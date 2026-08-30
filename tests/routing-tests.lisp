(uiop:define-package :cl-inputs.tests.routing
  (:use :cl :fiveam)
  (:import-from :cl-inputs.tokens #:make-token #:input-token-data)
  (:import-from :cl-inputs.routing
                #:make-response-router #:register-response-correlation
                #:route-token #:response-correlation-state
                #:response-correlation-response #:take-unmatched-response
                #:cancel-response-correlation
                #:take-protocol-diagnostic #:terminal-query-response-type
                #:terminal-query-bytes)
  (:export #:routing-tests))

(in-package :cl-inputs.tests.routing)

(def-suite routing-tests
  :description "Terminal response routing and bounded correlation"
  :in :cl-inputs)

(in-suite routing-tests)

(defun response-token (type &rest data)
  (make-token :terminal-response (list* :response-type type data) 0d0))

(test matched-response-is-consumed-by-live-correlation
  (let ((now 10d0))
    (flet ((clock () now))
      (let* ((router (make-response-router :clock #'clock))
             (correlation (register-response-correlation
                           router :cursor-position :timeout 0.5d0))
             (token (response-token :cursor-position :row 4 :column 9)))
        (multiple-value-bind (route matched)
            (route-token router token :now 10.25d0)
          (is (eq :matched-response route))
          (is (eq correlation matched)))
        (is (eq :matched (response-correlation-state correlation :now 10.25d0)))
        (is (eq token (response-correlation-response correlation)))
        (is (null (take-unmatched-response router)))))))

(test unmatched-response-never-becomes-user-input
  (let ((router (make-response-router)))
    (let ((token (response-token :device-status :status 0)))
      (is (eq :unmatched-response (nth-value 0 (route-token router token))))
      (is (eq token (take-unmatched-response router)))
      (is (null (take-unmatched-response router))))))

(test stale-response-expires-correlation-and-is-unmatched
  (let ((now 20d0))
    (flet ((clock () now))
      (let* ((router (make-response-router :clock #'clock))
             (correlation (register-response-correlation
                           router :cursor-position :timeout 0.1d0))
             (token (response-token :cursor-position :row 1 :column 1)))
        (setf now 20.1d0)
        (is (eq :unmatched-response
                (nth-value 0 (route-token router token :now now))))
        (is (eq :expired (response-correlation-state correlation :now now)))
        (is (null (response-correlation-response correlation)))
        (is (eq token (take-unmatched-response router)))))))

(test protocol-diagnostic-has-separate-bounded-path
  (let ((router (make-response-router :max-backlog 2)))
    (dolist (reason '(:one :two :three))
      (is (eq :protocol
              (nth-value 0
                         (route-token router
                                      (make-token :protocol
                                                  (list :reason reason)
                                                  0d0))))))
    (is (eq :two (getf (input-token-data (take-protocol-diagnostic router))
                        :reason)))
    (is (eq :three (getf (input-token-data (take-protocol-diagnostic router))
                          :reason)))
    (is (null (take-protocol-diagnostic router)))))

(test correlation-limit-rejects-live-overflow
  (let ((router (make-response-router :max-correlations 1)))
    (register-response-correlation router :cursor-position :timeout 1d0)
    (signals error
      (register-response-correlation router :device-status :timeout 1d0))))

(test same-type-correlations-match-in-registration-order
  (let* ((router (make-response-router))
         (first (register-response-correlation
                 router :cursor-position :timeout 1d0))
         (second (register-response-correlation
                  router :cursor-position :timeout 1d0))
         (first-token (response-token :cursor-position :row 1 :column 2))
         (second-token (response-token :cursor-position :row 3 :column 4)))
    (is (eq first
            (nth-value 1 (route-token router first-token))))
    (is (eq second
            (nth-value 1 (route-token router second-token))))
    (is (eq first-token (response-correlation-response first)))
    (is (eq second-token (response-correlation-response second)))))

(test explicit-correlation-cancellation-is-terminal-and-skipped-by-fifo
  (let* ((router (make-response-router))
         (cancelled (register-response-correlation
                     router :cursor-position :timeout 1d0))
         (live (register-response-correlation
                router :cursor-position :timeout 1d0))
         (token (response-token :cursor-position :row 5 :column 6)))
    (is (eq :cancelled (cancel-response-correlation cancelled)))
    (is (eq live (nth-value 1 (route-token router token))))
    (is (eq :cancelled (response-correlation-state cancelled)))
    (is (eq :matched (response-correlation-state live)))))

(test explicit-cancellation-releases-bounded-correlation-capacity
  (let* ((router (make-response-router :max-correlations 1))
         (first (register-response-correlation
                 router :cursor-position :timeout 1d0)))
    (is (eq :cancelled (cancel-response-correlation first)))
    (is (typep (register-response-correlation
                router :device-status :timeout 1d0)
               'cl-inputs.routing:response-correlation))))

(test unmatched-response-backlog-drops-oldest-at-bound
  (let ((router (make-response-router :max-backlog 2)))
    (dolist (status '(1 2 3))
      (is (eq :unmatched-response
              (nth-value 0
                         (route-token router
                                      (response-token :device-status
                                                      :status status))))))
    (is (= 2 (getf (input-token-data (take-unmatched-response router))
                   :status)))
    (is (= 3 (getf (input-token-data (take-unmatched-response router))
                   :status)))
    (is (null (take-unmatched-response router)))))

(test capability-query-contract-is-explicit
  (is (eq :primary-device-attributes
          (terminal-query-response-type :primary-device-attributes)))
  (is (eq :secondary-device-attributes
          (terminal-query-response-type :secondary-device-attributes)))
  (is (equal '(27 91 99)
             (coerce (terminal-query-bytes :primary-device-attributes) 'list)))
  (is (equal '(27 91 62 99)
             (coerce (terminal-query-bytes :secondary-device-attributes) 'list))))
