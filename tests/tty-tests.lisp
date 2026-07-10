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
