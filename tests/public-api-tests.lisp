(uiop:define-package :cl-inputs.tests.public-api
  (:use :cl :fiveam)
  (:export #:public-api-tests))

(in-package :cl-inputs.tests.public-api)

(def-suite public-api-tests
  :description "0.2.0 public package and ASDF boundary contract"
  :in :cl-inputs)

(in-suite public-api-tests)

(defun %external-symbol-p (name package)
  (multiple-value-bind (symbol status) (find-symbol name package)
    (and symbol (eq status :external))))

(test facade-reexports-source-and-response-api
  (dolist (name '("MAKE-INPUT-SOURCE"
                  "NEXT-TOKEN"
                  "CLOSE-INPUT-SOURCE"
                  "CANCEL-INPUT-SOURCE"
                  "EXPECT-TERMINAL-RESPONSE"
                  "SEND-TERMINAL-QUERY"
                  "WAIT-TERMINAL-RESPONSE"
                  "TAKE-UNMATCHED-TERMINAL-RESPONSE"
                  "TAKE-INPUT-PROTOCOL-DIAGNOSTIC"))
    (is-true (%external-symbol-p name :cl-inputs))))

(test phantom-device-raw-mode-export-is-absent
  (is-false (%external-symbol-p "DEVICE-ENABLE-RAW-CHAR-MODE"
                                :cl-inputs.device.api))
  (is-true (%external-symbol-p "ENABLE-RAW-CHAR-MODE"
                               :cl-inputs.device.api)))

(test event-bus-compatibility-shims-are-not-core-exports
  (dolist (name '("EVENT-BUS-SINK" "TOKEN->EVENT"))
    (is-false (%external-symbol-p name :cl-inputs.sink))
    (is-false (%external-symbol-p name :cl-inputs))))

(test asdf-system-boundaries-are-explicit
  (let ((core (asdf:find-system "cl-inputs"))
        (events (asdf:find-system "cl-inputs/events"))
        (tests (asdf:find-system "cl-inputs/tests"))
        (events-tests (asdf:find-system "cl-inputs/events-tests")))
    (is (string= "0.2.0" (asdf:component-version core)))
    (is (string= "0.2.0" (asdf:component-version events)))
    (is (string= "0.2.0" (asdf:component-version tests)))
    (is (string= "0.2.0" (asdf:component-version events-tests)))
    (is-false (member "cl-events" (asdf:system-depends-on core)
                      :test #'string=))
    (is-false (member "cl-events" (asdf:system-depends-on tests)
                      :test #'string=))
    (is-true (member "cl-inputs" (asdf:system-depends-on events)
                     :test #'string=))
    (is-true (member "cl-events" (asdf:system-depends-on events)
                     :test #'string=))
    (is-true (member "cl-inputs/events" (asdf:system-depends-on events-tests)
                     :test #'string=))))
