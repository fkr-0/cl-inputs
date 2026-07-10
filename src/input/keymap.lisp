;;;; cl-inputs.keymap.lisp
;;;
;;; Key sequence mapping utilities for cl-inputs.
;;; Provides lookup and canonicalization for keyboard input events.
(uiop:define-package :cl-inputs.keymap
  (:use :cl :alexandria #:log4cl)
  (:export #:*default-keymap* #:lookup-seq #:canonicalize-key))
(in-package :cl-inputs.keymap)

(defparameter *default-keymap*
  `( (,(mapcar #'char-code '(#\Esc #\[ #\A)) :up)
     (,(mapcar #'char-code '(#\Esc #\[ #\B)) :down)
     (,(mapcar #'char-code '(#\Esc #\[ #\C)) :right)
     (,(mapcar #'char-code '(#\Esc #\[ #\D)) :left)
     (,(list (char-code #\Return))      :enter)
     (,(list (char-code #\Tab))         :tab)
     (,(list (char-code #\Backspace))   :backspace)
     (,(list 127) :backspace) ; DEL
     (,(mapcar #'char-code '(#\Esc #\[ #\1 #\~)) :home)
     (,(mapcar #'char-code '(#\Esc #\[ #\4 #\~)) :end)
     (,(mapcar #'char-code '(#\Esc #\[ #\5 #\~)) :page-up)
     (,(mapcar #'char-code '(#\Esc #\[ #\6 #\~)) :page-down)
     (,(mapcar #'char-code '(#\Esc #\[ #\2 #\~)) :insert)
     (,(mapcar #'char-code '(#\Esc #\[ #\3 #\~)) :delete)
     (,(mapcar #'char-code '(#\Esc #\O #\P)) :f1)
     (,(mapcar #'char-code '(#\Esc #\O #\Q)) :f2)
     (,(mapcar #'char-code '(#\Esc #\O #\R)) :f3)
     (,(mapcar #'char-code '(#\Esc #\O #\S)) :f4)
     (,(mapcar #'char-code '(#\Esc #\[ #\1 #\5 #\~)) :f5)
     (,(mapcar #'char-code '(#\Esc #\[ #\1 #\7 #\~)) :f6)
     (,(mapcar #'char-code '(#\Esc #\[ #\1 #\8 #\~)) :f7)
     (,(mapcar #'char-code '(#\Esc #\[ #\1 #\9 #\~)) :f8)
     (,(mapcar #'char-code '(#\Esc #\[ #\2 #\0 #\~)) :f9)
     (,(mapcar #'char-code '(#\Esc #\[ #\2 #\1 #\~)) :f10)
     (,(mapcar #'char-code '(#\Esc #\[ #\2 #\3 #\~)) :f11)
     (,(mapcar #'char-code '(#\Esc #\[ #\2 #\4 #\~)) :f12)
     ;; Common alternate Home/End encodings.
     (,(mapcar #'char-code '(#\Esc #\[ #\H)) :home)
     (,(mapcar #'char-code '(#\Esc #\[ #\F)) :end))
  "Default keymap: maps common escape sequences to symbolic key names.
Extend this table to support additional keys or custom layouts."
  )

(defun lookup-seq (octets &optional (table *default-keymap*))
  "Look up OCTETS (vector of char codes) in TABLE and return the mapped key symbol.
Returns NIL if no match is found."
  (log-debug "Looking up sequence: ~A" octets)
  (let ((match (find (coerce octets 'list) table
                 :key #'first
                 :test #'equal)))
    (and match (second match))))

(defun %character-key-name (char)
  (case char
    (#\Space "SPACE")
    (#\: "COLON")
    (#\Tab "TAB")
    (#\Return "ENTER")
    (#\Backspace "BACKSPACE")
    (#\Esc "ESCAPE")
    (otherwise (string-upcase (string char)))))

(defun canonicalize-key (char &key ctrl alt shift)
  "Return a stable keyword for CHAR and its modifier flags.

Modifiers use the conventional C-/M-/S- prefixes, in that order.  For
example, Control+Alt+Shift+A becomes :C-M-S-A."
  (check-type char character)
  (let ((parts (append (when ctrl '("C"))
                       (when alt '("M"))
                       (when shift '("S"))
                       (list (%character-key-name char)))))
    (intern (format nil "~{~A~^-~}" parts) :keyword)))
