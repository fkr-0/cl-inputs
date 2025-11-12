;;; run_clpm.lisp
;;; Runs an Elmtui example application directly.
"
Usage:
  sbcl --load run_clpm.lisp
This script sets up logging, loads the Elmtui system,
and runs a pre-configured example application.
It may drop you into the REPL after the application finishes or if it's non-blocking.
To run non-interactively, use sbcl --non-interactive --load run_clpm.lisp
"

(require 'log4cl)
(log4cl:log-info "Hm")
(load "cl-inputs.asd")
(asdf:load-asd "./cl-inputs.asd")
(asdf:load-system :cl-inputs)
;; (load "./examples/key-printer.lisp")

;; (cl-inputs.example.key-printer:main)

(defvar il
  (let ((input-loop (cl-inputs:start-input-loop :mode :sync)))input-loop) )
;; == demo ==
;; (let* ((dev (cl-inputs.device.tty:make-tty-device))
;;         (buf (make-array 1024 :element-type '(unsigned-byte 8))))
;;   (cl-inputs.device.api:open-device dev)
;;   (cl-inputs.device.api:with-raw-char-mode (dev)  ;; VMIN=1 / VTIME=0
;;     (loop
;;       (let ((n (cl-inputs.device.api:device-read-bytes dev buf 0 (length buf))))
;;         (when (eql n :eof) (return))
;;         (when (> n 0)
;;           (format t "~&Read ~d bytes: ~{~2,'0X~^ ~}~%" n
;;             (loop for i below n collect (aref buf i))))))))
