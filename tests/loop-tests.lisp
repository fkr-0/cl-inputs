(uiop:define-package :cl-inputs.tests.loop
  (:use :cl :fiveam)
  (:import-from :cl-inputs.loop
                #:input-source #:input-source-device #:input-source-sink
                #:poll-once)
  (:import-from :cl-inputs.device.api #:make-device)
  (:import-from :cl-inputs.tokens #:make-token)
  (:export #:loop-tests))

(in-package :cl-inputs.tests.loop)

(def-suite loop-tests
  :description "Tests for cl-inputs.loop module"
  :in :cl-inputs)

(in-suite loop-tests)

(test make-input-source-from-device
  "Test creating an input source from device"
  (let ((dev (make-device :faketerm))
        (src (input-source-device (make-device :faketerm))))
    (is (listp src))))

(test poll-once-no-data
  "Test poll-once with no data returns NIL"
  (let ((dev (make-device :faketerm))
        (src (input-source-device dev)))
    (is (null (poll-once src)))))
