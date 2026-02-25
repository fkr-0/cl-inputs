(uiop:define-package :cl-inputs.adapters
  (:use :cl)
  (:import-from :cl-inputs.tokens
                #:input-token-kind
                #:input-token-data)
  (:import-from :cl-inputs.terminal.ansii
                #:normalize-key-symbol
                #:%token-char)
  (:export #:token->normalized-event))

(in-package :cl-inputs.adapters)

(defun token->normalized-event (token)
  "Convert a cl-inputs token into a normalized event plist.
Returns NIL when TOKEN kind is unsupported."
  (let* ((kind (input-token-kind token))
         (data (input-token-data token)))
    (case kind
      (:key
       (let* ((code (getf data :code))
              (mods (copy-list (getf data :mods)))
              (char (or (%token-char code) (getf data :char)))
              (key (normalize-key-symbol code))
              (etype (or (getf data :type) :key-down))
              (code-value (cond ((integerp code) code)
                                ((characterp char) (char-code char))
                                (t nil))))
         (list :type :key-event
               :event-type etype
               :key key
               :char char
               :code code-value
               :modifiers mods)))
      (:mouse
       (list :type :mouse-event
             :event-type (getf data :type)
             :button (getf data :button)
             :x (getf data :x)
             :y (getf data :y)
             :modifiers (copy-list (getf data :mods))))
      (:resize
       (let ((width (getf data :width))
             (height (getf data :height)))
         (when (and width height)
           (list :type :terminal-resized
                 :width width
                 :height height))))
      (t nil))))
