(in-package :cl-inputs.keymap)

(defparameter *default-keymap*
  ;; minimal examples; extend with your full table
  `((,(mapcar #'char-code '(#\Esc #\[ #\A)) :up)
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
    (,(mapcar #'char-code '(#\Esc #\[ #\2 #\4 #\~)) :f12)))

(defun lookup-seq (octets &optional (table *default-keymap*))
  (let ((match (find (coerce octets 'list) table
                     :key #'first
                     :test #'equal)))
    (and match (second match))))

(defun canonicalize-key (char &key ctrl alt shift)
  "Turn raw char + modifiers into a canonical key symbol/plist."
  (declare (ignore alt shift))
  (cond
    ((and ctrl (<= (char-code char) 31))
     (intern (format nil "C-~A" (code-char (+ 64 (char-code char)))) :keyword))
    (t (intern (string-upcase (string char)) :keyword))))
