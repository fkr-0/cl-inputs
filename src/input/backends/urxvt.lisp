(in-package :cl-inputs.device)

;; (defstruct urxvt-device proc master-fd caps)
;;;---------------------------------------------------------------
;;; PTY Management Utilities (adapted from lowterm/urxvt.lisp)
;;;---------------------------------------------------------------
(sb-alien:define-alien-routine "ptsname" sb-alien:c-string (fd sb-alien:int))
(sb-alien:define-alien-routine "grantpt" sb-alien:int (fd sb-alien:int))
(sb-alien:define-alien-routine "unlockpt" sb-alien:int (fd sb-alien:int))

(defun find-pty ()
  "Attempts to open a new pseudo-terminal master and returns (VALUES MASTER-FD SLAVE-FD SLAVE-NAME)."
  (let ((master-fd (unix-open "/dev/ptmx" (logior o_rdwr o_noctty) 0)))
    (when (and master-fd (>= master-fd 0))
      (when (zerop (grantpt master-fd))
        (when (zerop (unlockpt master-fd))
          (let* ((slave-name (ptsname master-fd))
                 (slave-fd (unix-open slave-name (logior o_rdwr o_noctty) 0)))
            (if (and slave-fd (>= slave-fd 0))
                (return-from find-pty (values master-fd slave-fd slave-name))
                (progn (unix-close master-fd)
                       (error "Could not open PTY slave: ~A" slave-name))))))
      (when (and master-fd (>= master-fd 0)) (unix-close master-fd))
      (error "Could not grantpt/unlockpt on PTY master.")))
  (error "Could not open /dev/ptmx."))

(defstruct urxvt-device
  (master-fd -1 :type integer)
  (slave-fd -1 :type integer)
  (pty-name nil :type (or null string))
  (proc nil :type (or null t))
  (caps '(:truecolor t :mouse t :paste t :focus t :winch t :urxvt t))
  (stream nil :type (or null stream))
  (original-termios nil :type (or null termios))
  (width 80 :type integer)
  (height 24 :type integer)
  (cursor-visible-p t :type boolean)
  (cursor-row 0 :type integer)
  (cursor-col 0 :type integer)
  (current-style '(:fg :white :bg :black :attrs nil))
  (input-buffer (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
  (lock (bt:make-recursive-lock "urxvt-io-lock")))

(defmacro with-urxvt-lock ((instance) &body body)
  `(bt:with-recursive-lock-held ((urxvt-device-lock ,instance))
     ,@body))


;; (defun find-pty ()
;;   "Attempts to open a new pseudo-terminal master and returns (VALUES MASTER-FD SLAVE-FD SLAVE-NAME)."
;;   (let ((master-fd (unix-open "/dev/ptmx" (logior o_rdwr o_noctty) 0)))
;;     (when (and master-fd (>= master-fd 0))
;;       (when (zerop (grantpt master-fd))
;;         (when (zerop (unlockpt master-fd))
;;           (let* ((slave-name (ptsname master-fd))
;;                  (slave-fd (unix-open slave-name (logior o_rdwr o_noctty) 0)))
;;             (if (and slave-fd (>= slave-fd 0))
;;                 (return-from find-pty (values master-fd slave-fd slave-name))
;;                 (progn (unix-close master-fd)
;;                        (error "Could not open PTY slave: ~A" slave-name))))))
;;       (when (and master-fd (>= master-fd 0)) (unix-close master-fd))
;;       (error "Could not grantpt/unlockpt on PTY master.")))
;;   (error "Could not open /dev/ptmx."))

(defun spawn-urxvt (&key (urxvt-program "/usr/bin/urxvt")
                      (name "cl-inputs-urxvt")
                      (urxvt-args '("-fn" "xft:monospace:size=12")))
  (multiple-value-bind (master-fd slave-fd pty-name) (find-pty)
    (handler-case
        (let* (
               (process (run-program urxvt-program
                                     (append urxvt-args (list
                                                         "-name" name
                                                         "-pty-fd"
                                                         (format nil "~A" slave-fd)))
                                     :search t :wait nil :input nil :output nil :error :output
                                     ;; :preserve-fds (list slave-fd) ; SBCL specific, might not be needed if urxvt handles -pty-fd correctly
                                     ))
               (stream (make-fd-stream master-fd :input t :output t :element-type 'character :buffering :none))
               (original-termios (enable-raw-mode master-fd)) ; Set raw mode on our end of PTY
               (instance (make-urxvt-device :master-fd master-fd
                                            :slave-fd slave-fd ; Keep for potential cleanup
                                            :pty-name pty-name
                                            :proc process
                                            :stream stream
                                            :original-termios original-termios)))
          ;; Set non-blocking on master PTY for reads
          (fcntl master-fd sb-posix::f-setfd (fcntl master-fd sb-posix::f-getfd 0)) ; Clear O_NONBLOCK if set by run-program
          (fcntl master-fd sb-posix::f-setfd (logior
                                              (fcntl master-fd sb-posix::f-getfd 0)
                                              sb-posix::o-nonblock))
          (sleep 0.5) ; Give URxvt a moment to start up

          ;; (multiple-value-bind (w h) (get-screen-dimensions instance)
          ;;   (setf (urxvt-device-width instance) w
          ;;         (urxvt-device-height instance) h))
          ;; (elmtui.backend.common.utils:render-seq (get-sequence :cursor-hide))
          ;; (elmtui.backend.common.utils:render-seq (get-sequence :alt-screen-buffer))
          ;; (clear-screen instance)
          ;; (flush-output instance)
          instance)
      (error (c)
        (when (and master-fd (>= master-fd 0)) (unix-close master-fd))
        (when (and slave-fd (>= slave-fd 0)) (unix-close slave-fd))
        (error "Failed to initialize URxvt backend: ~A" c)))))

(register-backend :urxvt
                  #'spawn-urxvt
                  ;; (lambda (&key (cmd "urxvt") (args '()))
                  ;;   (multiple-value-bind (master-fd slave-path)
                  ;;       (allocate-pty)
                  ;;     (let* ((proc (uiop:launch-program
                  ;;                   (append (list cmd) args)
                  ;;                   :input  slave-path
                  ;;                   :output slave-path
                  ;;                   :error-output slave-path
                  ;;                   :detached t)))

                  ;;       ;; (make-urxvt-device :proc proc
                  ;;       ;;                    :master-fd master-fd
                  ;;       ;;                    :caps '(:truecolor t :mouse :urxvt :paste t :focus t :winch t))
                  ;;       )))
                  )

(defmethod device-kind ((dev urxvt-device)) :urxvt)

(defmethod open-device ((dev urxvt-device)) dev)
(defmethod close-device ((instance urxvt-device))
  (with-urxvt-lock (instance)
    (handler-case
        (progn
          (when (urxvt-device-stream instance)
            ;; (elmtui.backend.common.utils:render-seq (get-sequence :normal-screen-buffer))
            ;; (elmtui.backend.common.utils:render-seq (get-sequence :cursor-show))
            ;; (elmtui.backend.common.utils:render-seq (get-sequence :reset))
            (finish-output (urxvt-device-stream instance)))

          (when (and (urxvt-device-master-fd instance) (>= (urxvt-device-master-fd instance) 0))
            (disable-raw-mode instance))

          (when (urxvt-device-stream instance)
            (close (urxvt-device-stream instance))
            (setf (urxvt-device-stream instance) nil))

          (when (and (urxvt-device-master-fd instance) (>= (urxvt-device-master-fd instance) 0))
            (unix-close (urxvt-device-master-fd instance))
            (setf (urxvt-device-master-fd instance) -1))

          (when (and (urxvt-device-slave-fd instance) (>= (urxvt-device-slave-fd instance) 0))
            ;; Slave FD is typically managed by the PTY system and URxvt,
            ;; closing master should be enough. Explicit close might error if URxvt already closed it.
            ;; (unix-close (urxvt-device-slave-fd instance))
            (setf (urxvt-device-slave-fd instance) -1))

          (when (urxvt-device-proc instance)
            (ignore-errors (process-kill (urxvt-device-proc instance) 15)) ; SIGTERM
            (sleep 0.1)
            (ignore-errors (process-kill (urxvt-device-proc instance) 9))  ; SIGKILL
            (setf (urxvt-device-proc instance) nil)))
      (error (c)
        (warn "Error during URxvt backend shutdown: ~A" c))))
  t)
;; (defmethod close-device ((dev urxvt-device))
;;   (ignore-errors (uiop:terminate-process (urxvt-device-proc dev)))
;;   (ignore-errors (trivial-ptys:close-pty (urxvt-device-master-fd dev)))
;;   t)

(defmethod enable-raw-mode ((dev urxvt-device)) t)
(defmethod disable-raw-mode ((dev urxvt-device)) t)

(defmethod device-read-bytes ((dev urxvt-device) buffer start end)
  (let ((fd (urxvt-device-master-fd dev)))
    (if (and fd (>= fd 0))
        (with-urxvt-lock (dev)
          (let ((bytes-read (read-sequence buffer (urxvt-device-stream dev)
                                           :start start :end end)))
            (if (= bytes-read 0)
                :eof
                bytes-read)))
        (error "URxvt device is not open or master FD is invalid."))))

(defun read-into-buffer (dev buffer start end &optional (timeout nil))
  "Reads bytes from the stream into BUFFER from START to END."
  (declare (ignore timeout))
  (let ((stream (urxvt-device-stream dev)))
    (with-urxvt-lock (dev)
      (let ((bytes-read (read-sequence buffer stream :start start :end end )))
        (if (= bytes-read 0)
            :eof
            bytes-read)))))



(defun read-char-nonblock (stream) (read-byte stream nil nil))


(defun write-output (output stream )
  "Write output to the terminal
This method should be implemented by subclasses of low-level-terminal."
  ;; (declare (ignore style))
  ;; ;; (with-lock (term)
  ;; (exec-sequence term :cursor-set-position y x)
  (dotimes (i (length output))
    (as-utf-8-bytes (char output i) (lambda (x) (write-byte x stream)))))

(defmethod device-write-bytes ((dev urxvt-device) buffer start end)
  (with-urxvt-lock (dev)
    (let ((stream (urxvt-device-stream dev)))
      (if (and stream (sb-sys:fd-stream-p stream))
          (let ((bytes-written (write-sequence buffer stream :start start :end end)))
            (finish-output stream)
            bytes-written)
          (error "URxvt device stream is not valid.")))))
;;   (let ((fd (urxvt-device-master-fd dev)))
;;     (sb-sys:fd-write fd buffer start end)))

(defmethod device-capabilities ((dev urxvt-device))
  (copy-list (urxvt-device-caps dev)))

(defmethod device-set-modes ((dev urxvt-device) modes)
  (declare (ignore modes))
  t)
