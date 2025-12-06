(uiop:define-package :cl-inputs.api
  (:use :cl :alexandria :cl-inputs.tokens :cl-inputs.decoder :cl-inputs.device.api :cl-inputs.sink)
  (:import-from :log4cl #:log-info)
  (:export
    ;; Pull/Push helpers
    #:with-raw-input
    #:make-ready-input-source
    #:with-input-source
    #:set-terminal-modes
    #:read-tokens
    ;; Async input handling
    #:with-async-signal))

;; #:with-interruptible-input-reader))

(in-package :cl-inputs.api)

;;;; cl-inputs.api.lisp
;;;
;;; Unified public API for cl-inputs. This file primarily re-exports symbols from
;;; submodules to provide a single entry point for input handling. Extend here for
;;; additional user-facing macros or helpers.
;;;
;;; All exported symbols should be documented and idiomatic.

(defmacro with-raw-input ((dev) &body body)
  "Open DEV and enable raw-char-mode + raw-mode for BODY; restore/close on exit."
  `(progn
     (unwind-protect
       (progn
         (cl-inputs.device.api:open-device ,dev)
         (ignore-errors (cl-inputs.device.api:enable-raw-char-mode ,dev))
         (cl-inputs.device.api:enable-raw-mode ,dev)
         (log-info "> Enabled raw input on device ~A" ,dev)
         ,@body)
       (ignore-errors (cl-inputs.device.api:disable-raw-char-mode ,dev))
       (ignore-errors (cl-inputs.device.api:disable-raw-mode ,dev))
       (ignore-errors (cl-inputs.device.api:close-device ,dev)))))

(defun make-ready-input-source (&key (device (cl-inputs.device.api:make-device :tty)) (decoder (cl-inputs.decoder:make-decoder)))
  "Open DEVICE, enable raw-char-mode, and return an input-source ready for next-token."
  (cl-inputs.device.api:open-device device)
  (ignore-errors (cl-inputs.device.api:enable-raw-char-mode device))
  (cl-inputs.device.api:enable-raw-mode device)
  (cl-inputs.loop:make-input-source :device device :decoder decoder))

(defmacro with-input-source ((var &key (device '(cl-inputs.device.api:make-device :tty)) (decoder '(cl-inputs.decoder:make-decoder))) &body body)
  "Bind VAR to a ready input-source around BODY; cleans up on exit."
  `(let ((,var (make-ready-input-source :device ,device :decoder ,decoder)))
     (unwind-protect
       (progn ,@body)
       (ignore-errors (cl-inputs.loop:close-input-source ,var)))))

(defun set-terminal-modes (dev &key mouse focus paste)
  "Convenience: toggle device terminal modes via device-set-modes."
  (let ((modes (list :mouse mouse :focus focus :paste paste)))
    (cl-inputs.device.api:device-set-modes dev modes)))

(defun read-tokens (dev &key (timeout 5))
  "Read all available tokens from DEV until TIMEOUT seconds elapse.

Arguments:
  DEV     -- device object supporting input
  TIMEOUT -- maximum seconds to wait for input (type: real, default: 5)

Return Value:
  List of tokens read from DEV.

Side Effects:
  Closes the input source after reading."
  (let ((src (cl-inputs.loop:make-input-source :device dev))
         (tokens '()))
    (loop for tok = (cl-inputs.loop:next-token src :timeout timeout)
      while tok
      do (push tok tokens))
    (cl-inputs.loop:close-input-source src)
    (nreverse tokens)))

(defmacro with-async-signal (return-var &body body)
  "Run BODY in a background thread, allowing interruption and result retrieval.
RETURN-VAR is a symbol bound to NIL and can be set within BODY to track progress or result.
Defines a SIGNAL-FN function that interrupts the thread and returns the current value of RETURN-VAR.
Returns (values thread signal-fn device)."
  (let* ((pkg *package*)
          (thread-name (format nil "__~A-THREAD__" (symbol-name return-var)))
          (thread-sym  (intern thread-name pkg))
          (device (make-device :tty))
          (ret-sym (gensym)))
    `(progn

       ;; Export the thread symbol and signal function for use in the thread context.
       ;; 3. Start the thread, wrapping BODY in a (CATCH 'interrupt …)
       (let* ((,return-var nil)
               (,ret-sym ,return-var)
               (,thread-sym
                 (bordeaux-threads:make-thread
                   (lambda ()
                     (catch 'interrupt
                       (with-raw-input
                         ,device
                         ,@body)))))
               (interrupt-fn
                 (lambda ()

                   ;; 1. Interrupt the thread
                   ;; 2. Throw 'interrupt with last value of RETURN-VAR
                   ;; Note: We use a lambda here to delay the evaluation of RETURN-VAR
                   ;; until the interrupt function is called.)
                   ;; ,(format
                   ;;   nil
                   ;;   "Interrupt thread ~A% and return last value of ~A%."
                   ;;   `,thread-name `,return-var)
                   (bordeaux-threads:interrupt-thread
                     ,thread-sym
                     (lambda () (throw 'interrupt ,ret-sym)))
                   ,return-var)))
         (values ,thread-sym interrupt-fn device)))))
