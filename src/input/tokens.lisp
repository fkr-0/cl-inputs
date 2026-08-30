;;;; cl-inputs.tokens.lisp
;;;
;;; Token types and constructors for cl-inputs.
;;; Defines the input-token struct and helpers for token creation and inspection.
(uiop:define-package :cl-inputs.tokens
  (:use :cl :alexandria)
  (:export #:input-token #:make-token #:input-token-kind #:input-token-data #:input-token-ts
    ;; common :kind values
    #:+k-key+ #:+k-mouse+ #:+k-resize+ #:+k-paste+ #:+k-focus+
    #:+k-terminal-response+ #:+k-protocol+))
(in-package :cl-inputs.tokens)

(defparameter +k-key+    :key)    ;; a key press or release event
(defparameter +k-mouse+  :mouse)  ;; a mouse event (click, move, etc.)
(defparameter +k-resize+ :resize) ;; a terminal resize event
(defparameter +k-paste+  :paste)  ;; a paste event (e.g., from clipboard)
(defparameter +k-focus+  :focus)  ;; a focus event (focus in or out)
(defparameter +k-terminal-response+ :terminal-response)
;; A syntactically valid terminal reply. Source routing keeps these off the
;; ordinary user-input path and offers them to response correlations instead.
(defparameter +k-protocol+ :protocol) ;; diagnostic/unsupported protocol outcome

(defstruct input-token
  "A token representing a single input event.

Fields:
  KIND -- event kind (type: keyword, one of the +k-*+ constants)
  DATA -- event data (type: plist, e.g., (:code :enter :mods (:ctrl)))
  TS   -- timestamp (type: universal-time or monotonic integer)

All fields are required."
  kind
  data
  ts)

(defun make-token (kind data &optional ts)
  "Construct an input-token of KIND with DATA and optional TS (timestamp).
If TS is not provided, uses the current universal time."
  (make-input-token :kind kind :data data :ts (or ts (get-universal-time))))
