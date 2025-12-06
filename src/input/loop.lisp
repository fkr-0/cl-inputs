
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

;; (defstruct input-loop dev thread stop? decoder sink)

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


;; (defun start-input-loop (&key (device (cl-inputs.device.api:make-device :tty))
;;                           (sink (fn-sink
;;                                   (lambda (_tok)
;;                                     (declare (ignore _tok)) nil)))
;;                           (decoder (cl-inputs.decoder:make-decoder)))
;;   "Reads from DEVICE, decodes via DECODER, pushes to SINK. Returns an INPUT-LOOP handle."
;;   (cl-inputs.device.api:enable-raw-mode device)
;;   (let ((in-loop (make-input-loop :dev device :sink sink :decoder decoder)))
;;     (setf (input-loop-thread in-loop)
;;       (bt:make-thread
;;         (lambda ()
;;           (let ((buf (make-array 64 :element-type '(unsigned-byte 8))))
;;             (unwind-protect
;;               (loop until (input-loop-stop? in-loop) do
;;                 (let ((n (cl-inputs.device.api:device-read-bytes device buf 0 (length buf))))
;;                   (when (or (eql n :eof) (null n)) (return))
;;                   (multiple-value-bind (tokens dec2)
;;                     (cl-inputs.decoder:decode-chunk (input-loop-decoder in-loop)
;;                       (subseq buf 0 n))
;;                     (log-debug "Decoded ~A tokens from ~A bytes" (length tokens) n)
;;                     (setf (input-loop-decoder in-loop) dec2)
;;                     (dolist (to tokens) (%deliver (input-loop-sink in-loop) to)))))
;;               (cl-inputs.device.api:disable-raw-mode device))))
;;         :name "cl-inputs.loop"))
;;     in-loop))



;; == cl-inputs/src/input-loop.lisp ==
;; (in-package :cl-inputs)

;;; NOTE:
;;; - Expects these accessors on IN-LOOP: INPUT-LOOP-DEV, INPUT-LOOP-DECODER,
;;;   INPUT-LOOP-SINK, INPUT-LOOP-STOP?, INPUT-LOOP-LAST-OUTPUT,
;;;   INPUT-LOOP-CONDITION (bt:condition-variable),
;;;   INPUT-LOOP-CONDITION-LOCK (bt:lock)  ; <-- if you currently only have a condition,
;;;                                        ;     add a dedicated lock in your loop struct.
;;;
;;; - DEVICE API contract (must be true for consistency):
;;;   cl-inputs.device.api:device-read-bytes returns:
;;;     * a non-negative integer N = number of octets read,
;;;     * 0 when nonblocking/EAGAIN (no data right now),
;;;     * :EOF (keyword) on end-of-file / hangup,
;;;     * may signal ERROR on hard failures (we catch & log).
;;;
;;; - DECODER contract:
;;;   (cl-inputs.decoder:decode-chunk DEC (u8-vector)) => (values tokens new-decoder)

;; (defun input-loop-main (in-loop &key (sync nil) (bufsize 1) (idle-sleep 0.005))
;;   "Main loop for reading, decoding, and delivering input.
;; If SYNC is true, signal a condition variable after each delivered token.
;; BUFSIZE controls raw read size; IDLE-SLEEP throttles the loop on EAGAIN."
;;   (let* ((device  (input-loop-dev in-loop))
;;           (decoder (or (input-loop-decoder in-loop)
;;                      (cl-inputs.decoder:make-decoder)))
;;           ;; Raw octet buffer reused per iteration
;;           (buf     (make-array bufsize :element-type '(unsigned-byte 8))))
;;     (log-info "Input loop started on device ~A (sync: ~A, bufsize: ~A)" device sync bufsize)
;;     (unwind-protect
;;       (handler-case
;;         (loop until (input-loop-stop? in-loop) do
;;           (progn
;;             (log-info "Input loop iteration on device ~A" device)
;;             (let ((n (cl-inputs.device.api:device-read-bytes device buf 0 bufsize)))
;;               (log-info "Read ~A from device ~A" n device)
;;               (cond
;;                 ;; EOF / hangup → exit loop cleanly
;;                 ((or (eql n :eof) (null n))
;;                   (log-warn "Input loop: device returned ~A — terminating." n)
;;                   (return))

;;                 ;; No bytes (nonblocking EAGAIN) → brief idle to avoid busy spin
;;                 ((and (integerp n) (zerop n))
;;                   (when (plusp idle-sleep) (sleep idle-sleep)))

;;                 ;; Received N bytes → decode and deliver tokens
;;                 ((and (integerp n) (> n 0))
;;                   ;; Slice the buffer to the bytes actually read, pass to pure decoder.
;;                   (multiple-value-bind (tokens dec2)
;;                     (cl-inputs.decoder:decode-chunk decoder (subseq buf 0 n))
;;                     (setf decoder dec2
;;                       (input-loop-decoder in-loop) dec2)
;;                     (log-debug "Decoded ~A tokens from ~A bytes" (length tokens) n)
;;                     (dolist (tok tokens)
;;                       (setf (input-loop-last-output in-loop) tok)
;;                       (log-debug "Delivering token ~A" tok)
;;                       (%deliver (input-loop-sink in-loop) tok)
;;                       (when sync
;;                         ;; Prefer signaling under a lock. If your loop struct doesn’t yet carry
;;                         ;; a lock, add INPUT-LOOP-CONDITION-LOCK and use it here.
;;                         (log-info "Signaling condition variable for token ~A" tok)
;;                         (let ((cond (input-loop-condition in-loop))
;;                                (lock (ignore-errors (input-loop-condition-lock in-loop))))
;;                           (if lock
;;                             (bt:with-lock-held (lock)
;;                               (bt:condition-notify cond))
;;                             ;; Fallback: notify without lock (works on some impls but less robust).
;;                             (bt:condition-notify cond)))))))

;;                 ;; Unexpected return → log & continue (defensive)
;;                 (t
;;                   (log-warn "Input loop: unexpected read result ~S" n))))))
;;         (error (e)
;;           (log-error "Input loop error: ~A" e)))
;;       ;; Always leave raw mode off on exit.
;;       (cl-inputs.device.api:disable-raw-mode device))))
;; == end/input-loop.lisp ==

;; == cl-inputs/src/input-loop.lisp ==

;; Expect these accessors on IN-LOOP object:
;;   INPUT-LOOP-DEV
;;   INPUT-LOOP-DECODER
;;   INPUT-LOOP-SINK
;;   INPUT-LOOP-STOP?
;;   INPUT-LOOP-LAST-OUTPUT
;;   INPUT-LOOP-CONDITION (optional)
;;   INPUT-LOOP-CONDITION-LOCK (optional)

;; (defun %maybe-signal (in-loop)
;;   (let ((cond (ignore-errors (slot-value in-loop 'condition)))
;;          (lock (ignore-errors (slot-value in-loop 'condition-lock))))
;;     (when cond
;;       (if lock
;;         (bt:with-lock-held (lock) (bt:condition-notify cond))
;;         (bt:condition-notify cond)))))

;; (defun input-loop-main (in-loop &key (sync nil) (poll-timeout-ms 200))
;;   "Blocking loop using device-wait-readable (SB-SYS:WAIT-UNTIL-FD-USABLE on SBCL).
;;    VMIN=1/VTIME=0 makes buffer size irrelevant to latency."
;;   (let* ((dev     (input-loop-dev in-loop))
;;           (decoder (or (input-loop-decoder in-loop) (make-decoder)))
;;           (buf     (make-array 2048 :element-type '(unsigned-byte 8))))
;;     (log-info "Input loop starting on ~A" (device-kind dev))
;;     (unwind-protect
;;       (handler-case
;;         (progn
;;           (open-device dev)
;;           (with-raw-char-mode (dev :vmin 1 :vtime 0 :canonical nil :echo nil :isig t)
;;             (device-set-nonblocking dev t)
;;             (loop until (input-loop-stop? in-loop) do
;;               (when (device-wait-readable dev poll-timeout-ms)
;;                 (let ((n (device-read-bytes dev buf 0 (length buf))))
;;                   (cond
;;                     ((eql n :eof) (log-warn "EOF on input device.") (return))
;;                     ((= n 0)      nil) ; spurious wake
;;                     (t
;;                       (multiple-value-bind (tokens dec2)
;;                         (decode-chunk decoder (subseq buf 0 n))
;;                         (setf decoder dec2 (input-loop-decoder in-loop) dec2)
;;                         (dolist (tok tokens)
;;                           (setf (input-loop-last-output in-loop) tok)
;;                           (%deliver (input-loop-sink in-loop) tok)
;;                           (when sync
;;                             (let ((cond (ignore-errors (slot-value in-loop 'condition)))
;;                                    (lock (ignore-errors (slot-value in-loop 'condition-lock))))
;;                               (if lock
;;                                 (bt:with-lock-held (lock) (bt:condition-notify cond))
;;                                 (when cond (bt:condition-notify cond))))))))))))))
;;         (error (e) (log-error "Input loop error: ~A" e)))
;;       (ignore-errors (device-set-nonblocking dev nil))
;;       (ignore-errors (disable-raw-char-mode dev))
;;       (ignore-errors (close-device dev))
;;       (log-info "Input loop exited."))))
;; (defun input-loop-main (in-loop &key (sync nil) (poll-timeout-ms 200))
;;   "Blocking loop: waits with poll/select for readability → reads octets → decodes → delivers tokens.
;; Poll timeout keeps the loop responsive to stop flags.
;; Buffer size is internal and irrelevant to latency thanks to VMIN=1.
;; Idempotent raw-mode handling and nonblocking I/O are set internally."
;;   (let* ((dev     (input-loop-dev in-loop))
;;           (decoder (or (input-loop-decoder in-loop) (make-decoder)))
;;           ;; internal buffer only caps max chunk size when burst data is present (paste/resize)
;;           (buf     (make-array 2048 :element-type '(unsigned-byte 8))))
;;     (log-info "Input loop starting on ~A" (device-kind dev))
;;     (unwind-protect
;;       (handler-case
;;         (progn
;;           ;; Ensure device open + raw per-byte readiness + nonblocking read
;;           (open-device dev)
;;           (with-raw-char-mode (dev :vmin 1 :vtime 0 :canonical nil :echo nil :isig t)
;;             (device-set-nonblocking dev t)
;;             (loop until (input-loop-stop? in-loop) do
;;               ;; Wait until readable; timeout allows checking stop? and other duties.
;;               (when (device-wait-readable dev poll-timeout-ms)
;;                 (let ((n (device-read-bytes dev buf 0 (length buf))))
;;                   (cond
;;                     ((eql n :eof)
;;                       (log-warn "EOF on input device; terminating input loop.")
;;                       (return))
;;                     ((= n 0)
;;                       ;; nonblocking and no data; loop again
;;                       nil)
;;                     (t
;;                       (multiple-value-bind (tokens dec2)
;;                         (decode-chunk decoder (subseq buf 0 n))
;;                         (setf decoder dec2
;;                           (input-loop-decoder in-loop) dec2)
;;                         (when (plusp (length tokens))
;;                           (log-debug "Decoded ~D token(s) from ~D byte(s)" (length tokens) n))
;;                         (dolist (tok tokens)
;;                           (setf (input-loop-last-output in-loop) tok)
;;                           (%deliver (input-loop-sink in-loop) tok)
;;                           (when sync (%maybe-signal in-loop)))))))))))
;;         (error (e)
;;           (log-error "Input loop error: ~A" e)))
;;       ;; restore device modes idempotently; safe even if already restored
;;       (ignore-errors (device-set-nonblocking dev nil))
;;       (ignore-errors (disable-raw-char-mode dev))
;;       (ignore-errors (close-device dev))
;;       (log-info "Input loop exited."))))
;; == end/input-loop.lisp ==
;; == cl-inputs/src/input-loop.lisp ==
;; == cl-inputs/src/input-loop.lisp ==

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
        (device-set-nonblocking dev nil) ; blocking is fine + simpler with VMIN=1  :contentReference[oaicite:6]{index=6}
        (with-raw-char-mode (dev :vmin 1 :vtime 0 :canonical nil :echo nil :isig t)
          (loop until (input-loop-stop? in-loop) do
            (when (device-wait-readable dev wait-timeout-ms) ; sleep until readable  :contentReference[oaicite:7]{index=7}
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

;; (defun input-loop-main (in-loop &key (sync nil) (poll-timeout-ms 200))
;;   "Latency is independent of buffer size:
;;    - termios uses VMIN=1/VTIME=0 → read returns after *first* byte. :contentReference[oaicite:4]{index=4}
;;    - we perform exactly one read(2) per wake. :contentReference[oaicite:5]{index=5}
;;    - restore is guaranteed via unwind-protect + exit-hook. :contentReference[oaicite:6]{index=6}"
;;   (let* ((dev     (input-loop-dev in-loop))
;;           (decoder (or (input-loop-decoder in-loop) (make-decoder)))
;;           (buf     (make-array 1 :element-type '(unsigned-byte 8))))
;;     ;; install an exit hook to restore tty even on crashy exits (not :abort). :contentReference[oaicite:7]{index=7}
;;     (flet ((%restore ()
;;              (ignore-errors (cl-inputs.device.api:disable-raw-char-mode dev))
;;              (ignore-errors (cl-inputs.device.api:close-device dev))))
;;       (push #'%restore sb-ext:*exit-hooks*))
;;     (log-info "Input loop starting on ~A" (device-kind dev))
;;     (unwind-protect
;;       (handler-case
;;         (progn
;;           (open-device dev)
;;           ;; IMPORTANT: keep the fd in *blocking* mode; VMIN=1 handles latency.
;;           ;; Nonblocking + read-sequence refill was the source of your stalls. :contentReference[oaicite:8]{index=8}
;;           (device-set-nonblocking dev nil)
;;           (with-raw-char-mode (dev :vmin 1 :vtime 0 :canonical nil :echo nil :isig t)
;;             (loop until (input-loop-stop? in-loop) do
;;               (when (device-wait-readable dev poll-timeout-ms)
;;                 (let ((n (device-read-bytes dev buf 0 (length buf))))
;;                   (cond
;;                     ((eql n :eof) (log-warn "EOF; exiting loop.") (return))
;;                     ((or (null n) (zerop n)) nil)
;;                     (t
;;                       (multiple-value-bind (tokens dec2)
;;                         (decode-chunk decoder (subseq buf 0 n))
;;                         (setf decoder dec2
;;                           (input-loop-decoder in-loop) dec2)
;;                         (log-debug "Decoded ~D token(s) from ~D byte(s)" (length tokens) n)
;;                         (dolist (tok tokens)
;;                           (setf (input-loop-last-output in-loop) tok)
;;                           (%deliver (input-loop-sink in-loop) tok)
;;                           (when sync (%maybe-signal in-loop)))))))))))
;;         (error (e)
;;           (log-error "Input loop error: ~A" e)))
;;       ;; robust cleanup
;;       (ignore-errors (device-set-nonblocking dev nil))
;;       (ignore-errors (disable-raw-char-mode dev))
;;       (ignore-errors (close-device dev))
;;       (log-info "Input loop exited."))))
;; == end/input-loop.lisp ==

;; (defun input-loop-main (in-loop &key (sync nil) (poll-timeout-ms 200))
;;   (let* ((dev     (input-loop-dev in-loop))
;;           (decoder (or (input-loop-decoder in-loop) (make-decoder)))
;;           (buf     (make-array 1 :element-type '(unsigned-byte 8))))
;;     (log-info "Input loop starting on ~A" (device-kind dev))
;;     (unwind-protect
;;       (handler-case
;;         (progn
;;           ;; open first so slots are bound, then enter raw char mode
;;           (open-device dev)
;;           (with-raw-char-mode (dev :vmin 1 :vtime 0 :canonical nil :echo nil :isig t)
;;             (device-set-nonblocking dev t)
;;             (loop until (input-loop-stop? in-loop) do
;;               (when (device-wait-readable dev poll-timeout-ms)
;;                 (let ((n (device-read-bytes dev buf 0 (length buf))))
;;                   (cond
;;                     ((eql n :eof) (log-warn "EOF on device; exiting.") (return))
;;                     ((= n 0)      nil)
;;                     (t
;;                       (multiple-value-bind (tokens dec2)
;;                         (decode-chunk decoder (subseq buf 0 n))
;;                         (setf decoder dec2 (input-loop-decoder in-loop) dec2)
;;                         (dolist (tok tokens)
;;                           (log-info "Delivering token ~A" tok)
;;                           (setf (input-loop-last-output in-loop) tok)
;;                           (%deliver (input-loop-sink in-loop) tok)
;;                           (when sync
;;                             (let ((cond (ignore-errors (slot-value in-loop 'condition)))
;;                                    (lock (ignore-errors (slot-value in-loop 'condition-lock))))
;;                               (if (and cond lock)
;;                                 (bt:with-lock-held (lock) (bt:condition-notify cond))
;;                                 (when cond (bt:condition-notify cond))))))))))))))
;;         (error (e)
;;           (log-error "Input loop error: ~A" e)))
;;       ;; idempotent cleanup
;;       (ignore-errors (device-set-nonblocking dev nil))
;;       (ignore-errors (disable-raw-char-mode dev))
;;       (ignore-errors (close-device dev))
;;       (log-info "Input loop exited."))))


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

;;; Pull mode: a source object that yields tokens on demand
;; (defstruct (input-source
;; :constructor make-input-source)
;;   "A source of input tokens, reading from a device and decoding them."
;;   (dev nil :type cl-inputs.device.api:device)
;;   (decoder nil :type cl-inputs.decoder:decoder)
;;   (buf nil :type (array (unsigned-byte 8) (*)) :read-only t))
(defstruct (input-source (:constructor %make-input-source))
  "A source of input tokens, typically from a device.

Fields:
  DEV     -- device object (type: device)
  DECODER -- decoder state (type: decoder)
  BUF     -- buffer for input bytes (type: (array (unsigned-byte 8) *))

All fields are required."
  dev decoder buf)

(defmethod print-object ((src input-source) stream)
  (format stream "#<INPUT-SOURCE dev=~A decoder=~A buf-size=~A>"
    (input-source-dev src)
    (input-source-decoder src)
    (array-total-size (input-source-buf src))))

(defvar *default-input-source* nil
  "Default input source for cl-inputs.")
(defun get-input-source ()
  "Get the default input source, creating it if necessary."
  (or *default-input-source*
    ))
(defun make-input-source (&key (device (cl-inputs.device.api:make-device :tty))
                           (decoder (cl-inputs.decoder:make-decoder)))
  (cl-inputs.device.api:open-device device)
  (ignore-errors (cl-inputs.device.api:enable-raw-char-mode device))
  (ignore-errors (cl-inputs.device.api:enable-raw-mode device))
  (let ((src (%make-input-source :dev device :decoder decoder
               :buf (make-array 4096 :element-type '(unsigned-byte 8)))))
    (setf *default-input-source* src)
    src))

;; override array printer
(defmethod print-object ((arr array) stream)
  ;; prevent recursive printing while printing arr
  (let ((*print-readably* nil)
         (*print-level* nil)
         (*print-length* nil))
    ;; Detect element type if you want different behaviours
    (cond
      ((equal (array-element-type arr) '(unsigned-byte 8))
        (format stream "#<UB8 ~D bytes: "
          (array-total-size arr))
        ;; print first few bytes as hex
        (let ((limit (min 16 (array-total-size arr))))
          (dotimes (i limit)
            (format stream "~2,'0X " (aref arr i))))
        (when (> (array-total-size arr) 16)
          (format stream "..."))
        (format stream ">"))
      (t
        ;; fallback to default
        (call-next-method)))))


(defun next-token (src &key timeout)
  "Blocking read (or timed if DEVICE supports it). Returns a token or NIL on EOF."
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
            (first tokens)))))))

(defun close-input-source (src)
  (let ((dev (input-source-dev src)))
    (when dev
      (ignore-errors (cl-inputs.device.api:disable-raw-char-mode dev))
      (ignore-errors (cl-inputs.device.api:disable-raw-mode dev))
      (ignore-errors (cl-inputs.device.api:close-device dev))))
  t)
