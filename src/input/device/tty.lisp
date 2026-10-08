;;; ---------------------------------------------------------------------------
;;; LEGACY/COMMENTED-OUT CODE BELOW -- retained for reference and migration only.
;;; ---------------------------------------------------------------------------
;; (uiop:define-package :cl-inputs.device.tty
;;   (:use :cl :alexandria )
;;   (:import-from
;;     #:cl-inputs.util #:as-utf-8-bytes #:string-to-utf-8-bytes)
;;   (:import-from #:sb-ext #:run-program  #:process-pid #:process-pty #:process-kill)
;;   (:import-from #:sb-sys #:make-fd-stream #:fd-stream-fd)
;;   (:use #:sb-unix)

;;   ;; #:sb-posix #:termios #:tcgetattr #:tcsetattr
;;   ;;             #:tcsanow #:icanon #:echo #:vmin #:vtime
;;   (:import-from :cl-inputs.device.api
;;     ;; Device port generics
;;     #:make-device
;;     #:device-kind
;;     #:open-device #:close-device
;;     #:enable-raw-mode #:disable-raw-mode
;;     #:device-read-bytes #:device-write-bytes
;;     #:device-capabilities
;;     #:device-set-modes))

;; (in-package :cl-inputs.device.tty)


;; (defstruct (tty-device (:constructor %make-tty-device))
;;   path
;;   in
;;   out
;;   (raw-enabled? nil)
;;   original-termios)

;; (defun %open-stream (path direction)
;;   (open path
;;     :direction direction
;;     :element-type '(unsigned-byte 8)
;;     :if-does-not-exist :error))

;; ;; (defun %close-stream (stream)
;; ;;   (when (and stream (streamp stream) (not (closed-stream-p stream)))
;; ;;     (close stream)))

;; (defmethod initialized-p ((dev tty-device))
;;   (and (tty-device-in dev) (tty-device-out dev)))
;; ;; (asdf:load-system :sb-posix)
;; ;; (use-package :sb-posix)
;; (defun %termios-raw-mode (fd enable-p &optional original-termios)
;;   (if enable-p
;;     (let ((orig (the sb-posix:termios (sb-posix:tcgetattr fd))))
;;       (let ((new (the sb-posix:termios (sb-int:sys-copy-struct orig))))
;;         (setf (sb-posix:termios-lflag new)
;;           (logand (sb-posix:termios-lflag new)
;;             (lognot sb-posix:icanon)
;;             (lognot sb-posix:echo)))
;;         (setf (aref (sb-posix:termios-cc new) sb-posix:vmin) 0
;;           (aref (sb-posix:termios-cc new) sb-posix:vtime) 1)
;;         (sb-posix:tcsetattr fd sb-posix:tcsanow new)
;;         orig))
;;     (when original-termios
;;       (sb-posix:tcsetattr fd sb-posix:tcsanow original-termios))))

;; (defun %tty-capabilities ()
;;   (list :truecolor t :mouse :sgr :paste t :focus t :winch t :term (uiop:getenv "TERM")))

;; ;; (register-backend :tty
;; ;;   (lambda (&key (path "/dev/tty"))
;; ;;     (make-tty-device :path path)))

;; (defmethod device-kind ((dev tty-device)) :tty)

;; (defmethod open-device ((dev tty-device))
;;   (let ((in (%open-stream (tty-device-path dev) :input))
;;          (out (%open-stream (tty-device-path dev) :output)))
;;     (setf (tty-device-in dev) in
;;       (tty-device-out dev) out)
;;     dev))

;; (defmethod close-device ((dev tty-device))
;;   (when (tty-device-in dev)
;;     (ignore-errors (close (tty-device-in dev))))
;;   (when (tty-device-out dev)
;;     (ignore-errors (close (tty-device-out dev))))
;;   t)

;; (define-condition termios-raw-mode-error (error)
;;   ((device :initarg :device :reader tty-device-error-device)
;;     (message :initarg :message :reader tty-device-error-message)))

;; (defmethod enable-raw-mode ((dev tty-device))
;;   (unless (initialized-p dev)
;;     ;; (error 'termios-raw-mode-error
;;     ;;        :device dev
;;     ;;        :message "TTY device not initialized; cannot enable raw mode.")
;;     (open-device dev)
;;     )
;;   (let* ((fd (sb-sys:fd-stream-fd (tty-device-in dev)))
;;           (tos (%termios-raw-mode fd t)))
;;     (unless tos
;;       (error 'termios-raw-mode-error
;;         :device dev
;;         :message "Failed to set raw mode on TTY device."))
;;     (when tos (setf (tty-device-original-termios dev) tos)
;;       (setf (tty-device-raw-enabled? dev) t))))

;; (defmethod disable-raw-mode ((dev tty-device))
;;   (when (tty-device-raw-enabled? dev)
;;     (let ((fd (sb-sys:fd-stream-fd (tty-device-in dev))))
;;       (%termios-raw-mode fd nil (tty-device-original-termios dev))
;;       (setf (tty-device-raw-enabled? dev) nil))))




;; (defun read-seq-from-fd (fd)
;;   "Read input from the terminal file descriptor until an interaction is parsed."
;;   (let ((alt-pressed nil)
;;          (state :normal))
;;     (loop
;;       (let ((byte (read-byte fd nil nil)))
;;         (log:debug "Read byte: ~a" byte)
;;         (cond
;;           ;; ESC: could be alt or start of escape sequence
;;           ((= byte (char-code #\Esc))
;;             (cond
;;               ((eq state :alt)
;;                 (setf alt-pressed nil
;;                   state :normal))
;;               (t
;;                 (setf alt-pressed t
;;                   state :escape))))
;;           ;; '[' or ']': possible start of escape sequence
;;           ((and (eq state :escape)
;;              (member byte (list (char-code #\[) (char-code #\]))))
;;             (let ((esc-seq (read-escape-sequence-bytes fd)))
;;               (setf state :normal)
;;               (log:debug "Escape sequence received: ~a" esc-seq)
;;               (return esc-seq)))
;;           ;; '~' or backspace: regular keys
;;           ((or (= byte (char-code #\~))
;;              (= byte 8)
;;              (= byte 127))
;;             (setf state :normal)
;;             (return (input-seq-from-input byte alt-pressed)))
;;           ;; Unexpected byte in escape state
;;           ((eq state :escape)
;;             (setf state :normal)
;;             (log:warn "Unexpected byte in escape sequence: ~a" byte))
;;           ;; All other bytes: normal input
;;           (t
;;             (setf state :normal)
;;             (return (input-seq-from-input byte alt-pressed))))))))
;; (defmethod device-read-bytes ((dev tty-device) buffer start end)
;;   (read-sequence buffer (tty-device-in dev) :start start :end end))
;; (defmethod read-seq-from-fd ((term low-level-terminal))
;;   "Read input from the terminal file descriptor until an interaction is parsed."
;;   (with-slots (fd) term
;;     (let ((alt-pressed nil)
;;           (in-escape-sequence nil)) ;; Track if we're in the middle of an escape sequence
;;       ;; Reading from terminal in raw mode
;;       (loop
;;         (let ((byte (read-byte fd nil nil)))
;;           (log:info "Read byte: ~a" byte)
;;           (cond
;;             ;; Handle the Escape character initiating an escape sequence
;;             ((= (char-code #\Esc) byte)
;;              (if alt-pressed
;;                  (setf alt-pressed nil)
;;                  ;; Set state to be ready for an escape sequence
;;                  (progn (setf alt-pressed t)
;;                         (setf in-escape-sequence t))))

;;             ;; Handle '[' or other escape sequence characters
;;             ((and in-escape-sequence
;;                   (or (= (char-code #\[) byte) (= (char-code #\]) byte)))
;;              ;; Read escape sequence, likely for a special key
;;              (let ((esc-seq (read-escape-sequence-bytes fd)))
;;                ;; Reset escape state
;;                (setf in-escape-sequence nil)
;;                ;; Process escape sequence (e.g., arrow keys, Delete)
;;                (log:info "Escape sequence received: ~a" esc-seq)
;;                (return esc-seq)))

;;             ;; Handle regular tilde key
;;             ((and (= (char-code #\~) byte) (not in-escape-sequence))
;;              ;; If we are not in an escape sequence, treat '~' as a regular key
;;              (log:info "Regular tilde key pressed")
;;              (return (input-seq-from-input byte alt-pressed)))

;;             ;; Handle Backspace (usually sends ASCII 8 or 127)
;;             ((or (= 8 byte) (= 127 byte))
;;              (log:info "Backspace pressed")
;;              (return (input-seq-from-input byte alt-pressed)))

;;             ;; If we are in the middle of an escape sequence but receive an unexpected character
;;             ((and in-escape-sequence
;;                   (not (member byte (list (char-code #\[) (char-code #\])))))
;;              ;; Unexpected character, reset the escape sequence state
;;              (setf in-escape-sequence nil)
;;              (log:warn "Unexpected byte while reading escape sequence: ~a" byte))

;;             ;; Handle other normal characters
;;             (t
;;              ;; Reset in-escape-sequence if not in it
;;              (setf in-escape-sequence nil)
;;              (return (input-seq-from-input byte alt-pressed)))))))))


;; (defmethod device-capabilities ((dev tty-device))
;;   (%tty-capabilities))

;; (defmethod device-set-modes ((dev tty-device) modes)
;;   (let ((stream (tty-device-out dev)))
;;     (when (getf modes :mouse)
;;       (write-sequence (string-to-utf-8-bytes
;;                         (if (eq (getf modes :mouse) :sgr)
;;                           "[?1006h[?1003h" ; SGR + any
;;                           "[?9h")) ; X10
;;         stream))
;;     (when (getf modes :paste)
;;       (write-sequence (string-to-utf-8-bytes "[?2004h") stream))
;;     (when (getf modes :focus)
;;       (write-sequence (string-to-utf-8-bytes "[?1004h") stream))
;;     (finish-output stream)))


;; == cl-inputs/src/device.lisp ==
;; == cl-inputs/src/device/tty.lisp ==
(uiop:define-package :cl-inputs.device.tty
  (:use :cl :alexandria :cl-inputs.device.api)
  (:import-from :sb-posix
    #:tcgetattr #:tcsetattr #:tcsanow
    #:termios #:termios-iflag #:termios-oflag #:termios-cflag #:termios-lflag #:termios-cc
    ;; input flags
    #:ignbrk #:brkint #:icrnl #:inlcr #:istrip #:ixon #:ixoff #:parmrk
    ;; output flags
    ;; #:opost
    ;; ;; control flags
    ;; #:cs8
    ;; ;; local flags
    ;; #:icanon ;; #:echo 
    ;; #:echoe #:echok #:echonl #:isig
    ;; open flags / poll
    ;; #:open
    #:o_rdonly #:o_wronly #:fcntl #:f_getfl #:f_setfl #:o_nonblock
    #:poll #:pollfd #:pollin)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes #:write-output)
  (:import-from :uiop #:getenv)
  (:import-from :cl-inputs.terminal.ansii #:get-sequence #:render-seq)
  (:import-from :cl-inputs.terminal.api
    #:get-terminal-size
    #:clear-screen #:clear-area #:draw-text-at #:draw-char-at
    #:fill-rectangle #:scroll-lines #:set-cursor-position #:get-cursor-position
    #:hide-cursor #:show-cursor #:flush-output #:apply-style #:reset-style
    #:with-styled-output #:%emit-ansi #:%style->sgr-string #:+esc+)
  (:export #:make-tty-device #:tty-device #:tty-device-path))
(in-package :cl-inputs.device.tty)
(defun device-open-fd-stream (fd)
  "Return a binary input stream over FD with element-type (unsigned-byte 8).
   Choose buffering to taste; :none gives you low-latency edges."
  #+sbcl
  (sb-sys:make-fd-stream fd :input t :output t
    :element-type '(unsigned-byte 8)
    :buffering :none)
  #+ccl
  (ccl:make-fd-stream fd :direction :input
    :element-type '(unsigned-byte 8)
    :sharing :exclusive
    :external-format :binary)
  #-(or sbcl ccl)
  (error "device-open-fd-stream not implemented for this Lisp. Please add a backend."))
(defclass tty-device (cl-inputs.device.api:lockable)
  ((path
     :initarg :path
     :accessor tty-device-path
     :initform "/dev/tty"
     :documentation "Path to the TTY device (type: string, default: /dev/tty)")
    (in
      :accessor %tty-in
      :initform nil
      :documentation "Input stream (type: stream or nil)")
    (out
      :accessor %tty-out
      :initform nil
      :documentation "Output stream (type: stream or nil)")
    (orig-termios
      :accessor %tty-orig-termios
      :initform nil
      :documentation "Original terminal settings (type: termios struct or nil)")
    (raw-depth
      :accessor %tty-raw-depth
      :initform 0
      :documentation "Nesting counter for raw char mode (type: integer)")
    (nonblock?
      :accessor %tty-nonblock?
      :initform nil
      :documentation "Non-blocking mode flag (type: boolean or nil)")
    (width
      :accessor %tty-width
      :initform 80
      :documentation "Cached terminal width (type: integer)")
    (height
      :accessor %tty-height
      :initform 24
      :documentation "Cached terminal height (type: integer)")
    (cursor-row
      :accessor %tty-cursor-row
      :initform 0
      :documentation "Last known cursor row (0-based).")
    (cursor-col
      :accessor %tty-cursor-col
      :initform 0
      :documentation "Last known cursor column (0-based).")
    (cursor-visible?
      :accessor %tty-cursor-visible?
      :initform t
      :documentation "Track cursor visibility flag.")
    (current-style
      :accessor %tty-current-style
      :initform nil
      :documentation "Last style plist applied via APPLY-STYLE.")))

(defun make-tty-device (&key (path "/dev/tty"))
  (make-instance 'tty-device :path path))

(defmethod make-device ((backend (eql :tty)) &key (path "/dev/tty") &allow-other-keys)
  (declare (ignore backend))
  (let  ((device (make-tty-device :path path)))
    (open-device device)
    device
    ;; setup inputsrc outputsrc, ...
    ;; (setf (%tty-in device) nil
    ;;   (%tty-out device) nil
    ;;   (%tty-orig-termios device) nil
    ;;   (%tty-raw-depth device) 0
    ;;   (%tty-nonblock? device) nil
    ;;   (%tty-width device) 80
    ;;   (%tty-height device) 24
    ;;   (%tty-cursor-row device) 0
    ;;   (%tty-cursor-col device) 0
    ;;   (%tty-cursor-visible? device) t
    ;;   (%tty-current-style device) nil)
    ))

(defmethod device-kind ((dev tty-device)) :tty)


;; small guard that never signals unbound-slot:
(defun %stream-or-nil (slot-reader dev)
  (if (slot-boundp dev (sb-mop:slot-definition-name
                         (find (symbol-name slot-reader)
                           (sb-mop:class-slots (type-of dev))
                           :key (lambda (s) (symbol-name (sb-mop:slot-definition-readers s)))
                           :test #'string=)))
    (funcall slot-reader dev)
    nil))

(defun %device-read-bytes (stream buffer start end)
  "Read raw octets into BUFFER[start,end) from binary STREAM.
   Return number of bytes read (0 for EAGAIN on nonblocking)."
  (declare (type (simple-array (unsigned-byte 8) (*)) buffer))
  (let ((n (read-sequence buffer stream :start start :end end)))
    (- n start)))
;; ;; == end/device.lisp ==

;; (defmethod device-read-bytes ((dev tty-device) buffer start end)
;;   (%device-read-bytes (%tty-in dev) buffer start end))
;; (defmethod device-read-bytes ((dev tty-device) buffer start end)
;;   "Exactly one read(2) into BUFFER[START,END). No stream refill, no loops."
;;   (declare (type (simple-array (unsigned-byte 8) (*)) buffer)
;;     (type fixnum start end))
;;   (%ensure-open-device dev)
;;   (let* ((count (- end start))
;;           ;; Create a simple, specialized u8 view into BUFFER starting at START.
;;           ;; Displaced arrays are fine for sb-posix:read (no copy).
;;           (view  (make-array count
;;                    :element-type '(unsigned-byte 8)
;;                    :displaced-to buffer
;;                    :displaced-index-offset start
;;                    :adjustable nil
;;                    :fill-pointer nil))
;;           ;; sb-posix:read signature: (read fd u8-vector &optional count)
;;           ;; It returns number of octets read, or 0 on EOF.
;;           (n     (sb-posix:read (device-fd dev) view count)))
;;     (cond ((= n 0) :eof)
;;       (t n))))


(defun %ensure-open-device (dev)
  (unless (and (%tty-in dev) (%tty-out dev))
    (open-device dev))
  (values (%tty-in dev) (%tty-out dev)))

(defmethod initialized-p ((dev tty-device))
  (and (%tty-in dev) (%tty-out dev)))

(defmethod open-device ((dev tty-device))
  ;; Terminal startup must not emit INFO messages into the application screen.
  (log:debug "Opening TTY device at path ~a" (tty-device-path dev))
  (unless (initialized-p dev)
    (let ((p (tty-device-path dev))
          (fd-in nil)
          (fd-out nil)
          (in nil)
          (out nil))
      (handler-case
        (progn
          (setf fd-in (sb-posix:open p sb-posix:o-rdonly)
                in (device-open-fd-stream fd-in))
          ;; MAKE-FD-STREAM owns FD after successful construction.
          (setf fd-in nil)
          (setf fd-out (sb-posix:open p sb-posix:o-wronly)
                out (device-open-fd-stream fd-out))
          (setf fd-out nil)
          (setf (%tty-in dev) in
                (%tty-out dev) out))
        (error (condition)
          (when in (ignore-errors (close in)))
          (when out (ignore-errors (close out)))
          (when fd-in (ignore-errors (sb-posix:close fd-in)))
          (when fd-out (ignore-errors (sb-posix:close fd-out)))
          (setf (%tty-in dev) nil
                (%tty-out dev) nil)
          (error condition)))))
  dev)

(defmethod close-device ((dev tty-device))
  ;; The concrete device also restores raw state so direct owners cannot leak it.
  (ignore-errors (disable-raw-char-mode dev))
  (when (%tty-in dev)
    (ignore-errors (close (%tty-in dev)))
    (setf (%tty-in dev) nil))
  (when (%tty-out dev)
    (ignore-errors (close (%tty-out dev)))
    (setf (%tty-out dev) nil))
  (setf (%tty-nonblock? dev) nil)
  t)

(defmethod device-input-stream  ((dev tty-device)) (%tty-in dev))
(defmethod device-output-stream ((dev tty-device)) (%tty-out dev))
(defmethod device-fd ((dev tty-device))
  (let ((in (%tty-in dev)))
    (and in (sb-sys:fd-stream-fd in))))

#+sbcl
(progn
  (declaim (inline %tty-read-into-buffer))
  (defun %tty-read-into-buffer (fd buffer start count stream)
    "Low-level helper to copy COUNT bytes from FD into BUFFER at START."
    (declare (ignore stream)
      (type (simple-array (unsigned-byte 8) (*)) buffer)
      (type fixnum start count))
    (sb-sys:with-pinned-objects (buffer)
      (let* ((sap (sb-sys:vector-sap buffer))
              (target (sb-sys:sap+ sap start)))
        (sb-posix:read fd target count)))))

#-sbcl
(defun %tty-read-into-buffer (fd buffer start count stream)
  (declare (ignore fd)
    (type (simple-array (unsigned-byte 8) (*)) buffer)
    (type fixnum start count)
    (type stream stream))
  (let ((limit (read-sequence buffer stream :start start :end (+ start count))))
    (- limit start)))

;; == cl-inputs/device/tty.lisp ==
;; 1) RAW mode: DO NOT touch c_oflag (keep OPOST).
;; 2) Block mode + VMIN=1, VTIME=0 (per-byte readiness, independent of buffer length).
;; 3) device-read-bytes: one POSIX read(2), never read-sequence.

(defmethod enable-raw-char-mode ((dev tty-device)
                                  &key (vmin 1) (vtime 0) (canonical nil) (echo nil) (isig t))
  (%ensure-open-device dev)
  (let* ((fd (device-fd dev)))
    (if (plusp (%tty-raw-depth dev))
      (incf (%tty-raw-depth dev))
      (let* ((orig (sb-posix:tcgetattr fd))
              ;; SB-POSIX termios is a foreign-backed structure. SYS-COPY-STRUCT
              ;; aliases its backing storage on supported SBCL builds, so
              ;; mutating that 'copy' also destroys our restoration snapshot.
              ;; Read a separate termios object for mutation instead.
              (tos (sb-posix:tcgetattr fd))
              (cc (sb-posix:termios-cc tos)))
        ;; INPUT flags: strip translations/flow-ctrl
        (setf (sb-posix:termios-iflag tos)
          (logand (sb-posix:termios-iflag tos)
            (lognot (logior sb-posix:ignbrk sb-posix:brkint sb-posix:icrnl
                      sb-posix:inlcr  sb-posix:istrip sb-posix:ixon
                      sb-posix:ixoff  sb-posix:parmrk))))
        ;; OUTPUT flags: leave OPOST AS-IS so logs print with CR/LF.  :contentReference[oaicite:3]{index=3}
        ;; (setf (sb-posix:termios-oflag tos) (sb-posix:termios-oflag tos))

        ;; CONTROL flags: 8-bit clean
        (setf (sb-posix:termios-cflag tos)
          (logior (logand (sb-posix:termios-cflag tos) (lognot sb-posix:cs8))
            sb-posix:cs8))
        ;; LOCAL flags: canonical+echo off, ISIG per arg
        (let ((l (sb-posix:termios-lflag tos)))
          (setf l (if canonical (logior l sb-posix:icanon) (logand l (lognot sb-posix:icanon))))
          (setf l (if echo      (logior l sb-posix:echo sb-posix:echoe sb-posix:echok sb-posix:echonl)
                    (logand l (lognot (logior sb-posix:echo sb-posix:echoe
                                        sb-posix:echok sb-posix:echonl)))))
          (setf l (if isig      (logior l sb-posix:isig) (logand l (lognot sb-posix:isig))))
          (setf (sb-posix:termios-lflag tos) l))
        ;; MIN/TIME: return as soon as ONE byte arrives (exactly what we want).  :contentReference[oaicite:4]{index=4}
        (setf (aref cc sb-posix:vmin) (the (unsigned-byte 8) vmin)
          (aref cc sb-posix:vtime) (the (unsigned-byte 8) vtime))
        (sb-posix:tcsetattr fd sb-posix:tcsanow tos)
        (setf (%tty-orig-termios dev) orig
          (%tty-raw-depth dev)    1))))
  t)

;; (defmethod device-read-bytes ((dev tty-device) buffer start end)
;;   "Exactly one read(2). No ‘refill’, ever."
;;   (declare (type (simple-array (unsigned-byte 8) (*)) buffer))
;;   (%ensure-open dev)
;;   (let* ((fd (device-fd dev))
;;           (n  (sb-posix:read fd buffer  (- end start)  ))) ;; single syscall  :contentReference[oaicite:5]{index=5}
;;     (cond
;;       ((= n 0) :eof)
;;       (t n)))
;;   )
(defun %tty-syscall-outcome (condition)
  (let ((errno (sb-posix:syscall-errno condition)))
    (cond
      ((= errno sb-posix:eintr) :interrupted)
      ((or (= errno sb-posix:eagain)
           (= errno sb-posix:ewouldblock))
       :would-block)
      (t nil))))

(defmethod device-read-bytes ((dev tty-device) buffer start end)
  "Perform exactly one read(2), returning a typed transient outcome when needed."
  (declare (type (integer 0 #.most-positive-fixnum) start end)
    (type (simple-array (unsigned-byte 8) (*)) buffer))
  (%ensure-open-device dev)
  (assert (<= 0 start end (length buffer)) (start end))
  (let ((count (- end start)))
    (cond
      ((zerop count) 0)
      (t
       (handler-case
           (let ((n (%tty-read-into-buffer
                     (device-fd dev) buffer start count (%tty-in dev))))
             (if (= n 0) :eof n))
         (sb-posix:syscall-error (condition)
           (or (%tty-syscall-outcome condition)
               (error condition))))))))

(defmethod device-write-bytes ((dev tty-device) buffer start end)
  (%ensure-open-device dev)
  (let ((stream (%tty-out dev)))
    (write-sequence buffer stream :start start :end end)
    (finish-output stream)
    (- end start)))

(defmethod disable-raw-char-mode ((dev tty-device))
  "Nestable + idempotent: only restore when depth goes 1→0; ignore extra disables."
  (cond
    ((zerop (%tty-raw-depth dev)) t)
    ((> (%tty-raw-depth dev) 1) (decf (%tty-raw-depth dev)) t)
    (t
      ;; depth == 1
      (let* ((stream (%tty-in dev))
              (fd     (and stream (sb-sys:fd-stream-fd stream)))
              (orig   (%tty-orig-termios dev)))
        (when (and fd orig) (sb-posix:tcsetattr fd sb-posix:tcsanow orig))
        (setf (%tty-orig-termios dev) nil
          (%tty-raw-depth dev) 0)
        t))))

(defmethod device-set-nonblocking ((dev tty-device) flag)
  (%ensure-open-device dev)
  (let* ((fd (sb-sys:fd-stream-fd (%tty-in dev)))
          (fl (sb-posix:fcntl fd sb-posix:f-getfl)))
    (setf fl (if flag (logior fl sb-posix:o-nonblock)
               (logand fl (lognot sb-posix:o-nonblock))))
    (sb-posix:fcntl fd sb-posix:f-setfl fl)
    (setf (%tty-nonblock? dev) (not (zerop (logand fl sb-posix:o-nonblock))))
    (%tty-nonblock? dev)))



;; Wait using SBCL’s public helper (secs = double-float); returns T/NIL. :contentReference[oaicite:1]{index=1}
(defmethod device-wait-readable ((dev tty-device) timeout-ms)
  (%ensure-open-device dev)
  (let* ((fd (sb-sys:fd-stream-fd (%tty-in dev)))
          (secs (and timeout-ms (/ (coerce timeout-ms 'double-float) 1000d0))))
    (handler-case
        (sb-sys:wait-until-fd-usable fd :input secs)
      (sb-posix:syscall-error (condition)
        (or (%tty-syscall-outcome condition)
            (error condition))))))

(defmethod enable-raw-mode ((dev tty-device))
  (enable-raw-char-mode dev :vmin 1 :vtime 0 :canonical nil :echo nil :isig t))

(defmethod disable-raw-mode ((dev tty-device))
  (disable-raw-char-mode dev))

(defmethod device-capabilities ((dev tty-device))
  (let ((term (or (getenv "TERM") "unknown")))
    (list :truecolor t
      :mouse :sgr
      :paste t
      :focus t
      :winch t
      :term term)))

(defmethod device-set-modes ((dev tty-device) modes)
  (%ensure-open-device dev)
  (let ((mouse-mode (getf modes :mouse))
         (send (lambda (sequence) (%tty-write-string dev sequence))))
    (when mouse-mode
      (funcall send
        (cond
          ((eq mouse-mode :sgr)
            (format nil "~a[?1006h~a[?1003h" +esc+ +esc+))
          ((or (eq mouse-mode :off) (eq mouse-mode :disable))
            (format nil "~a[?1006l~a[?1003l" +esc+ +esc+))
          (t (format nil "~a[?9h" +esc+)))))
    (when (getf modes :paste)
      (funcall send (format nil "~a[?2004h" +esc+)))
    (when (getf modes :focus)
      (funcall send (format nil "~a[?1004h" +esc+)))
    (flush-output dev))
  t)

;; (defmethod device-read-bytes ((dev tty-device) buffer start end)
;;   (%ensure-open-device dev)
;;   (let ((n (read-sequence buffer (%tty-in dev) :start start :end end)))
;;     (if (= n start) 0 (- n start))))

;;; ---------------------------------------------------------------------------
;;; High-level terminal control

(defun %tty-write-string (dev string)
  (let ((bytes (string-to-utf-8-bytes string)))
    (device-write-bytes dev bytes 0 (length bytes))))

(defun %tty-fill-string (char width)
  (make-string width :initial-element char))

(defmethod clear-screen ((dev tty-device))
  (%emit-ansi dev "~a[2J~a[H" +esc+ +esc+)
  (setf (%tty-cursor-row dev) 0
    (%tty-cursor-col dev) 0)
  t)

(defmethod clear-area ((dev tty-device) row col height width &key style)
  (when (or (<= height 0) (<= width 0))
    (return-from clear-area nil))
  (let ((blank (%tty-fill-string #\Space width)))
    (dotimes (dy height)
      (set-cursor-position dev (+ row dy) col)
      (with-styled-output (dev style)
        (%tty-write-string dev blank))))
  t)

(defmethod draw-text-at ((dev tty-device) row col text &key style)
  (set-cursor-position dev row col)
  (with-styled-output (dev style)
    (%tty-write-string dev text))
  (setf (%tty-cursor-col dev) (+ col (length text)))
  t)

(defmethod draw-char-at ((dev tty-device) row col char &key style)
  (set-cursor-position dev row col)
  (with-styled-output (dev style)
    (%tty-write-string dev (string char)))
  (setf (%tty-cursor-col dev) col)
  t)

(defmethod fill-rectangle ((dev tty-device) row col height width &key (char #\Space) style)
  (when (or (<= height 0) (<= width 0))
    (return-from fill-rectangle nil))
  (let ((line (%tty-fill-string char width)))
    (dotimes (dy height)
      (set-cursor-position dev (+ row dy) col)
      (with-styled-output (dev style)
        (%tty-write-string dev line))))
  t)

(defmethod scroll-lines ((dev tty-device) count)
  (cond
    ((> count 0)
      (%emit-ansi dev "~a[~dS" +esc+ count))
    ((< count 0)
      (%emit-ansi dev "~a[~dT" +esc+ (- count))))
  t)

(defmethod set-cursor-position ((dev tty-device) row col)
  (%emit-ansi dev "~a[~d;~dH" +esc+ (1+ row) (1+ col))
  (setf (%tty-cursor-row dev) row
    (%tty-cursor-col dev) col)
  t)

(defmethod get-cursor-position ((dev tty-device))
  (values (%tty-cursor-row dev) (%tty-cursor-col dev)))

(defmethod hide-cursor ((dev tty-device))
  (%emit-ansi dev "~a[?25l" +esc+)
  (setf (%tty-cursor-visible? dev) nil)
  t)

(defmethod show-cursor ((dev tty-device))
  (%emit-ansi dev "~a[?25h" +esc+)
  (setf (%tty-cursor-visible? dev) t)
  t)

(defmethod flush-output ((dev tty-device))
  (when (%tty-out dev)
    (finish-output (%tty-out dev)))
  t)

(defmethod apply-style ((dev tty-device) style)
  (let ((sgr (%style->sgr-string style)))
    (when sgr
      (%emit-ansi dev "~a[~am" +esc+ sgr)
      (setf (%tty-current-style dev) style)))
  t)

(defmethod reset-style ((dev tty-device))
  (%emit-ansi dev "~a[0m" +esc+)
  (setf (%tty-current-style dev) nil)
  t)


;;;---------------------------------------------------------------
;;; Display & Screen Management (existing methods)
;;;---------------------------------------------------------------
(defmethod send-sequence ((instance tty-device) seq-id &rest args)
  (let ((seq-obj (cl-inputs.terminal.ansii:get-sequence seq-id)))
    (when seq-obj
      (let ((rendered (apply #'cl-inputs.terminal.ansii:render-seq seq-obj args)))
        (write-output rendered (%tty-out instance))))))

(defmethod get-cursor-position ((instance tty-device))
  "Return the cursor position tracked by writes through this device.

TTY device methods never read protocol replies directly: doing so would race the
input source and could steal user input. Call CL-INPUTS.LOOP:SEND-TERMINAL-QUERY
with :CURSOR-POSITION when an authoritative terminal CPR is required."
  (values (%tty-cursor-row instance) (%tty-cursor-col instance)))

(defmethod get-terminal-size ((instance tty-device))
  "Return the device's cached width and height without consuming input bytes.

Live terminal negotiation belongs to the input-source response router. This
method deliberately avoids cursor-report tricks that compete with the source."
  (values (%tty-width instance) (%tty-height instance)))


