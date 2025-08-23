(in-package :cl-inputs.api)

;; This file is mostly for re-exporting symbols from the other packages
;; to create a single, unified public API.

(defmacro with-raw-input ((dev) &body body)
  `(let ((,dev (cl-inputs.device:open-device)))
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