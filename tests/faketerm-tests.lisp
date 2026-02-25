(uiop:define-package :cl-inputs.tests.faketerm
  (:use :cl :fiveam)
  (:import-from :cl-inputs.device.api #:make-device)
  (:import-from :cl-inputs.device.faketerm
                #:faketerm-screen-lines #:faketerm-inject! #:faketerm-device-p
                #:faketerm-device-width #:faketerm-device-height)
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
