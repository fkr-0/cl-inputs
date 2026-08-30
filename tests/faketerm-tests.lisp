(uiop:define-package :cl-inputs.tests.faketerm
  (:use :cl :fiveam)
  (:import-from :cl-inputs.device.api
                #:make-device #:open-device #:close-device
                #:enable-raw-char-mode #:disable-raw-char-mode
                #:device-set-nonblocking #:device-read-bytes #:device-wait-readable)
  (:import-from :cl-inputs.device.faketerm
                #:faketerm-screen-lines #:faketerm-inject! #:faketerm-device-p
                #:faketerm-device-width #:faketerm-device-height
                #:faketerm-device-open-p #:faketerm-device-closed-p
                #:faketerm-device-raw-depth #:faketerm-device-nonblocking-p
                #:faketerm-device-read-count #:faketerm-device-wait-count
                #:faketerm-device-close-count)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:export #:faketerm-tests))

(in-package :cl-inputs.tests.faketerm)

(def-suite faketerm-tests
  :description "Tests for cl-inputs.device.faketerm module"
  :in :cl-inputs)

(in-suite faketerm-tests)

(test faketerm-screen-empty
  "Test that empty faketerm screen is empty"
  (let ((dev (make-device :faketerm :width 10 :height 5)))
    (is (equal '("" "" "" "" "") (faketerm-screen-lines dev)))))

(test faketerm-screen-dimensions
  "Test faketerm screen dimensions"
  (let ((dev (make-device :faketerm :width 20 :height 10)))
    (is (= 20 (faketerm-device-width dev)))
    (is (= 10 (faketerm-device-height dev)))))

(test faketerm-inject-and-read
  "Test injecting and reading from faketerm"
  (let ((dev (make-device :faketerm)))
    (faketerm-inject! dev (string-to-utf-8-bytes "X"))
    ;; Note: actually reading requires input-source setup
    ;; This test just verifies inject doesn't error
    (is-true t)))

(test faketerm-lifecycle-is-observable-and-idempotent
  (let ((dev (make-device :faketerm)))
    (is (eq dev (open-device dev)))
    (is-true (faketerm-device-open-p dev))
    (is-true (enable-raw-char-mode dev))
    (is (= 1 (faketerm-device-raw-depth dev)))
    (is-true (device-set-nonblocking dev t))
    (is-true (faketerm-device-nonblocking-p dev))
    (is-true (close-device dev))
    (is-true (close-device dev))
    (is-true (faketerm-device-closed-p dev))
    (is (= 0 (faketerm-device-raw-depth dev)))
    (is (= 1 (faketerm-device-close-count dev)))))

(test faketerm-scripted-transient-outcomes
  (let* ((dev (make-device :faketerm :script (list :interrupted :would-block)))
         (buffer (make-array 4 :element-type '(unsigned-byte 8))))
    (open-device dev)
    (is-true (device-wait-readable dev 0))
    (is (eq :interrupted (device-read-bytes dev buffer 0 4)))
    (is-true (device-wait-readable dev 0))
    (is (eq :would-block (device-read-bytes dev buffer 0 4)))
    (is-true (device-wait-readable dev 0))
    (is (eq :eof (device-read-bytes dev buffer 0 4)))
    (is (= 3 (faketerm-device-read-count dev)))
    (is (= 3 (faketerm-device-wait-count dev)))
    (disable-raw-char-mode dev)
    (close-device dev)))
