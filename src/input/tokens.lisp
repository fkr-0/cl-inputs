(in-package :cl-inputs.tokens)

(defparameter +k-key+    :key) ;; a key press or release event
(defparameter +k-mouse+  :mouse) ;; a mouse event (click, move, etc.)
(defparameter +k-resize+ :resize) ;; a terminal resize event
(defparameter +k-paste+  :paste) ;; a paste event (e.g., from clipboard)
(defparameter +k-focus+  :focus) ;; a focus event (focus in or out)

(defstruct input-token
  kind   ;; one of the +k-*+ keywords
  data   ;; plist describing the token (e.g., :code :enter :mods (:ctrl))
  ts)    ;; timestamp (universal-time or monotonic)

(defun make-token (kind data &optional ts)
  (make-input-token :kind kind :data data :ts (or ts (get-universal-time))))
