(uiop:define-package :cl-inputs.tests.tty
  (:use :cl :fiveam)
  (:import-from :cl-inputs.device.api #:make-device #:device-kind)
  (:export #:tty-tests))

(in-package :cl-inputs.tests.tty)

(def-suite tty-tests
  :description "Tests for cl-inputs.device.tty module"
  :in :cl-inputs)

(in-suite tty-tests)

;; Note: TTY tests require actual /dev/tty access
;; These tests are minimal to avoid hanging in CI/CD

(test make-tty-device
  "Test creating a TTY device"
  (handler-case
      (let ((dev (make-device :tty)))
        (is (not (null dev)))
        (is (eq :tty (device-kind dev))))
    (sb-posix:syscall-error ()
      (skip "No controlling TTY is available in this test environment."))))

(test unopened-tty-device-is-idempotently-closable
  "A constructed but unopened device must not leak a descriptor or raw state."
  (let ((dev (cl-inputs.device.tty:make-tty-device
              :path "/dev/tty")))
    (is (eq :tty (device-kind dev)))
    (is (null (cl-inputs.device.api:device-fd dev)))
    (is (null (cl-inputs.device.api:device-input-stream dev)))
    (is (null (cl-inputs.device.api:device-output-stream dev)))
    (is-true (cl-inputs.device.api:disable-raw-mode dev))
    (is-true (cl-inputs.device.api:close-device dev))
    (is-true (cl-inputs.device.api:close-device dev))
    (is (null (cl-inputs.device.api:device-fd dev)))))

(test tty-open-failure-cleans-up-and-allows-second-close
  "An impossible path must signal and leave no half-open device."
  (let* ((path (merge-pathnames
                 (format nil "cl-inputs-no-tty-~A" (gensym))
                 (uiop:temporary-directory)))
         (dev (cl-inputs.device.tty:make-tty-device
               :path (namestring path))))
    (signals sb-posix:syscall-error (cl-inputs.device.api:open-device dev))
    (is (null (cl-inputs.device.api:device-input-stream dev)))
    (is (null (cl-inputs.device.api:device-output-stream dev)))
    (is (null (cl-inputs.device.api:device-fd dev)))
    (is-true (cl-inputs.device.api:close-device dev))
    (is-true (cl-inputs.device.api:close-device dev))))
