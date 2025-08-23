(in-package :cl-inputs.device)

(defvar *backend-registry* (make-hash-table :test 'equal))

(defun register-backend (key ctor)
  "CTOR is a function (&rest initargs) -> DEV."
  (setf (gethash key *backend-registry*) ctor) key)

(defun make-device* (key &rest initargs)
  (let ((ctor (gethash key *backend-registry*)))
    (unless ctor (error "No backend registered for ~S" key))
    (apply ctor initargs)))

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
(defmethod open-device ((dev t)) dev)
(defmethod close-device ((dev t)) (declare (ignore dev)) t)
(defmethod enable-raw-mode ((dev t)) (declare (ignore dev)) t)
(defmethod disable-raw-mode ((dev t)) (declare (ignore dev)) t)
(defmethod device-read-bytes ((dev t) buffer start end)
  (declare (ignore dev buffer start end))
  :eof)
(defmethod device-write-bytes ((dev t) buffer start end)
  (declare (ignore dev buffer start end)) 0)
(defmethod device-capabilities ((dev t)) (declare (ignore dev)) nil)
(defmethod device-set-modes ((dev t) modes) (declare (ignore dev modes)) t)


;;; Optional constructor for your real termios impl
(defun make-tty-device (&key (path "/dev/tty"))
  (declare (ignore path))
  (make-device* :tty))