;;;; cl-inputs.routing.lisp
;;;
;;; Terminal-protocol routing and bounded response correlation.

(uiop:define-package :cl-inputs.routing
  (:use :cl)
  (:import-from :cl-inputs.tokens
                #:input-token-kind
                #:input-token-data
                #:+k-terminal-response+
                #:+k-protocol+)
  (:export
   #:+default-max-response-correlations+
   #:+default-max-protocol-backlog+
   #:make-response-router
   #:response-router-next-deadline
   #:register-response-correlation
   #:expire-response-correlations
   #:route-token
   #:token-route
   #:take-unmatched-response
   #:take-protocol-diagnostic
   #:response-correlation
   #:response-correlation-id
   #:response-correlation-response-type
   #:response-correlation-deadline
   #:response-correlation-state
   #:response-correlation-response
   #:cancel-response-correlation
   #:terminal-response-type
   #:terminal-query-response-type
   #:terminal-query-bytes))

(in-package :cl-inputs.routing)

(defparameter +default-max-response-correlations+ 16
  "Maximum simultaneously pending response correlations per input source.")

(defparameter +default-max-protocol-backlog+ 32
  "Maximum unmatched replies or protocol diagnostics retained per router queue.")

(defun %monotonic-seconds ()
  (/ (coerce (get-internal-real-time) 'double-float)
     (coerce internal-time-units-per-second 'double-float)))

(defun %validate-positive-bound (value name)
  (unless (and (integerp value) (plusp value))
    (error "~A must be a positive integer, got ~S" name value))
  value)

(defun %validate-timeout (timeout)
  (unless (and (realp timeout) (not (minusp timeout)))
    (error "Response timeout must be a non-negative real, got ~S" timeout))
  (coerce timeout 'double-float))

(defstruct (response-correlation (:constructor %make-response-correlation))
  "One terminal query/reply correlation with an absolute monotonic deadline."
  id
  response-type
  deadline
  (status :pending :type keyword)
  response-token
  (clock #'%monotonic-seconds :type function)
  (lock (bt:make-lock "cl-inputs response correlation")))

(defun response-correlation-state (correlation &key now)
  "Return CORRELATION lifecycle state, expiring a due pending request.

States are :PENDING, :MATCHED, :EXPIRED, and :CANCELLED. Deadline comparison is
inclusive: a reply observed at or after the absolute deadline cannot match."
  (bt:with-lock-held ((response-correlation-lock correlation))
    (when (and (eq (response-correlation-status correlation) :pending)
               (>= (coerce (or now
                               (funcall (response-correlation-clock correlation)))
                           'double-float)
                   (response-correlation-deadline correlation)))
      (setf (response-correlation-status correlation) :expired))
    (response-correlation-status correlation)))

(defun response-correlation-response (correlation)
  "Return the matched terminal-response token, or NIL when none matched."
  (response-correlation-state correlation)
  (bt:with-lock-held ((response-correlation-lock correlation))
    (response-correlation-response-token correlation)))

(defun cancel-response-correlation (correlation)
  "Idempotently cancel CORRELATION unless it already reached a terminal state."
  (bt:with-lock-held ((response-correlation-lock correlation))
    (when (eq (response-correlation-status correlation) :pending)
      (setf (response-correlation-status correlation) :cancelled))
    (response-correlation-status correlation)))

(defstruct (response-router (:constructor %make-response-router))
  (pending nil :type list)
  (unmatched nil :type list)
  (diagnostics nil :type list)
  (next-id 0 :type integer)
  (max-correlations +default-max-response-correlations+ :type integer)
  (max-backlog +default-max-protocol-backlog+ :type integer)
  (clock #'%monotonic-seconds :type function)
  (lock (bt:make-lock "cl-inputs response router")))

(defun make-response-router (&key
                               (clock #'%monotonic-seconds)
                               (max-correlations +default-max-response-correlations+)
                               (max-backlog +default-max-protocol-backlog+))
  "Create a bounded response router with an injectable monotonic CLOCK."
  (check-type clock function)
  (%make-response-router
   :clock clock
   :max-correlations (%validate-positive-bound max-correlations "MAX-CORRELATIONS")
   :max-backlog (%validate-positive-bound max-backlog "MAX-BACKLOG")))

(defun %expire-pending (router now)
  (setf (response-router-pending router)
        (delete-if (lambda (correlation)
                     (not (eq (response-correlation-state correlation :now now)
                              :pending)))
                   (response-router-pending router))))

(defun expire-response-correlations (router &key now)
  "Expire all pending correlations whose absolute deadlines are due."
  (bt:with-lock-held ((response-router-lock router))
    (%expire-pending router (or now (funcall (response-router-clock router))))
    (length (response-router-pending router))))

(defun response-router-next-deadline (router)
  "Return the earliest pending correlation deadline, or NIL."
  (bt:with-lock-held ((response-router-lock router))
    (let ((now (funcall (response-router-clock router))))
      (%expire-pending router now)
      (let ((pending (response-router-pending router)))
        (and pending
             (reduce #'min pending :key #'response-correlation-deadline))))))

(defun register-response-correlation (router response-type
                                      &key (timeout 0.5d0) deadline)
  "Register an expected RESPONSE-TYPE before emitting its terminal query.

TIMEOUT is relative to ROUTER's monotonic clock. DEADLINE, when supplied, is an
absolute monotonic timestamp and is mutually exclusive with a non-default
TIMEOUT argument in intent; callers should normally use one or the other. The
router has a hard bound and rejects registration rather than evicting a live
request. Correlations are FIFO among requests for the same response type."
  (let* ((now (funcall (response-router-clock router)))
         (absolute-deadline
           (if deadline
               (progn
                 (unless (realp deadline)
                   (error "DEADLINE must be a real monotonic timestamp, got ~S"
                          deadline))
                 (coerce deadline 'double-float))
               (+ now (%validate-timeout timeout)))))
    (bt:with-lock-held ((response-router-lock router))
      (%expire-pending router now)
      (when (>= (length (response-router-pending router))
                (response-router-max-correlations router))
        (error "Response correlation limit (~D) reached."
               (response-router-max-correlations router)))
      (let ((correlation
              (%make-response-correlation
               :id (incf (response-router-next-id router))
               :response-type response-type
               :deadline absolute-deadline
               :clock (response-router-clock router))))
        (setf (response-router-pending router)
              (nconc (response-router-pending router) (list correlation)))
        correlation))))

(defun terminal-response-type (token)
  "Return TOKEN's declared terminal response type, or NIL."
  (and (eq (input-token-kind token) +k-terminal-response+)
       (getf (input-token-data token) :response-type)))

(defun token-route (token)
  "Classify TOKEN without mutating routing state.

Only established user-input token kinds enter :USER-INPUT. Terminal replies and
protocol diagnostics remain on separate paths; unknown future kinds fail closed
to :PROTOCOL rather than silently becoming user input."
  (case (input-token-kind token)
    ((:key :mouse :resize :paste :focus :ctrl-c) :user-input)
    (:terminal-response :terminal-response)
    (:protocol :protocol)
    (otherwise :protocol)))

(defun %bounded-enqueue (queue token limit)
  (let ((queue (nconc queue (list token))))
    (when (> (length queue) limit)
      (setf queue (rest queue)))
    queue))

(defun %match-response (router token now)
  (%expire-pending router now)
  (let* ((response-type (terminal-response-type token))
         (correlation
           (find response-type (response-router-pending router)
                 :key #'response-correlation-response-type
                 :test #'eq)))
    (if correlation
        (progn
          (bt:with-lock-held ((response-correlation-lock correlation))
            (setf (response-correlation-status correlation) :matched
                  (response-correlation-response-token correlation) token))
          (setf (response-router-pending router)
                (delete correlation (response-router-pending router) :test #'eq))
          correlation)
        nil)))

(defun route-token (router token &key now)
  "Route TOKEN and return two values: route keyword and matched correlation.

A valid terminal response is consumed only by a live matching correlation.
Unmatched or stale replies are retained in the bounded unmatched queue and are
never reinterpreted as user input. Protocol diagnostics are likewise retained
separately."
  (let ((route (token-route token))
        (now (or now (funcall (response-router-clock router)))))
    (bt:with-lock-held ((response-router-lock router))
      (case route
        (:terminal-response
         (let ((correlation (%match-response router token now)))
           (if correlation
               (values :matched-response correlation)
               (progn
                 (setf (response-router-unmatched router)
                       (%bounded-enqueue (response-router-unmatched router)
                                         token
                                         (response-router-max-backlog router)))
                 (values :unmatched-response nil)))))
        (:protocol
         (setf (response-router-diagnostics router)
               (%bounded-enqueue (response-router-diagnostics router)
                                 token
                                 (response-router-max-backlog router)))
         (values :protocol nil))
        (otherwise
         (values :user-input nil))))))

(defun take-unmatched-response (router)
  "Remove and return the oldest unmatched terminal response, or NIL."
  (bt:with-lock-held ((response-router-lock router))
    (pop (response-router-unmatched router))))

(defun take-protocol-diagnostic (router)
  "Remove and return the oldest protocol diagnostic, or NIL."
  (bt:with-lock-held ((response-router-lock router))
    (pop (response-router-diagnostics router))))

(defun terminal-query-response-type (query)
  "Return the response type expected for a supported protocol QUERY."
  (ecase query
    (:cursor-position :cursor-position)
    (:device-status :device-status)
    (:primary-device-attributes :primary-device-attributes)
    (:secondary-device-attributes :secondary-device-attributes)))

(defun terminal-query-bytes (query)
  "Return a fresh octet vector for a supported read-only terminal QUERY."
  (let ((bytes
          (ecase query
            (:cursor-position '(27 91 54 110))       ; CSI 6 n
            (:device-status '(27 91 53 110))         ; CSI 5 n
            (:primary-device-attributes '(27 91 99)) ; CSI c
            (:secondary-device-attributes '(27 91 62 99))))) ; CSI > c
    (make-array (length bytes)
                :element-type '(unsigned-byte 8)
                :initial-contents bytes)))
