(uiop:define-package :cl-inputs.tests.optional-events
  (:use :cl :fiveam)
  (:export #:optional-events-tests))

(in-package :cl-inputs.tests.optional-events)

(def-suite optional-events-tests
  :description "ASDF boundary for the optional cl-events adapter"
  :in :cl-inputs)

(in-suite optional-events-tests)

(test core-has-no-required-cl-events-dependency
  (let ((dependencies
          (asdf:system-depends-on (asdf:find-system "cl-inputs"))))
    (is-false (member "cl-events" dependencies :test #'string=))))

(test events-adapter-declares-both-boundary-dependencies
  (let ((dependencies
          (asdf:system-depends-on (asdf:find-system "cl-inputs/events"))))
    (is-true (member "cl-inputs" dependencies :test #'string=))
    (is-true (member "cl-events" dependencies :test #'string=))))

(test core-sink-does-not-dynamically-load-events-adapter
  (multiple-value-bind (symbol status)
      (find-symbol "EVENT-BUS-SINK" :cl-inputs.sink)
    (declare (ignore symbol))
    (is (null status)))
  (multiple-value-bind (symbol status)
      (find-symbol "TOKEN->EVENT" :cl-inputs.sink)
    (declare (ignore symbol))
    (is (null status))))
