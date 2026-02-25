(uiop:define-package :cl-inputs.tests.device-api
  (:use :cl :fiveam)
  (:import-from :cl-inputs.device.api
                #:make-device #:device-kind #:open-device #:close-device
                #:enable-raw-mode #:disable-raw-mode #:device-capabilities)
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
    (is (true (close-device dev)))))

(test enable-raw-mode-faketerm
  "Test enabling raw mode on faketerm"
  (let ((dev (make-device :faketerm)))
    (is (true (enable-raw-mode dev)))
    (is (true (disable-raw-mode dev)))))

(test device-capabilities-faketerm
  "Test getting device capabilities from faketerm"
  (let* ((dev (make-device :faketerm))
          (caps (device-capabilities dev)))
    (is (listp caps))
    (is (true (getf caps :truecolor)))))
