(uiop:define-package :cl-inputs.sink
  (:use :cl :alexandria :cl-inputs.tokens)
  (:export #:accept-token #:on-key #:on-mouse #:on-resize #:on-paste #:on-focus
           #:on-ctrl-c #:tee-sink #:fn-sink))

(in-package :cl-inputs.sink)

(defgeneric accept-token (sink token)
  (:documentation "Deliver TOKEN to SINK. The default method is a no-op."))
(defgeneric on-key (sink token) (:documentation "Handle a :key token."))
(defgeneric on-mouse (sink token) (:documentation "Handle a :mouse token."))
(defgeneric on-resize (sink token) (:documentation "Handle a :resize token."))
(defgeneric on-paste (sink token) (:documentation "Handle a :paste token."))
(defgeneric on-focus (sink token) (:documentation "Handle a :focus token."))
(defgeneric on-ctrl-c (sink token) (:documentation "Handle a :ctrl-c token."))

(defmethod accept-token ((sink t) (token cl-inputs.tokens:input-token))
  (declare (ignore sink token))
  nil)
(defmethod on-key ((sink t) (token cl-inputs.tokens:input-token))
  (declare (ignore sink token))
  nil)
(defmethod on-mouse ((sink t) (token cl-inputs.tokens:input-token))
  (declare (ignore sink token))
  nil)
(defmethod on-resize ((sink t) (token cl-inputs.tokens:input-token))
  (declare (ignore sink token))
  nil)
(defmethod on-paste ((sink t) (token cl-inputs.tokens:input-token))
  (declare (ignore sink token))
  nil)
(defmethod on-focus ((sink t) (token cl-inputs.tokens:input-token))
  (declare (ignore sink token))
  nil)
(defmethod on-ctrl-c ((sink t) (token cl-inputs.tokens:input-token))
  (declare (ignore sink token))
  nil)

(defun fn-sink (fn)
  "Adapt FN to a token sink function."
  (lambda (token) (funcall fn token)))

(defun tee-sink (&rest sinks)
  "Return a sink function that fans each token out to SINKS in order."
  (lambda (token)
    (dolist (sink sinks)
      (if (functionp sink)
          (funcall sink token)
          (accept-token sink token)))))
