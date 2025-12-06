(defpackage :cl-inputs.example.key-printer
  (:use :cl :cl-inputs.api)
  (:export #:main))

(in-package :cl-inputs.example.key-printer)

(defun main ()
  (let* ((dev (cl-inputs.device.api:make-device :tty))
          (src (cl-inputs.loop:make-input-source :device dev)))
    (unwind-protect
      (progn
        (format t "Press any key to see its representation. Press ESC to quit.~%")
        (loop for tok = (cl-inputs.loop:next-token src)
          do (format t "Token: ~S~%" tok)
          until (and (eq (cl-inputs.tokens:input-token-kind tok) :key)
                  (eq (getf (cl-inputs.tokens:input-token-data tok) :code) :escape))))
      (cl-inputs.loop:close-input-source src))))
