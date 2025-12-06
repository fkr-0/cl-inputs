;;;; cl-inputs.device.urxvt.lisp
;;;
;;; URxvt terminal backend for cl-inputs.
;;; Provides device API implementation for urxvt-compatible terminals using PTYs.

(uiop:define-package :cl-inputs.device.urxvt
  (:use :cl :alexandria )

  (:import-from :sb-posix
    #:tcgetattr #:tcsetattr #:tcsanow
    #:termios #:termios-iflag #:termios-oflag #:termios-cflag #:termios-lflag #:termios-cc
    ;; input flags
    #:ignbrk #:brkint #:icrnl #:inlcr #:istrip #:ixon #:ixoff #:parmrk)
  (:import-from
    #:cl-inputs.util #:as-utf-8-bytes #:string-to-utf-8-bytes)
  (:import-from #:sb-ext #:run-program  #:process-pid #:process-pty #:process-kill)
  (:import-from #:sb-sys #:make-fd-stream #:fd-stream-fd #:wait-until-fd-usable)
  (:import-from #:sb-alien #:define-alien-routine #:c-string #:boolean #:int
    #:alien-sap #:make-alien-string)
  (:import-from #:bordeaux-threads
    #:make-recursive-lock #:with-recursive-lock-held)
  (:use #:sb-unix)

  ;; #:sb-posix #:termios #:tcgetattr #:tcsetattr
  ;;             #:tcsanow #:icanon #:echo #:vmin #:vtime
  (:import-from :cl-inputs.device.api
    #:enable-raw-char-mode
    ;; Device port (generics; default stub prints warnings)
    #:make-device
    #:device-kind #:device-input-stream #:device-output-stream #:device-fd
    #:device-set-nonblocking
    #:open-device #:close-device
    #:enable-raw-mode #:disable-raw-mode
    #:device-read-bytes #:device-write-bytes
    #:device-capabilities
    #:device-set-modes)
  (:import-from :cl-inputs.terminal.api
    #:clear-screen #:clear-area #:draw-text-at #:draw-char-at #:fill-rectangle
    #:scroll-lines #:set-cursor-position #:get-cursor-position #:hide-cursor #:show-cursor
    #:flush-output #:apply-style #:reset-style #:with-styled-output #:%emit-ansi
    #:%style->sgr-string #:+esc+))
;; Optional default TTY impl constructor:
(defvar master-fd nil)
(defvar slave-fd nil)
(defvar slave-name nil)

;; Define PTY handling functions
(in-package :cl-user)
(progn
  (define-alien-routine ptsname c-string (fd int)) ;; char *ptsname(int fd);

  (define-alien-routine grantpt boolean (fd int)) ;; int grantpt(int fd);
  (define-alien-routine unlockpt boolean (fd int)) ;; int unlockpt(int fd);

  (defun find-a-pty ()
    ;; First try to use the Unix98 pty api.
    (let ((master-fd (sb-unix:unix-open "/dev/ptmx"
                       (logior sb-unix:o_rdwr
                         sb-unix:o_noctty)
                       #o666)))
      (when master-fd
        (cl-user::grantpt master-fd)
        (cl-user::unlockpt master-fd)
        (let* ((slave-name (cl-user::ptsname master-fd))
                (slave-fd (sb-unix:unix-open slave-name
                            (logior sb-unix:o_rdwr
                              sb-unix:o_noctty)
                            #o666)))
          (when slave-fd
            (return-from find-a-pty
              (values master-fd
                slave-fd
                slave-name)))
          (sb-unix:unix-close master-fd))
        (error "could not find a pty")))
    ;; No dice, try using the old-school method.
    (dolist (char '(#\p #\q))
      (dotimes (digit 16)
        (let* ((master-name (with-output-to-string (str nil :element-type 'base-char)
                              (format str "/dev/pty~C~X" char digit)))
                (master-fd (sb-unix:unix-open master-name
                             (logior sb-unix:o_rdwr
                               sb-unix:o_noctty)
                             #o666)))
          (when master-fd
            (let* ((slave-name (with-output-to-string (str nil :element-type 'base-char)
                                 (format str "/dev/tty~C~X" char digit)))
                    (slave-fd (sb-unix:unix-open slave-name
                                (logior sb-unix:o_rdwr
                                  sb-unix:o_noctty)
                                #o666)))
              (when slave-fd
                (return-from find-a-pty
                  (values master-fd
                    slave-fd
                    slave-name)))
              (sb-unix:unix-close master-fd))))))
    (error "could not find a pty")))

(defun open-urxvt-with-pty (slave-fd)
  (sb-ext:run-program "/usr/bin/urxvt"
    (list "-pty-fd" (format nil "~A" slave-fd) "-name" "fzf_menu")
    :pty nil
    :preserve-fds (list slave-fd)
    :input nil
    :search t
    :output nil
    :wait nil))
(defun spawn-urxvt-with-pty ()
  (multiple-value-bind (mm ss nn) (cl-user::find-a-pty)
    (setf master-fd mm slave-fd ss slave-name nn)
    ;; Ensure slave FD is not closed-on-exec so urxvt can inherit it
    (sb-posix:fcntl slave-fd sb-posix:f-setfd 0)
    (let ((proc (open-urxvt-with-pty slave-fd)))
      ;; Parent only needs the master side; close the slave here
      (sb-unix:unix-close slave-fd)
      (format t "PTY opened: ~A ~A ~A~%" master-fd slave-fd slave-name)
      (values master-fd slave-fd slave-name proc)))

  )  ;; Corrected function call
;; immediately close the master fd


(in-package :cl-inputs.device.urxvt)
(defun term-in-fd (term)
  (let ((fd (device-fd term)))
    (unless (and fd (>= fd 0))
      (error "URxvt device FD invalid: ~A" fd))
    fd))
(defun read-single-key (term)
  (let ((buf (make-array 1 :element-type '(unsigned-byte 8))))
    (let ((len (sb-unix:unix-read (term-in-fd term) (sb-sys:vector-sap buf) 1)))
      (if (= len 1)
        (code-char (aref buf 0))
        nil))))

(defun read-term-byte (fd)
  (let ((buf (make-array 1 :element-type '(unsigned-byte 8))))
    (let ((len (sb-unix:unix-read fd (sb-sys:vector-sap buf) 1)))
      (if (= len 1)
        (aref buf 0)
        nil))))
(defun read-escape-sequence-bytes-term (fd b)
  (log:info "Reading escape sequence bytes: ~a" b)
  (let ((bytes (list b (read-term-byte fd))))
    (log:info "Reading escape sequence bytes: ~a ~a" bytes
      (mapcar #'code-char bytes))
    ;; Read until we see something that is not part of the escape sequence
    ;; (loop for byte = (read-term-byte fd)
    ;;   while (and byte (< 0 byte 126))
    ;;   do (progn (log:info "Reading escape sequence byte: ~a" byte)
    ;;        (push byte bytes)))
    ;; Reverse the bytes to have them in the original order
    (reverse bytes)))

(defun write-to-fd (fd string)
  (let ((len (length string)))
    (sb-unix:unix-write fd
      (alien-sap (make-alien-string string)) 0 len)))
;; (sb-unix:unix-write slave-fd
;;   (alien-sap (make-alien-string "asdasdfasdfasdff")) 0 47))
;; (defun ansi-clear-screen ()
;;   (write-to-fd slave-fd( format nil "~c[2J" #\esc))
;;   (ansi-cursor-to 0 0))
;; (defun ansi-cursor-to (x y)
;;   (write-to-fd slave-fd (format nil "~c[~A;~AH" #\esc y x)))
;; (defun hide-cursor ()
;;   (write-to-fd slave-fd (format nil "~c[?25l" #\esc)))
;; (defun show-cursor ()
;;   (write-to-fd slave-fd (format nil "~c[?25h" #\esc)))
;; (defun invert-colors ()
;;   (write-to-fd slave-fd (format nil "~c[?5h" #\esc)))
;; (defun reset-colors ()
;;   (write-to-fd slave-fd (format nil "~c[?5l" #\esc)))
;; (defun bg-color (color)
;;   (write-to-fd slave-fd (format nil "~c[48;5;~Am" #\esc color)))
;; (write-to-fd slave-fd (format nil "~ASalut! =)~Adzdz~&"(format nil "~c[48;5;~Am" #\esc 3)(format nil "~c[?5l" #\esc)))
;; (hide-cursor)
;; (invert-colors)
;; (write-to-fd slave-fd "Salut! =\n")
;; (reset-colors)
;; (write-to-fd slave-fd "Oh, hello")
;; (defvar urxvt )
;; (defstruct urxvt-device proc master-fd caps)
;;;---------------------------------------------------------------
;;; PTY Management Utilities (adapted from lowterm/urxvt.lisp)
;;;---------------------------------------------------------------
;; (sb-alien:define-alien-routine "ptsname" sb-alien:c-string (fd sb-alien:int))
;; (sb-alien:define-alien-routine "grantpt" sb-alien:int (fd sb-alien:int))
;; (sb-alien:define-alien-routine "unlockpt" sb-alien:int (fd sb-alien:int))

;; (defun find-pty ()
;;   "Attempts to open a new pseudo-terminal master and returns (VALUES MASTER-FD SLAVE-FD SLAVE-NAME)."
;;   (let ((master-fd (unix-open "/dev/ptmx" (logior o_rdwr o_noctty) 0)))
;;     (when (and master-fd (>= master-fd 0))
;;       (when (zerop (grantpt master-fd))
;;         (when (zerop (unlockpt master-fd))
;;           (let* ((slave-name (ptsname master-fd))
;;                   (slave-fd (unix-open slave-name (logior o_rdwr o_noctty) 0)))
;;             (if (and slave-fd (>= slave-fd 0))
;;               (return-from find-pty (values master-fd slave-fd slave-name))
;;               (progn (unix-close master-fd)
;;                 (error "Could not open PTY slave: ~A" slave-name))))))
;;       (when (and master-fd (>= master-fd 0)) (unix-close master-fd))
;;       (error "Could not grantpt/unlockpt on PTY master.")))
;;   (error "Could not open /dev/ptmx."))

(defstruct urxvt-device
  "URxvt terminal device for cl-inputs.

Fields:
  MASTER-FD        -- PTY master file descriptor (type: integer)
  SLAVE-FD         -- PTY slave file descriptor (type: integer)
  PTY-NAME         -- name of the slave PTY (type: string)
  PROC             -- process object for urxvt (type: process or null)
BLOCKING
  CAPS             -- device capabilities (type: plist)
  STREAM           -- stream for I/O (type: stream)
  ORIGINAL-TERMIOS -- original terminal settings (type: termios struct or null)
  WIDTH, HEIGHT    -- terminal dimensions (type: integer)
  CURSOR-VISIBLE-P -- cursor visibility flag (type: boolean)
  CURSOR-ROW, CURSOR-COL -- cursor position (type: integer)
  CURRENT-STYLE    -- current style attributes (type: plist)
  INPUT-BUFFER     -- buffer for input bytes (type: (array (unsigned-byte 8) *))
  LOCK             -- recursive lock for thread safety (type: lock)

All fields are required unless otherwise noted."
  (master-fd -1 :type integer)
  (slave-fd -1 :type integer)
  (pty-name nil :type (or null string))
  (proc nil :type (or null t))
  (caps '(:truecolor t :mouse t :paste t :focus t :winch t :urxvt t))
  (blocking t :type boolean)
  (stream nil :type (or null stream))
  (original-termios nil );;:type (or null sb-posix:termios))
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

(defun spawn-urxvt (&key (urxvt-program "/usr/bin/urxvt"))
                                        ;(name "cl-inputs-urxvt")
                                        ; (urxvt-args '("-fn" "xft:monospace:size=12")))
  (format t "Spawning URxvt terminal with program: ~A~%" urxvt-program)
  
  (multiple-value-bind (master-fd slave-fd pty-name proc) (cl-user::spawn-urxvt-with-pty)
    (handler-case
      (let* (
              ;; (process (run-program urxvt-program

              ;;            (append urxvt-args (list
              ;;                                 "-name" name
              ;;                                 "-pty-fd"
              ;;                                 (format nil "~A" slave-fd)))
              ;;            :search t :wait nil :input nil :output nil :error :output 
              ;;            :pty (format nil "~A" master-fd))
              ;;   ;; :preserve-fds (list slave-fd) ; SBCL specific, might not be needed if urxvt handles -pty-fd correctly
              ;;   )
              (stream (make-fd-stream master-fd :input t :output t :element-type '(unsigned-byte 8) :buffering :none))
              (original-termios (enable-raw-mode master-fd)) ; Set raw mode on our end of PTY
              (instance (make-urxvt-device :master-fd master-fd
                          :slave-fd slave-fd ; Keep for potential cleanup
                          :pty-name pty-name
                          :proc proc
                          :stream stream
                          :original-termios original-termios)))
        ;; Ensure master is blocking
        (let* ((flags (sb-posix:fcntl master-fd sb-posix:f-getfl))
                (newflags (logandc2 flags sb-posix:o-nonblock)))
          (sb-posix:fcntl master-fd sb-posix:f-setfl newflags))
        (sleep 0.5) ; Give URxvt a moment to start up

        ;; (multiple-value-bind (w h) (get-screen-dimensions instance)
        ;;   (setf (urxvt-device-width instance) w
        ;;     (urxvt-device-height instance) h))
        ;; (elmtui.backend.common.utils:render-seq (get-sequence :cursor-hide))
        ;; (elmtui.backend.common.utils:render-seq (get-sequence :alt-screen-buffer))
        ;; (clear-screen instance)
        ;; (flush-output instance)
        instance)
      (error (c)
        (when (and master-fd (>= master-fd 0)) (unix-close master-fd))
        (when (and slave-fd (>= slave-fd 0)) (unix-close slave-fd))
        (error "Failed to initialize URxvt backend: ~A" c)))))

;; (register-backend :urxvt
;;   #'spawn-urxvt
;;   ;; (lambda (&key (cmd "urxvt") (args '()))
;;   ;;   (multiple-value-bind (master-fd slave-path)
;;   ;;       (allocate-pty)
;;   ;;     (let* ((proc (uiop:launch-program
;;   ;;                   (append (list cmd) args)
;;   ;;                   :input  slave-path
;;   ;;                   :output slave-path
;;   ;;                   :error-output slave-path
;;   ;;                   :detached t)))

;;   ;;       ;; (make-urxvt-device :proc proc
;;   ;;       ;;                    :master-fd master-fd
;;   ;;       ;;                    :caps '(:truecolor t :mouse :urxvt :paste t :focus t :winch t))
;;   ;;       )))
;;   )

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

(defmethod device-input-stream ((dev urxvt-device))
  (urxvt-device-stream dev))

(defmethod device-output-stream ((dev urxvt-device))
  (urxvt-device-stream dev))

(defmethod device-fd ((dev urxvt-device))
  (urxvt-device-master-fd dev))
;; (defmethod close-device ((dev urxvt-device))
;;   (ignore-errors (uiop:terminate-process (urxvt-device-proc dev)))
;;   (ignore-errors (trivial-ptys:close-pty (urxvt-device-master-fd dev)))
;;   t)

(defmethod enable-raw-mode ((term urxvt-device))
  (let ((in-fd (term-in-fd term)))
    (let ((termios (sb-posix:tcgetattr in-fd)))
      (setf (sb-posix:termios-lflag termios)
        (logand (lognot sb-posix:icanon)
          (lognot sb-posix:echo)
          (sb-posix:termios-lflag termios)))
      (sb-posix:tcsetattr in-fd sb-posix:tcsaflush termios)
      (setf (urxvt-device-original-termios term) termios)
      termios)))

(defmethod enable-raw-char-mode ((term urxvt-device)
                                  &key (vmin 1) (vtime 0) (canonical nil) (echo nil) (isig t))
  (let ((in-fd (term-in-fd term)))
    (let* ((orig (or (urxvt-device-original-termios term)
                   (sb-posix:tcgetattr in-fd)))
            (tos  #+sbcl (sb-int:sys-copy-struct orig) #-sbcl orig)
            (cc   (sb-posix:termios-cc tos)))
      ;; Local flags
      (let ((l (sb-posix:termios-lflag tos)))
        (setf l (if canonical (logior l sb-posix:icanon)
                  (logand l (lognot sb-posix:icanon))))
        (setf l (if echo      (logior l sb-posix:echo)
                  (logand l (lognot sb-posix:echo))))
        (setf l (if isig      (logior l sb-posix:isig)
                  (logand l (lognot sb-posix:isig))))
        (setf (sb-posix:termios-lflag tos) l))
      ;; Control chars
      (setf (aref cc sb-posix:vmin)  (the (unsigned-byte 8) vmin)
        (aref cc sb-posix:vtime) (the (unsigned-byte 8) vtime))
      (sb-posix:tcsetattr in-fd sb-posix:tcsaflush tos)
      (setf (urxvt-device-original-termios term) orig)
      t)))

(defmethod cl-inputs.device.api:disable-raw-char-mode ((term urxvt-device))
  (let ((in-fd (term-in-fd term))
         (orig  (urxvt-device-original-termios term)))
    (when orig
      (sb-posix:tcsetattr in-fd sb-posix:tcsaflush orig)
      (setf (urxvt-device-original-termios term) nil)))
  t)
(defmethod disable-raw-mode ((term urxvt-device))
  "Disable raw mode, restoring the previous terminal settings.
TERMIOS is the value returned by ENABLE-RAW-MODE."
  (let ((in-fd (term-in-fd term))
         (termios (urxvt-device-original-termios term)))
    (setf (sb-posix:termios-lflag termios)
      (logior (sb-posix:termios-lflag termios)
        sb-posix:icanon
        sb-posix:echo))
    (sb-posix:tcsetattr in-fd sb-posix:tcsaflush termios)))

(defmethod device-read-bytes ((dev urxvt-device) buffer start end)
  (let ((fd (urxvt-device-master-fd dev)))
    (if (and fd (>= fd 0))
      (with-urxvt-lock (dev)
        ;; Wait up to 50ms for readability to avoid blocking forever
        (when (eq :timeout (sb-sys:wait-until-fd-usable fd :input 0.05))
          (return-from device-read-bytes 0))
        (let ((bytes-read (read-sequence buffer (urxvt-device-stream dev)
                            :start start :end end)))
          (cond
            ((= bytes-read 0) :eof)
            (t bytes-read))))
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

(defmethod cl-inputs.device.api:device-wait-readable ((dev urxvt-device) timeout-ms)
  (let* ((fd (urxvt-device-master-fd dev))
          (secs (and timeout-ms (/ (coerce timeout-ms 'double-float) 1000d0))))
    (sb-sys:wait-until-fd-usable fd :input secs)))

(defmethod device-set-modes ((dev urxvt-device) modes)
  (declare (ignore modes))
  ;; Enable focus and bracketed paste by default
  (let ((esc cl-inputs.terminal.api:+esc+))
    (flet ((send (s) (device-write-bytes dev (cl-inputs.util:string-to-utf-8-bytes s) 0 (length s))))
      (send (format nil "~A[?1004h" esc)) ; focus in/out
      (send (format nil "~A[?2004h" esc)))) ; bracketed paste
  t)
(defmethod make-device
  ((backend (eql :urxvt))
    &key (name "cl-inputs-urxvt") (args '()))
  (declare (ignore name args))

  (let ((dev (spawn-urxvt)))
    (format t "URxvt device created: ~A~%" dev)
    (write-to-fd (slot-value dev 'slave-fd) "Salut! =\n")

    dev))


(defmethod sb-ext::describe-object ((dev urxvt-device) stream)
  (format stream "#<URxvt Device: ~A x ~A, Cursor: ~A, Proc: ~A>"
    (urxvt-device-width dev)
    (urxvt-device-height dev)
    (if (urxvt-device-cursor-visible-p dev) "visible" "hidden")
    (if (urxvt-device-proc dev)
      (format nil "PID ~A" (process-pid (urxvt-device-proc dev)))
      "No process")))

;;; ---------------------------------------------------------------------------
;;; High-level terminal operations

(defun %urxvt-write-string (dev string)
  (let ((bytes (string-to-utf-8-bytes string)))
    (device-write-bytes dev bytes 0 (length bytes))))

(defun %urxvt-fill-string (char width)
  (make-string width :initial-element char))

(defmethod clear-screen ((dev urxvt-device))
  (%emit-ansi dev (format nil "~A[2J~A[H" +esc+ +esc+))
  (setf (urxvt-device-cursor-row dev) 0
    (urxvt-device-cursor-col dev) 0)
  t)

(defmethod clear-area ((dev urxvt-device) row col height width &key style)
  (when (or (<= height 0) (<= width 0))
    (return-from clear-area nil))
  (let ((blank (%urxvt-fill-string #\Space width)))
    (dotimes (dy height)
      (set-cursor-position dev (+ row dy) col)
      (with-styled-output (dev style)
        (%urxvt-write-string dev blank))))
  t)

(defmethod draw-text-at ((dev urxvt-device) row col text &key style)
  (set-cursor-position dev row col)
  (with-styled-output (dev style)
    (%urxvt-write-string dev text))
  (setf (urxvt-device-cursor-col dev) (+ col (length text)))
  t)

(defmethod draw-char-at ((dev urxvt-device) row col char &key style)
  (set-cursor-position dev row col)
  (with-styled-output (dev style)
    (%urxvt-write-string dev (string char)))
  (setf (urxvt-device-cursor-col dev) col)
  t)

(defmethod fill-rectangle
  ((dev urxvt-device) row col height width
    &key (char #\Space) style)
  (when (or (<= height 0) (<= width 0))
    (return-from fill-rectangle nil))
  (let ((line (%urxvt-fill-string char width)))
    (dotimes (dy height)
      (set-cursor-position dev (+ row dy) col)
      (with-styled-output (dev style)
        (%urxvt-write-string dev line))))
  t)

(defmethod scroll-lines ((dev urxvt-device) count)
  (cond
    ((> count 0) (%emit-ansi dev "~a[~dS" +esc+ count))
    ((< count 0) (%emit-ansi dev "~a[~dT" +esc+ (- count))))
  t)

(defmethod set-cursor-position ((dev urxvt-device) row col)
  (%emit-ansi dev "~a[~d;~dH" +esc+ (1+ row) (1+ col))
  (setf (urxvt-device-cursor-row dev) row
    (urxvt-device-cursor-col dev) col)
  t)

(defmethod get-cursor-position ((dev urxvt-device))
  (values (urxvt-device-cursor-row dev)
    (urxvt-device-cursor-col dev)))

(defmethod hide-cursor ((dev urxvt-device))
  (%emit-ansi dev "~a[?25l" +esc+)
  (setf (urxvt-device-cursor-visible-p dev) nil)
  t)

(defmethod show-cursor ((dev urxvt-device))
  (%emit-ansi dev "~a[?25h" +esc+)
  (setf (urxvt-device-cursor-visible-p dev) t)
  t)

(defmethod flush-output ((dev urxvt-device))
  (when (urxvt-device-stream dev)
    (finish-output (urxvt-device-stream dev)))
  t)

(defmethod apply-style ((dev urxvt-device) style)
  (let ((sgr (%style->sgr-string style)))
    (when sgr
      (%emit-ansi dev "~a[~am" +esc+ sgr)
      (setf (urxvt-device-current-style dev) style)))
  t)

(defmethod reset-style ((dev urxvt-device))
  (%emit-ansi dev "~a[0m" +esc+)
  (setf (urxvt-device-current-style dev) nil)
  t)

(defmacro with-raw-mode ((dev) &body body)
  "
Execute ~body~ with the terminal device ~dev~ temporarily set to raw mode.

This macro:
+ Calls ~enable-raw-mode~ on ~dev~ before executing ~body~, saving the original terminal settings.
+ Ensures that ~disable-raw-mode~ is called with the saved settings after ~body~ finishes, even if an error occurs (using ~unwind-protect~).
+ Guarantees that the terminal state is always restored, making it safe for interactive or error-prone code.
"
  `(let ((original-termios (enable-raw-mode ,dev)))
     (declare (ignore original-termios))
     (unwind-protect
       (progn ,@body)
       (disable-raw-mode ,dev))))

(defmethod device-set-nonblocking ((dev urxvt-device) flag)
  (let* ((fd (sb-sys:fd-stream-fd (urxvt-device-stream dev)))
          (fl (sb-posix:fcntl fd sb-posix:f-getfl)))
    (setf fl (if flag
               (logior fl sb-posix:o-nonblock)
               (logand fl (lognot sb-posix:o-nonblock))))
    (sb-posix:fcntl fd sb-posix:f-setfl fl)
    (setf (urxvt-device-blocking dev)
      (not (zerop (logand (sb-posix:fcntl fd sb-posix:f-getfl) sb-posix:o-nonblock))))
    (urxvt-device-blocking dev)))

;; (defmethod enable-raw-char-mode ((dev urxvt-device)
;;                                   &key (vmin 1) (vtime 0)
;;                                   (canonical nil) (echo nil) (isig t))
;;   "Enable raw character mode on the terminal device TERM."
;;   (let ((in-fd (term-in-fd dev)))
;;     (format t "Enabling raw char mode on FD: ~A~%" in-fd)
;;     (let ((termios (sb-posix:tcgetattr in-fd)))

;;       (let* ((orig (sb-posix:tcgetattr in-fd))
;;               (tos  #+sbcl (sb-int:sys-copy-struct orig) #-sbcl orig)
;;               (cc   (sb-posix:termios-cc tos)))
;;         (setf (sb-posix:termios-lflag termios)
;;           (logand (lognot sb-posix:icanon) (lognot sb-posix:echo)))
;;         (setf (aref cc sb-posix:vmin) (the (unsigned-byte 8) vmin)
;;           (aref cc sb-posix:vtime) (the (unsigned-byte 8) vtime))
;;         (sb-posix:tcsetattr in-fd sb-posix:tcsaflush termios)
;;         (sb-posix:tcsetattr in-fd sb-posix:tcsanow tos)
;;         (setf (urxvt-device-original-termios dev) termios)
;;         termios))))
