;;;; Invoked only by tests/pty-e2e.py in a real Linux pseudo-terminal.
;;;; Assertions run against the tty-device, source, response router and
;;;; terminal output API, never directly against the decoder.
(require :asdf)
(asdf:load-system "cl-inputs")

(defun %pty-assert (truth description)
  (unless truth (error "PTY E2E assertion failed: ~A" description)))

(defun %pty-announce (stage)
  (format t "@@PTY:~A~%" stage)
  (finish-output))

(defun %pty-token (source kind code)
  (let ((token (cl-inputs.loop:next-token source :timeout 3d0)))
    (%pty-assert token (format nil "~A token exists" kind))
    (%pty-assert (eq kind (cl-inputs.tokens:input-token-kind token))
                 (format nil "token kind ~A" kind))
    (%pty-assert (eql code (getf (cl-inputs.tokens:input-token-data token) :code))
                 (format nil "token code ~A" code))))

(let* ((path (or (uiop:getenv "CL_INPUTS_PTY_SLAVE")
                 (error "CL_INPUTS_PTY_SLAVE not provided")))
       (dev (cl-inputs.device.api:make-device :tty :path path))
       (src nil))
  (unwind-protect
       (progn
         (setf src (cl-inputs.loop:make-input-source :device dev))
         (let* ((fd (cl-inputs.device.api:device-fd dev))
                (termios (sb-posix:tcgetattr fd))
                (flags (sb-posix:termios-lflag termios)))
           (%pty-assert (zerop (logand flags sb-posix:icanon))
                        "ICANON disabled")
           (%pty-assert (zerop (logand flags sb-posix:echo))
                        "ECHO disabled")
           (%pty-assert (not (zerop (logand flags sb-posix:isig)))
                        "ISIG preserved"))
         ;; Nesting must not restore while another owner remains active.
         (cl-inputs.device.api:enable-raw-char-mode dev)
         (%pty-assert (= 2 (cl-inputs.device.tty::%tty-raw-depth dev))
                      "nested raw-mode depth")
         (cl-inputs.device.api:disable-raw-char-mode dev)
         (%pty-assert (= 1 (cl-inputs.device.tty::%tty-raw-depth dev))
                      "nested raw-mode still active")
         ;; The driver has not sent any input yet: zero-timeout reads
         ;; must not fabricate a key, consume EOF, or close the device.
         (%pty-assert (null (cl-inputs.loop:next-token src :timeout 0))
                      "empty PTY is a timeout, not an EOF")
         (%pty-assert (eq :open (cl-inputs.loop:input-source-state src))
                      "source remains open after a nonblocking timeout")
         ;; The driver observes the raw flags before delivering any input.
         (%pty-announce "READY input")
         (%pty-token src :key #\a)
         (%pty-token src :key (code-char #x00e9))
         (%pty-token src :key :up)
         (let* ((focus (cl-inputs.loop:next-token src :timeout 3d0))
                (data (and focus (cl-inputs.tokens:input-token-data focus))))
           (%pty-assert (and (eq :focus (cl-inputs.tokens:input-token-kind focus))
                             (getf data :gained))
                        "real TTY focus-in event"))
         (let* ((mouse (cl-inputs.loop:next-token src :timeout 3d0))
                (data (and mouse (cl-inputs.tokens:input-token-data mouse))))
           (%pty-assert (and (eq :mouse (cl-inputs.tokens:input-token-kind mouse))
                             (eq :mouse-down (getf data :type))
                             (= 2 (getf data :x)) (= 3 (getf data :y)))
                        "real TTY SGR mouse coordinates"))
         (let* ((paste (cl-inputs.loop:next-token src :timeout 3d0))
                (data (and paste (cl-inputs.tokens:input-token-data paste))))
           (%pty-assert (and (eq :paste (cl-inputs.tokens:input-token-kind paste))
                             (string= (format nil "hello ~A" (code-char #x03bb))
                                      (getf data :content))
                             (getf data :valid-utf8-p))
                        "real TTY bracketed UTF-8 paste"))

         ;; The registered query is written on the real PTY. A user key
         ;; precedes the response, but must remain in the pull queue.
         (let ((request (cl-inputs.loop:send-terminal-query
                         src :cursor-position :timeout 3d0)))
           (%pty-announce "READY reply")
           (let ((response (cl-inputs.loop:wait-terminal-response
                            src request :timeout 3d0)))
             (%pty-assert (eq :matched
                              (cl-inputs.routing:response-correlation-state request))
                          "cursor reply correlation matched")
             (%pty-assert (eq :terminal-response
                              (cl-inputs.tokens:input-token-kind response))
                          "cursor reply token")
             (%pty-assert (= 6 (getf (cl-inputs.tokens:input-token-data response) :row))
                          "cursor reply row")
             (%pty-assert (= 13 (getf (cl-inputs.tokens:input-token-data response) :column))
                          "cursor reply column")))
         (%pty-token src :key #\k)
         ;; Invalid terminal reply should become an isolated diagnostic;
         ;; subsequent user input must still be delivered.
         (%pty-announce "READY malformed")
         (%pty-token src :key #\q)
         (let* ((diag (cl-inputs.loop:take-input-protocol-diagnostic src))
                (data (and diag (cl-inputs.tokens:input-token-data diag))))
           (%pty-assert (and (eq :protocol (cl-inputs.tokens:input-token-kind diag))
                             (eq :unknown-sequence (getf data :category)))
                        "malformed CSI isolated from user input"))

         ;; The size API is explicitly a cached-value API, not ioctl/DSR.
         (multiple-value-bind (width height)
             (cl-inputs.terminal.api:get-terminal-size dev)
           (%pty-assert (and (= width 80) (= height 24))
                        "cached 80x24 dimensions"))
         (cl-inputs.api:set-terminal-modes dev
                                           :mouse :sgr :focus t :paste t)
         (cl-inputs.terminal.api:draw-text-at dev 1 2 "OK")
         (cl-inputs.terminal.api:hide-cursor dev)
         (cl-inputs.terminal.api:show-cursor dev)
         (cl-inputs.terminal.api:flush-output dev)
         (%pty-announce "READY close"))
    (when src (cl-inputs.loop:close-input-source src))
    (cl-inputs.device.api:close-device dev))
  ;; The parent must acknowledge observing restored termios before we
  ;; re-enter raw mode; otherwise its inspection races the second owner.
  (%pty-announce "RESTORED source")
  (%pty-assert (string= "resume" (read-line *standard-input* nil ""))
               "parent acknowledged restoration checkpoint")
  ;; Exercise the macro and exceptional unwind with a fresh owned TTY lifetime.
  (let ((caught nil))
    (handler-case
        (cl-inputs.api:with-raw-input (dev)
          (%pty-assert (= 1 (cl-inputs.device.tty::%tty-raw-depth dev))
                       "scoped raw mode enabled")
          (error "PTY injected scoped body failure"))
      (error (condition)
        (setf caught (search "PTY injected scoped" (princ-to-string condition)))))
    (%pty-assert caught "scoped exception propagated"))
  (%pty-announce "DONE"))
