(in-package :cl-inputs.device)


(defstruct (tty-device (:constructor %make-tty-device))
  path
  in
  out
  (raw-enabled? nil)
  original-termios)

(defun %open-stream (path direction)
  (open path
        :direction direction
        :element-type '(unsigned-byte 8)
        :if-does-not-exist :error))

(defun %termios-raw-mode (fd enable-p &optional original-termios)
  (if enable-p
      (let ((orig (the sb-posix:termios (sb-posix:tcgetattr fd))))
        (let ((new (the sb-posix:termios (sb-int:sys-copy-struct orig))))
          (setf (sb-posix:termios-lflag new)
                (logand (sb-posix:termios-lflag new)
                        (lognot sb-posix:icanon)
                        (lognot sb-posix:echo)))
          (setf (aref (sb-posix:termios-cc new) sb-posix:vmin) 0
                (aref (sb-posix:termios-cc new) sb-posix:vtime) 1)
          (sb-posix:tcsetattr fd sb-posix:tcsanow new)
          orig))
      (when original-termios
        (sb-posix:tcsetattr fd sb-posix:tcsanow original-termios))))

(defun %tty-capabilities ()
  (list :truecolor t :mouse :sgr :paste t :focus t :winch t :term (uiop:getenv "TERM")))

(register-backend :tty
                  (lambda (&key (path "/dev/tty"))
                    (make-tty-device :path path)))

(defmethod device-kind ((dev tty-device)) :tty)

(defmethod open-device ((dev tty-device))
  (let ((in (%open-stream (tty-device-path dev) :input))
        (out (%open-stream (tty-device-path dev) :output)))
    (setf (tty-device-in dev) in
          (tty-device-out dev) out)
    dev))

(defmethod close-device ((dev tty-device))
  (when (tty-device-in dev)
    (ignore-errors (close (tty-device-in dev))))
  (when (tty-device-out dev)
    (ignore-errors (close (tty-device-out dev))))
  t)

(define-condition termios-raw-mode-error (error)
  ((device :initarg :device :reader tty-device-error-device)
   (message :initarg :message :reader tty-device-error-message)))

(defmethod enable-raw-mode ((dev tty-device))
  (let* ((fd (sb-sys:fd-stream-fd (tty-device-in dev)))
         (tos (%termios-raw-mode fd t)))
    (unless tos
      (error 'termios-raw-mode-error
             :device dev
             :message "Failed to set raw mode on TTY device."))
    (when tos (setf (tty-device-original-termios dev) tos)
          (setf (tty-device-raw-enabled? dev) t))))

(defmethod disable-raw-mode ((dev tty-device))
  (when (tty-device-raw-enabled? dev)
    (let ((fd (sb-sys:fd-stream-fd (tty-device-in dev))))
      (%termios-raw-mode fd nil (tty-device-original-termios dev))
      (setf (tty-device-raw-enabled? dev) nil))))

(defmethod device-read-bytes ((dev tty-device) buffer start end)
  (read-sequence buffer (tty-device-in dev) :start start :end end))

(defmethod device-write-bytes ((dev tty-device) buffer start end)
  (write-sequence buffer (tty-device-out dev) :start start :end end)
  (finish-output (tty-device-out dev))
  (- end start))

(defmethod device-capabilities ((dev tty-device))
  (%tty-capabilities))

(defmethod device-set-modes ((dev tty-device) modes)
  (let ((stream (tty-device-out dev)))
    (when (getf modes :mouse)
      (write-sequence (string-to-utf-8-bytes
                       (if (eq (getf modes :mouse) :sgr)
                           "[?1006h[?1003h" ; SGR + any
                           "[?9h")) ; X10
                      stream))
    (when (getf modes :paste)
      (write-sequence (string-to-utf-8-bytes "[?2004h") stream))
    (when (getf modes :focus)
      (write-sequence (string-to-utf-8-bytes "[?1004h") stream))
    (finish-output stream)))
