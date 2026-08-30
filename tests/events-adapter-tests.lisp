(uiop:define-package :cl-inputs.tests.events-adapter
  (:use :cl :fiveam)
  (:import-from :cl-inputs.tokens #:make-token)
  (:import-from :cl-inputs.events #:token->event #:event-bus-sink)
  (:export #:run-events-adapter-tests))

(in-package :cl-inputs.tests.events-adapter)

(def-suite events-adapter-tests
  :description "Optional cl-events adapter protocol and publish behavior")

(in-suite events-adapter-tests)

(test token-event-satisfies-cl-events-protocol
  (let* ((token (make-token :key '(:code #\x) 123))
         (event (token->event token)))
    (is (eq :key (cl-events.protocols:event-topic event)))
    (is (eq token (cl-events.protocols:event-payload event)))
    (is (= 123 (cl-events.protocols:event-timestamp event)))))

(test event-bus-sink-publishes-on-requested-topic
  (let* ((bus (cl-events.bus:make-event-bus))
         (channel (cl-events.bus:subscribe bus :input/token))
         (sink (event-bus-sink bus :topic :input/token))
         (token (make-token :key '(:code #\y) 456)))
    (unwind-protect
         (progn
           (is-true (funcall sink token))
           (let ((published (cl-events.channel:chan-take channel)))
             (is (eq :input/token (cl-events.protocols:event-topic published)))
             (is (= 456 (cl-events.protocols:event-timestamp published)))
             (let ((nested (cl-events.protocols:event-payload published)))
               (is (eq :key (cl-events.protocols:event-topic nested)))
               (is (eq token (cl-events.protocols:event-payload nested))))))
      (cl-events.bus:unsubscribe bus :input/token channel)
      (cl-events.channel:chan-close channel))))

(defun run-events-adapter-tests ()
  "Run only the optional cl-events adapter regression suite."
  (let ((results (fiveam:run 'events-adapter-tests)))
    (fiveam:explain! results)
    (unless (fiveam:results-status results)
      (error "The cl-inputs/events adapter test suite failed."))
    results))
