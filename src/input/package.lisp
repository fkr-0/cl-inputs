;;;; cl-inputs/package.lisp
;;;
;;; Main package definition for cl-inputs.
;;; Re-exports all major submodules to provide a unified interface.

(uiop:define-package :cl-inputs
  (:use :cl :alexandria :log4cl)
  (:use-reexport :cl-inputs.api :cl-inputs.device.api
    :cl-inputs.loop :cl-inputs.sink :cl-inputs.decoder
    :cl-inputs.keymap :cl-inputs.tokens :cl-inputs.terminal.api))

(in-package :cl-inputs)


