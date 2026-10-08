;;;; Launched only by tmux-terminal-apps.py in its private terminal.
;;;; All interaction traverses the public TTY/input-source/terminal APIs.
(require :asdf)
(asdf:load-system "cl-inputs")

(defun %tmux-draw (device row text)
  (cl-inputs.terminal.api:draw-text-at device row 4
                                      (format nil "~A~32@T" text))
  (cl-inputs.terminal.api:flush-output device))

(let* ((device (cl-inputs.device.api:make-device :tty))
       (source nil)
       (seen 0)
       (mode (uiop:getenv "CL_INPUTS_TMUX_CASE")))
  (unwind-protect
       (progn
         (setf source (cl-inputs.loop:make-input-source :device device))
         (cl-inputs.terminal.api:hide-cursor device)
         (cl-inputs.api:set-terminal-modes device :paste t)
         (%tmux-draw device 2 "CL_INPUTS_READY")
         (loop
           for token = (cl-inputs.loop:next-token source :timeout 5d0)
           do (unless token (error "No input within 5 seconds"))
              (let* ((kind (cl-inputs.tokens:input-token-kind token))
                     (data (cl-inputs.tokens:input-token-data token))
                     (code (getf data :code)))
                (incf seen)
                (cond
                  ((eq kind :paste)
                   (%tmux-draw device 4
                               (format nil "CL_INPUTS_PASTE:~A"
                                       (getf data :content))))
                  ((and (eq kind :key) (eql code :up))
                   (%tmux-draw device 4 "CL_INPUTS_UP"))
                  ((and (eq kind :key) (eql code #\q))
                   (%tmux-draw device 4
                               (format nil "CL_INPUTS_QUIT:~D" seen))
                   (return))
                  ((and (eq kind :key) (eql code #\x)
                        (equal mode "exception"))
                   (error "CL_INPUTS_INTENTIONAL_E2E_EXCEPTION"))
                  ((eq kind :key)
                   (%tmux-draw device 4
                               (format nil "CL_INPUTS_KEY:~A" code)))
                  (t
                   (%tmux-draw device 4
                               (format nil "CL_INPUTS_KIND:~A" kind)))))))
    ;; An exception must still unwind raw mode and cursor ownership.
    (cl-inputs.terminal.api:show-cursor device)
    (when source (cl-inputs.loop:close-input-source source))
    (cl-inputs.device.api:close-device device)))
