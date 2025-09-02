(in-package :cl-inputs.api)

;; This file is mostly for re-exporting symbols from the other packages
;; to create a single, unified public API.

(defmacro with-raw-input ((dev) &body body)
  `(progn  ;; let ((,dev (cl-inputs.device:open-device dev)))
     (unwind-protect
          (progn (cl-inputs.device:enable-raw-mode ,dev) ,@body)
       (cl-inputs.device:disable-raw-mode ,dev)
       (cl-inputs.device:close-device ,dev))))

(defun read-tokens (dev &key (timeout 5))
  "Reads tokens from a device until timeout."
  (let ((src (make-input-source :device dev))
        (tokens '()))
    (loop for tok = (next-token src :timeout timeout)
          while tok
          do (push tok tokens))
    (close-input-source src)
    (nreverse tokens)))

(defmacro with-async-signal (return-var &body body)
  "Spawn a background thread running BODY.  RETURN-VAR is a user-supplied symbol,
initialized to NIL; you can (SETF RETURN-VAR …) anywhere in BODY to record progress
or final result.  Defines a global function SIGNAL-FN which, when called, will:

 1. interrupt the thread,
 2. throw a tag 'interrupt carrying the current RETURN-VAR,
 3. return that RETURN-VAR to the caller of SIGNAL-FN.

The macro expands to evaluating to the thread object itself."
  (let* ((pkg *package*)
         (thread-name (format nil "__~A-THREAD__" (symbol-name return-var)))
         (thread-sym  (intern thread-name pkg))
         (device (make-device :tty))
         (ret-sym (gensym)))
    `(progn

       ;; export the thread-sym so it can be used in the signal function
       ;; export the signal-fn so it can be used in the thread
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
