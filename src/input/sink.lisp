(in-package :cl-inputs.sink)

(defgeneric accept-token (sink token)
  (:documentation "Main delivery method. Default: NO-OP."))

(defgeneric on-key (sink token))
(defgeneric on-mouse (sink token))
(defgeneric on-resize (sink token))
(defgeneric on-paste (sink token))
(defgeneric on-focus (sink token))

;; Defaults: do nothing
(defmethod accept-token ((sink t) (tok cl-inputs.tokens:input-token)) (declare (ignore sink tok)) nil)
(defmethod on-key   ((sink t) (tok cl-inputs.tokens:input-token)) (declare (ignore sink tok)) nil)
(defmethod on-mouse ((sink t) (tok cl-inputs.tokens:input-token)) (declare (ignore sink tok)) nil)
(defmethod on-resize((sink t) (tok cl-inputs.tokens:input-token)) (declare (ignore sink tok)) nil)
(defmethod on-paste ((sink t) (tok cl-inputs.tokens:input-token)) (declare (ignore sink tok)) nil)
(defmethod on-focus ((sink t) (tok cl-inputs.tokens:input-token)) (declare (ignore sink tok)) nil)

;; Convenience: if user passes a plain function, treat it as accept-token
(defun fn-sink (fn)
  (lambda (token) (funcall fn token)))

(defun tee-sink (&rest sinks)
  (lambda (token)
    (dolist (s sinks)
      (cond
        ((functionp s) (funcall s token))
        (t (accept-token s token))))))