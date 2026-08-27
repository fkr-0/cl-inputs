
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
  (:import-from  :cl-inputs.decoder #:decode-chunk #:make-decoder)
  (:import-from :cl-inputs.tokens
    #:input-token-kind)
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
    #:decode-from-fd-loop
    #:input-loop
    #:start-input-loop))

(in-package :cl-inputs.loop)

(defun %validate-timeout (timeout)
  (unless (or (null timeout) (and (numberp timeout) (not (minusp timeout))))
    (error "Timeout must be NIL or a non-negative number, got ~S" timeout))
  timeout)


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
;; Wait → ONE read(2) → decode. Keep fd in BLOCKING mode; VMIN handles latency.
(defun input-loop-main (in-loop &key (sync nil) (wait-timeout-ms 200))
  (let* ((dev     (input-loop-dev in-loop))
          (decoder (or (input-loop-decoder in-loop) (cl-inputs.decoder:make-decoder)))
          (buf     (make-array 1 :element-type '(unsigned-byte 8))))
    (unwind-protect
      (progn
        (open-device dev)
        (device-set-nonblocking dev nil) ; blocking mode plus VMIN=1 keeps first-byte latency explicit
        (with-raw-char-mode (dev :vmin 1 :vtime 0 :canonical nil :echo nil :isig t)
          (loop until (input-loop-stop? in-loop) do
            (when (device-wait-readable dev wait-timeout-ms) ; bounded wait keeps stop checks responsive
              (let ((n (device-read-bytes dev buf 0 (length buf))))
                (when (and n (not (eql n :eof)) (> n 0))
                  (multiple-value-bind (tokens dec2)
                    (cl-inputs.decoder:decode-chunk decoder (subseq buf 0 n))
                    (setf decoder dec2 (input-loop-decoder in-loop) dec2)
                    (dolist (tok tokens)
                      (setf (input-loop-last-output in-loop) tok)
                      (%deliver (input-loop-sink in-loop) tok)
                      (when sync (%maybe-signal in-loop))))))))))
      (ignore-errors (disable-raw-char-mode dev))
      (ignore-errors (close-device dev)))))


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
  (cl-inputs.device.api:enable-raw-mode device)
  (let* ((condition (bt:make-condition-variable))
          (condition-lock (bt:make-lock))
          (in-loop (make-input-loop :dev device
                     :sink sink
                     :decoder decoder
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
  (setf (input-loop-stop? in-loop) t)
  (cl-inputs.device.api:close-device
    (input-loop-dev in-loop))
  t)

;;; Pull mode: INPUT-SOURCE yields decoded tokens on demand.
(defstruct (input-source (:constructor %make-input-source))
  "A source of input tokens, typically from a device.

Fields:
  DEV     -- device object (type: device)
  DECODER -- decoder state (type: decoder)
  BUF     -- buffer for input bytes (type: (array (unsigned-byte 8) *))
  PENDING-TOKENS -- buffered tokens from a previous decode-chunk call

All fields are required."
  dev decoder buf
  (pending-tokens nil :type list))

(defmethod print-object ((src input-source) stream)
  (format stream "#<INPUT-SOURCE dev=~A decoder=~A buf-size=~A>"
    (input-source-dev src)
    (input-source-decoder src)
    (array-total-size (input-source-buf src))))

(defvar *default-input-source* nil
  "Default input source for cl-inputs.")
(defun get-input-source ()
  "Return the process-wide default input source, creating it on first use.

Arguments:
  None.

Returns:
  The cached INPUT-SOURCE. The first call delegates to MAKE-INPUT-SOURCE with
  its default device and decoder.

Mutation:
  On first use, MAKE-INPUT-SOURCE stores the new source in
  *DEFAULT-INPUT-SOURCE* and may enable raw mode on the underlying device.

Conditions:
  Device/decoder construction conditions propagate. Raw-mode enablement is
  currently best-effort inside MAKE-INPUT-SOURCE and is therefore not signaled.

Example:
  (let ((source (get-input-source)))
    (next-token source :timeout 0))"
  (or *default-input-source*
      (make-input-source)))
(defun make-input-source (&key (device (cl-inputs.device.api:make-device :tty))
                           (decoder (cl-inputs.decoder:make-decoder)))
  (cl-inputs.device.api:open-device device)
  (ignore-errors (cl-inputs.device.api:enable-raw-char-mode device))
  (ignore-errors (cl-inputs.device.api:enable-raw-mode device))
  (let ((src (%make-input-source :dev device :decoder decoder
               :buf (make-array 4096 :element-type '(unsigned-byte 8)))))
    (setf *default-input-source* src)
    src))

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


(defun next-token (src &key timeout)
  "Blocking read (or timed if DEVICE supports it). Returns a token or NIL on EOF."
  ;; Drain any tokens buffered from a previous read first
  (let ((pending (input-source-pending-tokens src)))
    (when pending
      (setf (input-source-pending-tokens src) (rest pending))
      (return-from next-token (first pending))))
  (let* ((dev (input-source-dev src))
          (buf (input-source-buf src)))
    (when (and dev (numberp timeout))
      (let ((ms (if (<= timeout 0) 0 (round (* timeout 1000)))))
        (unless (cl-inputs.device.api:device-wait-readable dev ms)
          (return-from next-token nil))))
    (let ((n (cl-inputs.device.api:device-read-bytes dev buf 0 4096)))
      (cond
        ((or (eql n :eof) (null n) (zerop n)) nil)
        (t
          (multiple-value-bind (tokens dec2)
            (cl-inputs.decoder:decode-chunk (input-source-decoder src)
              (subseq buf 0 n))
            (setf (input-source-decoder src) dec2)
            (when (rest tokens)
              (setf (input-source-pending-tokens src) (rest tokens)))
            (first tokens)))))))

(defun close-input-source (src)
  (let ((dev (input-source-dev src)))
    (when dev
      (ignore-errors (cl-inputs.device.api:disable-raw-char-mode dev))
      (ignore-errors (cl-inputs.device.api:disable-raw-mode dev))
      (ignore-errors (cl-inputs.device.api:close-device dev))))
  t)
