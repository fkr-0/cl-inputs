(uiop:define-package :cl-inputs.tests.device-api
  (:use :cl :fiveam)
  (:import-from :cl-inputs.device.api
                #:make-device #:device-kind #:open-device #:close-device
                #:enable-raw-mode #:disable-raw-mode #:device-capabilities
                #:device-error)
  (:export #:device-api-tests))

(in-package :cl-inputs.tests.device-api)

(def-suite device-api-tests
  :description "Tests for cl-inputs.device.api module"
  :in :cl-inputs)

(in-suite device-api-tests)

(test make-device-faketerm
  "Test creating a faketerm device"
  (let* ((dev (make-device :faketerm :width 40 :height 12))
          (kind (device-kind dev)))
    (is (eq :faketerm kind))))

(test open-close-faketerm
  "Test opening and closing faketerm device"
  (let ((dev (make-device :faketerm)))
    (is (eq dev (open-device dev)))
    (is-true (close-device dev))))

(test enable-raw-mode-faketerm
  "Test enabling raw mode on faketerm"
  (let ((dev (make-device :faketerm)))
    (is-true (enable-raw-mode dev))
    (is-true (disable-raw-mode dev))))

(test device-capabilities-faketerm
  "Test getting device capabilities from faketerm"
  (let* ((dev (make-device :faketerm))
          (caps (device-capabilities dev)))
    (is (listp caps))
    (is-true (getf caps :truecolor))))

(test unsupported-device-operation-signals-reportable-device-error
  (let ((condition
          (handler-case
              (progn (open-device (list :unsupported)) nil)
            (device-error (condition) condition))))
    (is (typep condition 'device-error))
    (is (search "Unsupported device operation OPEN-DEVICE"
                (princ-to-string condition)))))

(test unsupported-device-protocol-methods-fail-closed
  "Every documented fallback must signal a reportable DEVICE-ERROR."
  (let ((bad (list :not-a-device))
        (bytes (make-array 2 :element-type '(unsigned-byte 8)
                           :initial-contents '(65 66))))
    (dolist (case (list
                   (cons "CLOSE-DEVICE" (lambda () (close-device bad)))
                   (cons "ENABLE-RAW-MODE" (lambda () (enable-raw-mode bad)))
                   (cons "DISABLE-RAW-MODE" (lambda () (disable-raw-mode bad)))
                   (cons "DEVICE-READ-BYTES"
                         (lambda () (cl-inputs.device.api:device-read-bytes bad bytes 0 2)))
                   (cons "DEVICE-WRITE-BYTES"
                         (lambda () (cl-inputs.device.api:device-write-bytes bad bytes 0 2)))
                   (cons "DEVICE-INPUT-STREAM"
                         (lambda () (cl-inputs.device.api:device-input-stream bad)))
                   (cons "DEVICE-OUTPUT-STREAM"
                         (lambda () (cl-inputs.device.api:device-output-stream bad)))
                   (cons "DEVICE-FD"
                         (lambda () (cl-inputs.device.api:device-fd bad)))
                   (cons "DEVICE-CAPABILITIES"
                         (lambda () (device-capabilities bad)))
                   (cons "DEVICE-SET-MODES"
                         (lambda () (cl-inputs.device.api:device-set-modes bad '(:paste t))))))
      (let ((condition (handler-case (progn (funcall (cdr case)) nil)
                         (device-error (error) error))))
        (is (typep condition 'device-error))
        (when condition
          (is (search (car case) (princ-to-string condition))))))))

(test lockable-recursion-and-unwind-cleanup
  "Nested ownership and exceptional unwind release the underlying lock once."
  (let ((object (make-instance 'cl-inputs.device.api:lockable)))
    (is (eq object (cl-inputs.device.api:acquire-lock object)))
    (is (= 1 (cl-inputs.device.api::lock-owner-count object)))
    (cl-inputs.device.api:with-lock (object)
      (is (= 2 (cl-inputs.device.api::lock-owner-count object))))
    (is (= 1 (cl-inputs.device.api::lock-owner-count object)))
    (cl-inputs.device.api:release-lock object)
    (is (= 0 (cl-inputs.device.api::lock-owner-count object)))
    (signals error
      (cl-inputs.device.api:with-lock (object)
        (error "Injected failure while owning a recursive lock.")))
    (is (= 0 (cl-inputs.device.api::lock-owner-count object)))
    (cl-inputs.device.api:with-lock (object)
      (is (= 1 (cl-inputs.device.api::lock-owner-count object))))
    (is (= 0 (cl-inputs.device.api::lock-owner-count object)))))
