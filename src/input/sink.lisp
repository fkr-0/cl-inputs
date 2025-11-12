;;;; cl-inputs.sink.lisp
;;;
;;; Sink protocol for input token delivery.
;;; Defines generic methods for handling different token kinds and helpers for composing sinks.
(uiop:define-package :cl-inputs.sink
  (:use :cl :alexandria :cl-inputs.tokens)
  (:export
    ;; Sink port (generics; defaults are NO-OP)
    #:accept-token #:on-key #:on-mouse #:on-resize #:on-paste #:on-focus #:on-ctrl-c
    ;; Helpers for composing sinks:
    #:tee-sink #:fn-sink))
(in-package :cl-inputs.sink)

(defgeneric accept-token (sink token)
  (:documentation "Main delivery method for delivering a token to a sink.
Default implementation is a no-op. Override for custom sink behavior."))

(defgeneric on-key (sink token)
  (:documentation "Handle a :key token. Override for custom key handling."))
(defgeneric on-mouse (sink token)
  (:documentation "Handle a :mouse token. Override for custom mouse handling."))
(defgeneric on-resize (sink token)
  (:documentation "Handle a :resize token. Override for custom resize handling."))
(defgeneric on-paste (sink token)
  (:documentation "Handle a :paste token. Override for custom paste handling."))
(defgeneric on-focus (sink token)
  (:documentation "Handle a :focus token. Override for custom focus handling."))
(defgeneric on-ctrl-c (sink token)
  (:documentation "Handle a :ctrl-c token. Override for custom ctrl-c handling."))

;; Defaults: do nothing
(defmethod accept-token ((sink t) (tok cl-inputs.tokens:input-token))
  "Default accept-token method: does nothing."
  (declare (ignore sink tok)) nil)
(defmethod on-key   ((sink t) (tok cl-inputs.tokens:input-token))
  "Default on-key method: does nothing."
  (declare (ignore sink tok)) nil)
(defmethod on-mouse ((sink t) (tok cl-inputs.tokens:input-token))
  "Default on-mouse method: does nothing."
  (declare (ignore sink tok)) nil)
(defmethod on-resize((sink t) (tok cl-inputs.tokens:input-token))
  "Default on-resize method: does nothing."
  (declare (ignore sink tok)) nil)
(defmethod on-paste ((sink t) (tok cl-inputs.tokens:input-token))
  "Default on-paste method: does nothing."
  (declare (ignore sink tok)) nil)
(defmethod on-focus ((sink t) (tok cl-inputs.tokens:input-token))
  "Default on-focus method: does nothing."
  (declare (ignore sink tok)) nil)

;; Convenience: if user passes a plain function, treat it as accept-token
(defun fn-sink (fn)
  (lambda (token) (funcall fn token)))

(defun tee-sink (&rest sinks)
  (lambda (token)
    (dolist (s sinks)
      (cond
        ((functionp s) (funcall s token))
        (t (accept-token s token))))))
