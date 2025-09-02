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

(load "cl-inputs.asd")
(asdf:load-asd "./cl-inputs.asd")
(asdf:load-system :cl-inputs)
;; (load "./examples/key-printer.lisp")

;; (cl-inputs.example.key-printer:main)

(defvar il (let ((input-loop (cl-inputs.api:start-input-loop)))input-loop) )
