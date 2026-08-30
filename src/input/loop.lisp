
;; == end/package.lisp ==

;;;; cl-inputs.loop.lisp
;;;
;;; Main event loop and input source management for cl-inputs.
;;; Provides the core logic for reading, decoding, and dispatching input tokens
;;; from devices to sinks, supporting both synchronous and asynchronous usage.

(uiop:define-package :cl-inputs.loop
  (:use :cl :bt)
  (:import-from :cl-inputs.device.api #:device-read-bytes
    #:device-write-bytes #:device-set-nonblocking
    #:device-wait-readable #:open-device #:close-device
    #:disable-raw-char-mode #:with-raw-char-mode
    #:device-kind #:make-device #:enable-raw-char-mode)
  (:import-from :cl-inputs.decoder
    #:decode-chunk #:finish-decoder #:make-decoder #:decoder-next-deadline)
  (:import-from :cl-inputs.tokens
    #:input-token-kind)
  (:import-from :cl-inputs.routing
    #:make-response-router #:response-router-next-deadline
    #:expire-response-correlations #:route-token
    #:register-response-correlation #:response-correlation-state
    #:response-correlation-response #:cancel-response-correlation
    #:terminal-query-response-type #:terminal-query-bytes
    #:take-unmatched-response #:take-protocol-diagnostic)
  (:import-from #:log4cl #:log-debug #:log-warn #:log-info
    #:log-error) ; Added log-info
  (:import-from :cl-inputs.sink
    #:fn-sink
    #:accept-token
    #:on-key
    #:on-mouse
    #:on-resize
    #:on-ctrl-c
    #:on-paste
    #:on-focus)
  (:export #:decode-from-fd-once
    #:make-input-source
    #:next-token
    #:close-input-source
    #:cancel-input-source
    #:input-source-state
    #:input-source-terminal-outcome
    #:input-source-owns-device-p
    #:input-source-response-router
    #:expect-terminal-response
    #:send-terminal-query
    #:wait-terminal-response
    #:take-unmatched-terminal-response
    #:take-input-protocol-diagnostic
    #:decode-from-fd-loop
    #:input-loop
    #:start-input-loop
    #:stop-input-loop))

(in-package :cl-inputs.loop)

(defun %validate-timeout (timeout)
  (unless (or (null timeout) (and (realp timeout) (not (minusp timeout))))
    (error "Timeout must be NIL or a non-negative real, got ~S" timeout))
  timeout)

(defun %monotonic-seconds ()
  (/ (coerce (get-internal-real-time) 'double-float)
     (coerce internal-time-units-per-second 'double-float)))

(defparameter +cancellation-poll-seconds+ 0.05d0
  "Maximum time a source read may remain inside one readiness wait.")

(defun %minimum-deadline (&rest deadlines)
  (let ((present (remove nil deadlines)))
    (and present (reduce #'min present))))

(defun %remaining-seconds (deadline now)
  (and deadline (max 0d0 (- (coerce deadline 'double-float)
                            (coerce now 'double-float)))))

(defun %syscall-outcome (condition)
  (let ((errno (sb-posix:syscall-errno condition)))
    (cond
      ((= errno sb-posix:eintr) :interrupted)
      ((or (= errno sb-posix:eagain)
           (= errno sb-posix:ewouldblock))
       :would-block)
      (t nil))))


(defstruct input-loop
  "State for a running input loop.

Fields:
  DEV            -- device handle (type: device object)
  SINK           -- sink function or object for token delivery (type: function or sink object)
  DECODER        -- decoder state object (type: decoder)
  THREAD         -- thread running the loop (if async) (type: thread or null)
  STOP?          -- flag to request loop termination (type: boolean)
  CONDITION      -- condition variable for sync/notify (type: condition-variable or null)
  CONDITION-LOCK -- lock for condition variable (type: lock or null)
  LAST-OUTPUT    -- last token delivered (type: token or null)

All fields are required except THREAD, CONDITION, CONDITION-LOCK, and LAST-OUTPUT, which may be NIL if not used."
  dev
  sink
  decoder
  source
  thread
  stop?
  condition
  condition-lock
  last-output)

(defun %deliver (sink token)
  "Deliver TOKEN to SINK, dispatching to the appropriate handler.

Arguments:
  SINK  -- a function or sink object (type: function or sink object)
  TOKEN -- an input token (type: input-token)

Behavior:
  If SINK is a function, calls it directly with TOKEN.
  Otherwise, uses generic methods for the token kind (:key, :mouse, etc).

Return Value:
  None.

Side Effects:
  May invoke user-defined handlers or methods on SINK."
  (cond ((functionp sink) (funcall sink token))
    (t
      (accept-token sink token)
      (ecase (cl-inputs.tokens:input-token-kind token)
        (:key    (on-key sink token))
        (:mouse  (on-mouse sink token))
        (:resize (on-resize sink token))
        (:ctrl-c (on-ctrl-c sink token))
        (:paste  (on-paste sink token))
        (:focus  (on-focus sink token))))))


;;; INPUT-LOOP-MAIN owns device reads, decoder progression, token delivery,
;;; and optional synchronous notification. Historical draft implementations
;;; are intentionally omitted; tests define the maintained behavior.

(defun %maybe-signal (in-loop)
  "Safely notify a condition variable in the given IN-LOOP object.

Attempts to retrieve the 'condition' and 'condition-lock' slots from IN-LOOP.
If a condition variable is found, it is notified. If a lock is also present,
the notification occurs within a lock-held context. If either slot is missing,
no error is signaled.

+ IN-LOOP: An object that may have 'condition' and 'condition-lock' slots.
+ Uses Bordeaux Threads (bt) for locking and condition notification.
+ Ignores errors if slots are missing or unbound.

Example:
  (%maybe-signal some-loop-object)

This function is useful in concurrent code to safely notify waiting threads,
even when the presence of synchronization primitives is not guaranteed."
  (let ((cond (ignore-errors (slot-value in-loop 'condition)))
         (lock (ignore-errors (slot-value in-loop 'condition-lock))))
    (when cond
      (if lock
        (bt:with-lock-held (lock)
          (bt:condition-notify cond))
        (bt:condition-notify cond)))))
;; == cl-inputs/input-loop.lisp ==
;; The source structure is defined below; these forward calls intentionally stay
;; non-inline so the loop can share the pull-source lifecycle without reordering
;; the historical input-loop definitions.
(declaim (notinline input-source-decoder input-source-state))

;; The source owns readiness waits, decoder deadlines, raw mode and cleanup.
(defun input-loop-main (in-loop &key (sync nil) (wait-timeout-ms 200))
  (let ((source nil))
    (unwind-protect
      (progn
        (setf source (make-input-source :device (input-loop-dev in-loop)
                       :decoder (or (input-loop-decoder in-loop)
                                  (cl-inputs.decoder:make-decoder)))
          (input-loop-source in-loop) source)
        (loop until (input-loop-stop? in-loop) do
          (let ((token (next-token source :timeout (/ wait-timeout-ms 1000d0))))
            (setf (input-loop-decoder in-loop) (input-source-decoder source))
            (when token
              (setf (input-loop-last-output in-loop) token)
              (%deliver (input-loop-sink in-loop) token)
              (when sync (%maybe-signal in-loop)))
            (when (member (input-source-state source)
                          '(:closed :cancelled :eof :error))
              (return)))))
      (when source
        (close-input-source source))
      (setf (input-loop-source in-loop) nil))))


(defun start-input-loop
  (&key (device (cl-inputs.device.api:make-device :tty)) ;;:urxvt))
    (sink (fn-sink (lambda (_tok)
                     (log-warn "No sink defined; dropping token ~A" _tok)
                     ;; (declare (ignore _tok))
                     nil)))
    (decoder (cl-inputs.decoder:make-decoder))
    (mode :async)) ;; :async or :sync
  "Start an input loop. MODE can be :async (default) or :sync."
  (if (keywordp device)
    (setf device (cl-inputs.device.api:make-device device)))
  (let* ((condition (bt:make-condition-variable))
          (condition-lock (bt:make-lock))
          (in-loop (make-input-loop :dev device
                     :sink sink
                     :decoder decoder
                     :source nil
                     :stop? nil
                     :condition condition
                     :condition-lock condition-lock
                     :last-output nil)))
    (ecase mode
      (:async
        (setf (input-loop-thread in-loop)
          (bt:make-thread
            (lambda ()
              (input-loop-main in-loop :sync nil))
            :name (format nil "cl-inputs.loop[~A]" device))))
      (:sync
        ;; No thread, run in calling thread

        (progn
          ;; (log-info "Starting input loop in sync mode; blocking caller thread.")
          (input-loop-main in-loop :sync t))))
    in-loop))

(defun input-loop-wait-for-output (in-loop)
  "Wait for the next output in sync mode. Returns the last output."
  (bt:with-lock-held ((input-loop-condition-lock in-loop))
    (bt:condition-wait
      (input-loop-condition in-loop)
      (input-loop-condition-lock in-loop))
    (input-loop-last-output in-loop)))

(defun stop-input-loop (in-loop)
  "Request loop cancellation. Active reads are bounded by the source wait slice."
  (setf (input-loop-stop? in-loop) t)
  (let ((source (input-loop-source in-loop)))
    (when source
      (cancel-input-source source)))
  t)

;;; Pull mode: INPUT-SOURCE yields decoded tokens on demand.
(defstruct (input-source (:constructor %make-input-source))
  "Owned lifecycle for one decoder/device pair.

The source is the sole owner of raw-mode restoration and device close when
OWNS-DEVICE-P is true. Reads are serialized and use finite readiness slices so
close/cancel cannot leave a read permanently stranded."
  dev
  decoder
  buf
  response-router
  (pending-tokens nil :type list)
  pending-terminal-outcome
  (clock #'%monotonic-seconds :type function)
  (state :opening :type keyword)
  terminal-outcome
  (owns-device-p t :type boolean)
  (device-opened-p nil :type boolean)
  (raw-enabled-p nil :type boolean)
  (close-requested-p nil :type boolean)
  (cancel-requested-p nil :type boolean)
  (cleanup-done-p nil :type boolean)
  (state-lock (bt:make-lock "cl-inputs source state"))
  (read-lock (bt:make-lock "cl-inputs source read")))

(defmethod print-object ((src input-source) stream)
  (format stream "#<INPUT-SOURCE state=~A dev=~A buf-size=~A>"
    (input-source-state src)
    (input-source-dev src)
    (array-total-size (input-source-buf src))))

(defvar *default-input-source* nil
  "Default input source for cl-inputs.")

(defun %source-terminal-state-p (state)
  (member state '(:closed :cancelled :eof :error)))

(defun %source-stop-outcome (src)
  (bt:with-lock-held ((input-source-state-lock src))
    (cond
      ((input-source-cancel-requested-p src) :cancelled)
      ((input-source-close-requested-p src) :closed)
      ((eq (input-source-state src) :eof) :eof)
      ((eq (input-source-state src) :error) :error)
      (t nil))))

(defun %source-mark-reading (src)
  (bt:with-lock-held ((input-source-state-lock src))
    (unless (or (input-source-close-requested-p src)
                (%source-terminal-state-p (input-source-state src)))
      (setf (input-source-state src) :reading)
      t)))

(defun %source-mark-open-after-read (src)
  (bt:with-lock-held ((input-source-state-lock src))
    (when (and (eq (input-source-state src) :reading)
               (not (input-source-close-requested-p src)))
      (setf (input-source-state src) :open))))

(defun %cleanup-source-device (src)
  (when (input-source-owns-device-p src)
    (let ((dev (input-source-dev src)))
      (when (and dev (input-source-raw-enabled-p src))
        (ignore-errors (cl-inputs.device.api:disable-raw-char-mode dev))
        (setf (input-source-raw-enabled-p src) nil))
      (when (and dev (input-source-device-opened-p src))
        (ignore-errors (cl-inputs.device.api:close-device dev))
        (setf (input-source-device-opened-p src) nil))))
  t)

(defun %shutdown-input-source (src requested-state outcome &key cancel)
  "Request shutdown, serialize behind any active read, and clean up exactly once."
  (bt:with-lock-held ((input-source-state-lock src))
    (unless (input-source-cleanup-done-p src)
      (setf (input-source-close-requested-p src) t)
      (when cancel
        (setf (input-source-cancel-requested-p src) t))
      (unless (%source-terminal-state-p (input-source-state src))
        (setf (input-source-state src) (if cancel :cancelling :closing)))))
  (bt:with-lock-held ((input-source-read-lock src))
    (let ((cleanup-p nil))
      (bt:with-lock-held ((input-source-state-lock src))
        (unless (input-source-cleanup-done-p src)
          (setf cleanup-p t)))
      (when cleanup-p
        (%cleanup-source-device src)
        (bt:with-lock-held ((input-source-state-lock src))
          (let ((final-state (cond
                               ((input-source-cancel-requested-p src) :cancelled)
                               ((eq requested-state :eof) :eof)
                               ((eq requested-state :error) :error)
                               (t :closed))))
            (setf (input-source-state src) final-state
                  (input-source-terminal-outcome src)
                  (if (eq final-state :cancelled) :cancelled outcome)
                  (input-source-cleanup-done-p src) t))))))
  (when (eq *default-input-source* src)
    (setf *default-input-source* nil))
  t)

(defun get-input-source ()
  "Return the process-wide default input source, creating it on first use."
  (or *default-input-source*
      (make-input-source)))

(defun make-input-source (&key device decoder
                               (clock #'%monotonic-seconds)
                               (owns-device-p t))
  "Create an explicit source lifecycle around DEVICE and DECODER.

When OWNS-DEVICE-P is true (the default), this function opens DEVICE, enables
nonblocking reads and raw-character mode, and the returned source is responsible
for restoring raw mode and closing the device exactly once. Partial-open or
raw-mode failure is cleaned up before the original condition is re-signaled.
When OWNS-DEVICE-P is false, the caller retains ownership and must keep DEVICE
open, raw-configured, and nonblocking for the source lifetime; the source never
changes or closes that borrowed device."
  (check-type clock function)
  (let* ((device (or device (cl-inputs.device.api:make-device :tty)))
         (decoder (or decoder (cl-inputs.decoder:make-decoder :clock clock)))
         (src (%make-input-source
               :dev device
               :decoder decoder
               :buf (make-array 4096 :element-type '(unsigned-byte 8))
               :response-router (make-response-router :clock clock)
               :clock clock
               :owns-device-p owns-device-p)))
    (handler-case
      (progn
        (when owns-device-p
          (cl-inputs.device.api:open-device device)
          (setf (input-source-device-opened-p src) t)
          (cl-inputs.device.api:device-set-nonblocking device t)
          (cl-inputs.device.api:enable-raw-char-mode
           device :vmin 1 :vtime 0 :canonical nil :echo nil :isig t)
          (setf (input-source-raw-enabled-p src) t))
        (setf (input-source-state src) :open
              *default-input-source* src)
        src)
      (error (condition)
        (%cleanup-source-device src)
        (setf (input-source-state src) :error
              (input-source-terminal-outcome src) condition
              (input-source-cleanup-done-p src) t)
        (error condition)))))

;; override array printer for byte buffers only
(defun %print-ub8-array (arr stream)
  (let ((*print-readably* nil)
         (*print-level* nil)
         (*print-length* nil))
    (format stream "#<UB8 ~D bytes: "
      (length arr))
    (let ((limit (min 16 (length arr))))
      (dotimes (i limit)
        (format stream "~2,'0X " (aref arr i))))
    (when (> (length arr) 16)
      (format stream "..."))
    (format stream ">")))

(defun %enqueue-source-user-token (src token)
  (setf (input-source-pending-tokens src)
        (nconc (input-source-pending-tokens src) (list token)))
  token)

(defun %take-source-user-token (src)
  (pop (input-source-pending-tokens src)))

(defun %route-source-tokens (src tokens now)
  (dolist (token tokens)
    (multiple-value-bind (route correlation)
        (route-token (input-source-response-router src) token :now now)
      (declare (ignore correlation))
      (when (eq route :user-input)
        (%enqueue-source-user-token src token))))
  nil)

(defun %decode-source-octets (src octets now)
  (multiple-value-bind (tokens decoder)
      (cl-inputs.decoder:decode-chunk (input-source-decoder src) octets :now now)
    (setf (input-source-decoder src) decoder)
    (%route-source-tokens src tokens now)))

(defun %expire-source-decoder-deadline (src now)
  (%decode-source-octets
   src (make-array 0 :element-type '(unsigned-byte 8)) now))

(defun %device-wait-outcome (dev timeout-ms)
  (handler-case
      (cl-inputs.device.api:device-wait-readable dev timeout-ms)
    (sb-posix:syscall-error (condition)
      (or (%syscall-outcome condition)
          (error condition)))))

(defun %device-read-outcome (dev buffer)
  (handler-case
      (cl-inputs.device.api:device-read-bytes dev buffer 0 (length buffer))
    (sb-posix:syscall-error (condition)
      (or (%syscall-outcome condition)
          (error condition)))))

(defun %next-token-active (src timeout &key (return-user-input-p t) stop-predicate)
  (when (and stop-predicate (funcall stop-predicate))
    (return-from %next-token-active (values nil nil :stopped)))
  (when (and return-user-input-p (input-source-pending-tokens src))
    (return-from %next-token-active
      (values (%take-source-user-token src) nil nil)))
  (when (input-source-pending-terminal-outcome src)
    (let ((outcome (input-source-pending-terminal-outcome src)))
      (setf (input-source-pending-terminal-outcome src) nil)
      (return-from %next-token-active (values nil outcome))))
  (%validate-timeout timeout)
  (let* ((clock (input-source-clock src))
         (started-at (funcall clock))
         (caller-deadline (and timeout (+ started-at timeout)))
         (first-attempt-p t)
         (dev (input-source-dev src))
         (buf (input-source-buf src)))
    (loop
      (let ((stop-outcome (%source-stop-outcome src)))
        (when stop-outcome
          (return (values nil stop-outcome))))
      (let* ((now (funcall clock))
             (decoder-deadline
               (cl-inputs.decoder:decoder-next-deadline
                (input-source-decoder src)))
             (router-deadline
               (response-router-next-deadline
                (input-source-response-router src))))
        (expire-response-correlations (input-source-response-router src) :now now)
        (when (and stop-predicate (funcall stop-predicate))
          (return (values nil nil :stopped)))
        (when (and decoder-deadline (>= now decoder-deadline))
          (%expire-source-decoder-deadline src now)
          (when (and return-user-input-p (input-source-pending-tokens src))
            (return (values (%take-source-user-token src) nil nil)))
          (when (and stop-predicate (funcall stop-predicate))
            (return (values nil nil :stopped))))
        (when (and caller-deadline
                   (>= now caller-deadline)
                   (not first-attempt-p))
          (return (values nil nil)))
        (let* ((poll-deadline (+ now +cancellation-poll-seconds+))
               (wait-deadline (%minimum-deadline caller-deadline
                                                 decoder-deadline
                                                 router-deadline
                                                 poll-deadline))
               (wait-seconds (or (%remaining-seconds wait-deadline now)
                                 +cancellation-poll-seconds+))
               (wait-outcome (%device-wait-outcome dev (* wait-seconds 1000d0))))
          (setf first-attempt-p nil)
          (cond
            ((eq wait-outcome :interrupted)
             nil)
            ((or (null wait-outcome) (eq wait-outcome :would-block))
             nil)
            (t
             (let ((read-outcome (%device-read-outcome dev buf)))
               (cond
                 ((or (eq read-outcome :interrupted)
                      (eq read-outcome :would-block)
                      (and (integerp read-outcome) (zerop read-outcome)))
                  nil)
                 ((member read-outcome '(:closed :cancelled))
                  (return (values nil read-outcome)))
                 ((eq read-outcome :eof)
                  (multiple-value-bind (tokens decoder)
                      (cl-inputs.decoder:finish-decoder (input-source-decoder src))
                    (setf (input-source-decoder src) decoder)
                    (%route-source-tokens src tokens (funcall clock))
                    (cond
                      ((and return-user-input-p (input-source-pending-tokens src))
                       (setf (input-source-pending-terminal-outcome src) :eof)
                       (return (values (%take-source-user-token src) nil nil)))
                      ((and stop-predicate (funcall stop-predicate))
                       (setf (input-source-pending-terminal-outcome src) :eof)
                       (return (values nil nil :stopped)))
                      (t
                       (return (values nil :eof nil))))))
                 ((and (integerp read-outcome) (plusp read-outcome))
                  (%decode-source-octets
                   src (subseq buf 0 read-outcome) (funcall clock))
                  (when (and stop-predicate (funcall stop-predicate))
                    (return (values nil nil :stopped)))
                  (when (and return-user-input-p (input-source-pending-tokens src))
                    (return (values (%take-source-user-token src) nil nil))))
                 (t
                  (error "Unexpected device read outcome ~S from ~S"
                         read-outcome dev)))))))))))

(defun %ensure-source-queryable (src)
  (let ((outcome (%source-stop-outcome src)))
    (when outcome
      (error "Cannot register a terminal response query on source in ~S state."
             outcome)))
  src)

(defun expect-terminal-response (src response-type &key (timeout 0.5d0) deadline)
  "Register RESPONSE-TYPE on SRC without writing terminal bytes.

This is the correlation seam for protocol extensions. Register before emitting a
custom query so a fast response cannot race ahead of its correlation."
  (%ensure-source-queryable src)
  (register-response-correlation
   (input-source-response-router src) response-type
   :timeout timeout :deadline deadline))

(defun send-terminal-query (src query &key (timeout 0.5d0))
  "Register and emit a supported read-only terminal protocol QUERY.

The correlation is installed before bytes are written. A short/failed write
cancels the correlation and signals rather than leaving an unfulfillable live
request. QUERY describes protocol negotiation only; it carries no rendering
policy."
  (bt:with-lock-held ((input-source-read-lock src))
    (%ensure-source-queryable src)
    (let* ((correlation
             (register-response-correlation
              (input-source-response-router src)
              (terminal-query-response-type query)
              :timeout timeout))
           (bytes (terminal-query-bytes query)))
      (handler-case
          (let ((written
                  (cl-inputs.device.api:device-write-bytes
                   (input-source-dev src) bytes 0 (length bytes))))
            (unless (and (integerp written) (= written (length bytes)))
              (error "Terminal query ~S wrote ~S of ~D bytes."
                     query written (length bytes)))
            correlation)
        (error (condition)
          (cancel-response-correlation correlation)
          (error condition))))))

(defun wait-terminal-response (src correlation &key timeout)
  "Pump SRC until CORRELATION matches/expires, without consuming user input.

User-input tokens observed while waiting remain queued for NEXT-TOKEN in their
original order. TIMEOUT bounds this wait only; the correlation keeps its own
absolute deadline and may remain :PENDING if this call returns earlier."
  (%validate-timeout timeout)
  (labels ((done-p ()
             (not (eq (response-correlation-state correlation) :pending)))
           (cancel-if-pending ()
             (when (eq (response-correlation-state correlation) :pending)
               (cancel-response-correlation correlation))))
    (unless (done-p)
      (multiple-value-bind (ignored terminal-outcome stopped read-error)
          (handler-case
              (bt:with-lock-held ((input-source-read-lock src))
                (unless (%source-mark-reading src)
                  (cancel-if-pending)
                  (return-from wait-terminal-response nil))
                (multiple-value-bind (token terminal-outcome stopped)
                    (unwind-protect
                         (%next-token-active src timeout
                                             :return-user-input-p nil
                                             :stop-predicate #'done-p)
                      (%source-mark-open-after-read src))
                  (values token terminal-outcome stopped nil)))
            (error (condition)
              (%source-mark-open-after-read src)
              (values nil :error nil condition)))
        (declare (ignore ignored stopped))
        (when terminal-outcome
          ;; A terminal source cannot ever satisfy an outstanding response.
          ;; Fail closed instead of leaving a live correlation behind.
          (cancel-if-pending)
          (%shutdown-input-source src terminal-outcome
                                  (or read-error terminal-outcome)
                                  :cancel (eq terminal-outcome :cancelled)))
        (when read-error
          (error read-error))))
    (when (eq (response-correlation-state correlation) :matched)
      (response-correlation-response correlation))))

(defun take-unmatched-terminal-response (src)
  "Return the oldest valid terminal reply that had no live correlation."
  (take-unmatched-response (input-source-response-router src)))

(defun take-input-protocol-diagnostic (src)
  "Return the oldest malformed/unknown protocol token retained by SRC."
  (take-protocol-diagnostic (input-source-response-router src)))

(defun next-token (src &key timeout)
  "Return the next token, NIL on timeout/end, and preserve source terminal state.

TIMEOUT is a non-negative number of seconds or NIL for an indefinite logical
wait. Even an indefinite wait uses finite readiness slices so concurrent
close/cancel is observed. EINTR retries consume the caller's original budget;
EAGAIN/would-block returns to readiness waiting rather than spinning. The
Phase-A decoder ESC deadline participates in the same deadline calculation."
  (multiple-value-bind (token terminal-outcome read-error)
      (handler-case
        (bt:with-lock-held ((input-source-read-lock src))
          (unless (%source-mark-reading src)
            (return-from next-token nil))
          (multiple-value-bind (token terminal-outcome)
              (unwind-protect
                (%next-token-active src timeout)
                (%source-mark-open-after-read src))
            (values token terminal-outcome nil)))
        (error (condition)
          (%source-mark-open-after-read src)
          (values nil :error condition)))
    (when terminal-outcome
      (%shutdown-input-source src terminal-outcome
                              (or read-error terminal-outcome)
                              :cancel (eq terminal-outcome :cancelled)))
    (when read-error
      (error read-error))
    token))

(defun close-input-source (src)
  "Idempotently close SRC after any active bounded read returns."
  (%shutdown-input-source src :closed :closed))

(defun cancel-input-source (src)
  "Idempotently cancel SRC and wait for its active bounded read to unwind."
  (%shutdown-input-source src :cancelled :cancelled :cancel t))
