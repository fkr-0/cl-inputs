(in-package :cl-inputs.tokens)

(defparameter +k-key+    :key)
(defparameter +k-mouse+  :mouse)
(defparameter +k-resize+ :resize)
(defparameter +k-paste+  :paste)
(defparameter +k-focus+  :focus)

(defstruct input-token
  kind   ;; one of the +k-*+ keywords
  data   ;; plist describing the token (e.g., :code :enter :mods (:ctrl))
  ts)    ;; timestamp (universal-time or monotonic)

(defun make-token (kind data &optional ts)
  (make-input-token :kind kind :data data :ts (or ts (get-universal-time))))