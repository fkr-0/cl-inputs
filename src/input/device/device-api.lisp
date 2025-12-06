;;;; cl-inputs.device.api.lisp
;;;
;;; Device API protocol for cl-inputs.
;;; Defines generic interfaces for device operations (open, close, raw char mode, I/O, etc).
;;; Backends should implement these generics for their device types.

(uiop:define-package :cl-inputs.device.api
  (:use :cl :alexandria )
  (:import-from
    #:cl-inputs.util #:as-utf-8-bytes #:string-to-utf-8-bytes)
  (:import-from #:sb-ext #:run-program  #:process-pid #:process-pty #:process-kill)
  (:import-from #:sb-sys #:make-fd-stream #:fd-stream-fd)
  (:use #:sb-unix)

  (:export
    ;; Device port (generics; default stub prints warnings)
    #:device-wait-readable
    #:device-enable-raw-char-mode
    #:with-raw-char-mode
    #:enable-raw-char-mode
    #:disable-raw-char-mode
    #:device-set-nonblocking
    #:device-error
    #:raw-mode-error
    #:make-device
    #:device-kind
    #:open-device #:close-device
    #:enable-raw-mode #:disable-raw-mode
    #:device-read-bytes #:device-write-bytes
    #:device-input-stream #:device-output-stream #:device-fd
    #:device-capabilities
    #:device-wait-readable
    #:device-set-modes
    ;; Locking
    #:lockable
    #:lock-of
    #:with-lock
    #:with-terminal-lock
    #:acquire-lock
    #:release-lock))


(in-package :cl-inputs.device.api)
(defgeneric disable-raw-char-mode (dev))
;; (defgeneric get-terminal-size (dev)
;;   (:documentation "Return (values rows cols) for DEV."))
;; (defvar *backend-registry* (make-hash-table :test 'equal))

;; (defun register-backend (key ctor)
;;   "CTOR is a function (&rest initargs) -> DEV."
;;   (setf (gethash key *backend-registry*) ctor) key)

;; (defun make-device* (key &rest initargs)
;;   (let ((ctor (gethash key *backend-registry*)))
;;     (unless ctor (error "No backend registered for ~S" key))
;;     (apply ctor initargs)))

;; (defgeneric make-device-kind (backend &key &allow-other-keys)
;;   (:documentation
;;     "Return a keyword identifying the device kind for BACKEND (a keyword or descriptor).
;;     E.g. :tty, :faketerm, :urxvt."))
;; (defmethod make-device-kind ((backend (eql :tty)) &key &allow-other-keys)
;;   (cl-inputs.device.tty:make-tty-device )

;;   (defmethod make-device-kind ((backend (eql :faketerm)) &key &allow-other-keys))
;;   (make-instance 'cl-inputs.device.faketerm:faketerm-device))

;; (defmethod make-device-kind ((backend (eql :urxvt)) &key &allow-other-keys)
;;   (cl-inputs.device.urxvt:make-urxvt-device ))

;; (defgeneric get-cursor-position (dev)
;;   (:documentation "Return (values row col) for DEV."))


(defgeneric make-device (backend &key &allow-other-keys)
  (:documentation
    "Construct a device instance for BACKEND (a keyword or descriptor).
    No global singletons; return a self-contained handle."))



(defgeneric device-kind (dev) (:documentation "Return a keyword like :tty, :faketerm, :urxvt."))

(defgeneric open-device (dev)
  (:documentation "Return a device handle (whatever your impl wants)."))

(defgeneric close-device (dev))
(defgeneric enable-raw-mode (dev))
(defgeneric disable-raw-mode (dev))

(defgeneric device-read-bytes (dev buffer start end)
  (:documentation "Fill BUFFER[start..end). Return number of bytes or :eof."))

(defgeneric device-write-bytes (dev buffer start end)
  (:documentation "Optional; return bytes written."))

(defgeneric device-input-stream (dev)
  (:documentation "Return the underlying binary input stream for DEV, or NIL if not available."))

(defgeneric device-output-stream (dev)
  (:documentation "Return the underlying binary output stream for DEV, or NIL if not available."))

(defgeneric device-fd (dev)
  (:documentation "Return the underlying file descriptor for DEV, or NIL if not supported."))

(defgeneric device-capabilities (dev)
  (:documentation
    "Return a plist describing negotiated/known features, e.g.:
    (:truecolor t
     :mouse :sgr             ; :x10 | :urxvt | :sgr
     :focus-events t
     :bracketed-paste t
     :winch t                ; supports reporting resize
     :term (\"xterm-256color\"))"))

(defgeneric device-set-modes (dev modes)
  (:documentation
    "Enable terminal modes (mouse tracking, bracketed paste, focus in/out).
    MODES is a plist, e.g. (:mouse :sgr :paste t :focus t)."))


;;; Default fallbacks (do nothing) so the protocol is optional to implement
(defmethod open-device ((dev t))
  "Default fallback for OPEN-DEVICE. Returns DEV unchanged.

Extension Point:
  Override in device backends to implement device opening logic.
  Required for concrete device types.

Side Effects:
  None by default."
  dev)

(defmethod close-device ((dev t))
  "Default fallback for CLOSE-DEVICE. Returns T.

Extension Point:
  Override in device backends to implement device closing logic.
  Required for concrete device types.

Side Effects:
  None by default."
  (declare (ignore dev)) t)

(defmethod enable-raw-mode ((dev t))
  "Default fallback for ENABLE-RAW-MODE. Returns T.

Extension Point:
  Override in device backends to enable raw char mode on the device.
  Required for concrete device types.

Side Effects:
  None by default."
  (declare (ignore dev)) t)

(defmethod disable-raw-mode ((dev t))
  "Default fallback for DISABLE-RAW-MODE. Returns T.

Extension Point:
  Override in device backends to disable raw char mode on the device.
  Required for concrete device types.

Side Effects:
  None by default."
  (declare (ignore dev)) t)

(defmethod device-read-bytes ((dev t) buffer start end)
  "Default fallback for DEVICE-READ-BYTES. Returns :EOF.

Extension Point:
  Override in device backends to implement byte reading from the device.
  Required for concrete device types.

Arguments:
  DEV    -- device object
  BUFFER -- array to fill (unsigned-byte 8)
  START  -- start index (integer)
  END    -- end index (integer, exclusive)

Return Value:
  Number of bytes read (non-negative integer), :EOF on end-of-file.

Side Effects:
  None by default."
  (declare (ignore dev buffer start end))
  :eof)

(defmethod device-write-bytes ((dev t) buffer start end)
  "Default fallback for DEVICE-WRITE-BYTES. Returns 0.

Extension Point:
  Override in device backends to implement byte writing to the device.
  Optional; not all devices need to support output.

Arguments:
  DEV    -- device object
  BUFFER -- array to write (unsigned-byte 8)
  START  -- start index (integer)
  END    -- end index (integer, exclusive)

Return Value:
  Number of bytes written (integer).

Side Effects:
  None by default."
  (declare (ignore dev buffer start end)) 0)

(defmethod device-input-stream ((dev t))
  "Default fallback for DEVICE-INPUT-STREAM. Returns NIL."
  (declare (ignore dev)) nil)

(defmethod device-output-stream ((dev t))
  "Default fallback for DEVICE-OUTPUT-STREAM. Returns NIL."
  (declare (ignore dev)) nil)

(defmethod device-fd ((dev t))
  "Default fallback for DEVICE-FD. Returns NIL."
  (declare (ignore dev)) nil)

(defmethod device-capabilities ((dev t))
  "Default fallback for DEVICE-CAPABILITIES. Returns NIL.

Extension Point:
  Override in device backends to report device capabilities.
  Optional.

Arguments:
  DEV -- device object

Return Value:
  Plist of capabilities, or NIL.

Side Effects:
  None by default."
  (declare (ignore dev)) nil)

(defmethod device-set-modes ((dev t) modes)
  "Default fallback for DEVICE-SET-MODES. Returns T.

Extension Point:
  Override in device backends to set terminal modes (mouse, paste, etc).
  Optional.

Arguments:
  DEV   -- device object
  MODES -- plist of mode settings

Return Value:
  T if successful.

Side Effects:
  None by default."
  (declare (ignore dev modes)) t)
;; ;; == cl-inputs/src/device/protocol.lisp ==
;; (uiop:define-package :cl-inputs.device.protocol
;;   (:use :cl :alexandria)
;;   (:export
;;     ;; protocol
;;     #:device-kind
;;     #:initialized-p
;;     #:open-device
;;     #:close-device
;;     #:device-input-stream
;;     #:device-output-stream
;;     #:enable-raw-char-mode
;;     #:disable-raw-char-mode
;;     #:device-read-bytes
;;     ;; macros
;;     #:with-raw-char-mode
;;     ;; conditions
;;     #:device-error
;;     #:raw-mode-error))
;; (in-package :cl-inputs.device.protocol)

;; ;;; Conditions

(define-condition device-error (error)
  ((device  :initarg :device  :reader device-error/device)
    (message :initarg :message :reader device-error/message))
  (:report (lambda (c s)
             (format s "~a (device=~s)" (device-error/message c) (device-error/device c))))
  (:documentation "Generic device error condition for device API failures."))

(define-condition raw-mode-error (device-error) ()
  (:documentation "Condition signaled when raw mode operations fail."))

;;; Protocol (defgenerics)

;; (defgeneric device-kind (dev))
;; (defgeneric initialized-p (dev))
;; (defgeneric open-device (dev))
;; (defgeneric close-device (dev))

;; (defgeneric device-input-stream (dev))
;; (defgeneric device-output-stream (dev))

;; (defgeneric enable-raw-char-mode (dev &key vmin vtime canonical echo isig)
;;   (:documentation "Enter raw character mode; SHOULD be idempotent and nestable."))
;; (defgeneric disable-raw-char-mode (dev)
;;   (:documentation "Leave raw character mode; SHOULD be idempotent and nestable."))

;; (defgeneric device-set-nonblocking (dev flag)
;;   (:documentation "Enable/disable O_NONBLOCK; return FLAG actually set."))

;; (defgeneric device-wait-readable (dev timeout-ms)
;;   (:documentation "Block up to TIMEOUT-MS for input readiness. Return T if readable, NIL on timeout."))

;; (defgeneric device-read-bytes (dev buffer start end)
;;   (:documentation
;;    "Read up to END-START octets into BUFFER. Return:
;;     - non-negative integer N bytes read,
;;     - 0 for EAGAIN (nonblocking and no data),
;;     - :EOF on end-of-file / hangup."))

;; (defgeneric device-open-fd-stream (fd &key direction)
;;   (:documentation "Create a binary (unsigned-byte 8) stream for FD; DIRECTION is :input or :output."))

;; (defgeneric device-capabilities (dev)
;;   (:documentation "Return plist of capabilities, e.g. (:truecolor T :mouse :sgr :paste T :focus T :term \"xterm-256color\")."))

;;; Macro façade

(defmacro with-raw-char-mode ((dev &key (vmin 1) (vtime 0) (canonical nil) (echo nil) (isig t))
                               &body body)
  "Portable wrapper that enables raw char mode before BODY and restores it after,
   relying on device methods. Idempotent and safe to nest."
  (alexandria:with-gensyms (gdev)
    `(let ((,gdev ,dev))
       (unwind-protect
         (progn
           (enable-raw-char-mode ,gdev :vmin ,vmin :vtime ,vtime
             :canonical ,canonical :echo ,echo :isig ,isig)
           ,@body)
         (ignore-errors (disable-raw-char-mode ,gdev))))))
;; == end/protocol.lisp ==


;;; Optional constructor for your real termios impl
;; (defun make-tty-device (&key (path "/dev/tty"))
;;   (declare (ignore path))
;;   (make-device :tty :path path))
;; == cl-inputs/src/device/protocol.lisp ==
;; unchanged API, but leave the docstring hint that the tty impl uses WAIT-UNTIL-FD-USABLE

(defgeneric device-wait-readable (dev timeout-ms)
  (:documentation
    "Block up to TIMEOUT-MS for readability; T if readable, NIL on timeout.
On SBCL TTY the impl uses SB-SYS:WAIT-UNTIL-FD-USABLE (seconds)."))
;; == end/protocol.lisp ==

(defgeneric device-set-nonblocking (dev flag)
  (:documentation
    "Enable/disable O_NONBLOCK; return FLAG actually set."))

(defgeneric enable-raw-char-mode (dev &key vmin vtime canonical echo isig &allow-other-keys)
  (:documentation "Enter raw character mode; SHOULD be idempotent and nestable."))

(defclass lockable ()
  ((lock :initarg :lock
     :initform (bt:make-recursive-lock)
     :accessor lock-of ; Changed from accessor to reader to prevent direct (setf lock-of)
     :type bt:recursive-lock)
    (lock-owner :initarg :lock-owner
      :initform nil
      :accessor lock-owner
      :type t) ; Can be any thread object or T for generic owner
    (lock-owner-count :initarg :lock-owner-count
      :initform 0
      :accessor lock-owner-count
      :type unsigned-byte)))

;;; ===================================================================
;;; IMPLEMENTATION SECTION
;;; ===================================================================
(defmethod initialize-instance :after ((l lockable) &key)
  (check-type (lock-of l) bt:recursive-lock)
  (check-type (lock-owner-count l) unsigned-byte))

(defmethod acquire-lock ((l lockable))
  "Acquire the terminal lock. If the lock is already held by the current thread,
increment the lock count. Otherwise, acquire the lock and set the lock owner to
the current thread."
  (declare (optimize (speed 3) (safety 0) (debug 0)))
  (let ((current-thread (bt:current-thread)))
    (with-slots (lock lock-owner lock-owner-count)
      l
      (bt:acquire-lock lock t) ; Ensure the lock is acquired before checking owner
      (if (eq lock-owner current-thread)
        (incf (the fixnum lock-owner-count))
        (progn
          (setf lock-owner current-thread)
          (setf lock-owner-count 1)))))
  l) ; Return the lockable object

(defmethod release-lock ((l lockable))
  "Release the terminal lock. If the lock count is greater than 1, decrement the
lock count. Otherwise, release the lock and set the lock owner to nil."
  (declare (optimize (speed 3) (safety 0) (debug 0)))
  (let ((current-thread (bt:current-thread)))
    (with-slots (lock lock-owner lock-owner-count)
      l
      (when (eq lock-owner current-thread)
        (if (> (the fixnum lock-owner-count) 1)
          (decf (the fixnum lock-owner-count))
          (progn
            (setf lock-owner nil)
            (setf lock-owner-count 0)
            (bt:release-lock lock)))))))

(defmacro with-lock ((l) &body body)
  "Execute BODY with the lock of LOCKABLE L acquired.
This macro ensures that the lock is acquired before executing BODY,
and released afterwards, even if an error occurs during execution.
It uses `acquire-lock` and `release-lock` methods to manage the lock.
This is useful for ensuring thread safety when accessing shared resources."
  `(progn
     (acquire-lock ,l)
     (unwind-protect
       (progn ,@body)
       (release-lock ,l))))
;; TODO compare
(defmacro with-terminal-lock ((instance) &body body)
  `(bt:with-recursive-lock-held ((lock-of ,instance))
     ,@body))
