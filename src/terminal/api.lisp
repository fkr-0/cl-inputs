(uiop:define-package :cl-inputs.terminal.api
  (:use :cl :alexandria)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:import-from :cl-inputs.device.api #:device-write-bytes)
  (:export
    ;; High-level terminal control generics
    #:clear-screen
    #:clear-area
    #:draw-text-at
    #:draw-char-at
    #:fill-rectangle
    #:scroll-lines
    #:get-terminal-size
    #:set-cursor-position
    #:get-cursor-position
    #:hide-cursor
    #:show-cursor
    #:flush-output
    #:apply-style
    #:reset-style
    #:with-styled-output
    ;; Helpers
    #:%emit-ansi
    #:%style->sgr-string
    #:+esc+))

;;;===============================================================\\
;;; ;;; cl-inputs.terminal.api.lisp
;;; ;; Generic terminal API definitions and helpers.
;;; ;; Extend this module to add additional terminal operations.
;;; ;;===============================================================

(in-package :cl-inputs.terminal.api)

(defparameter +esc+ (string (code-char 27))
  "ESC character as a string literal.")

(defun %emit-ansi (target fmt &rest args)
  "Format an ANSI control sequence and write it to TARGET via DEVICE-WRITE-BYTES."
  (let* ((string (apply #'format nil fmt args))
          (bytes (string-to-utf-8-bytes string)))
    (device-write-bytes target bytes 0 (length bytes))))

(defun %style-attribute-code (attr)
  (ecase attr
    (:bold 1)
    (:dim 2)
    (:italic 3)
    (:underline 4)
    (:blink 5)
    (:reverse 7)))

(defun %color-code (color kind)
  (let ((base (ecase kind (:fg 30) (:bg 40))))
    (case color
      (:black base)
      (:red (+ base 1))
      (:green (+ base 2))
      (:yellow (+ base 3))
      (:blue (+ base 4))
      (:magenta (+ base 5))
      (:cyan (+ base 6))
      (:white (+ base 7))
      (:default (if (eq kind :fg) 39 49))
      (t nil))))

(defun %style->sgr-string (style)
  "Return an SGR fragment (without final 'm') for STYLE plist or NIL."
  (when style
    (let ((codes '()))
      (when-let (fg (getf style :fg))
        (when-let (code (%color-code fg :fg))
          (push code codes)))
      (when-let (bg (getf style :bg))
        (when-let (code (%color-code bg :bg))
          (push code codes)))
      (dolist (attr (getf style :attrs))
        (push (%style-attribute-code attr) codes))
      (when codes
        (format nil "~{~d~^;~}" (nreverse codes))))))

(defmacro with-styled-output ((target style) &body body)
  "Emit STYLE before BODY and reset attributes afterwards.

Args
  - ~target~: The output destination (e.g., a stream or buffer).
  - ~style~: A style specification, typically a plist or object that ~%style->sgr-string~ can convert to an ANSI SGR string.
  - ~body~: Forms to execute with the style applied.


*Style Evaluation*: The macro evaluates ~style~ and, if non-nil, converts it to an ANSI SGR string using ~%style->sgr-string~.
*Emit Style*: If a style string is produced, it emits the ANSI code to the ~target~ using ~%emit-ansi~.
*Body Execution*: Executes the ~body~ forms.
*Reset Style*: After the body, emits the ANSI reset code (~[0m~) to the ~target~, ensuring styles do not leak.
*No Style Case*: If ~style~ is nil, simply executes the body with no styling.

Example Usage:
  (with-styled-output (my-terminal '(:fg :red :attrs (:bold :underline)))
    (draw-text-at my-terminal 10 5 \"Hello, World!\") ;; => Draws bold, underlined red text at row 10, column 5.
    "
  (let ((style-var (gensym "STYLE"))
         (sgr-var (gensym "SGR")))
    `(let ((,style-var ,style))
       (if ,style-var
         (let ((,sgr-var (%style->sgr-string ,style-var)))
           (when ,sgr-var
             (%emit-ansi ,target "~a[~am" +esc+ ,sgr-var))
           (unwind-protect
             (progn ,@body)
             (%emit-ansi ,target "~a[0m" +esc+)))
         (progn ,@body)))))

;;; ----------------------------------------------------------------------
;;; Generic operations (default no-ops so backends opt-in)

(defgeneric clear-screen (target)
  (:documentation "Clear the full terminal content and home the cursor."))

(defgeneric clear-area (target row col height width &key style)
  (:documentation "Clear a rectangular region starting at ROW/COL with HEIGHT x WIDTH."))

(defgeneric draw-text-at (target row col text &key style)
  (:documentation "Draw TEXT with optional STYLE at ROW/COL."))

(defgeneric draw-char-at (target row col char &key style)
  (:documentation "Draw CHAR with optional STYLE at ROW/COL."))

(defgeneric fill-rectangle (target row col height width &key char style)
  (:documentation "Fill rectangle with CHAR (defaults to space) using STYLE."))

(defgeneric scroll-lines (target count)
  (:documentation "Scroll the display by COUNT lines (positive = up, negative = down)."))

(defgeneric set-cursor-position (target row col)
  (:documentation "Move cursor to ROW/COL (0-based)."))

(defgeneric get-cursor-position (target)
  (:documentation "Return cursor ROW and COL (0-based) if known, NIL otherwise."))

(defgeneric get-terminal-size (target)
  (:documentation "Return (ROWS . COLS) of the terminal if known, NIL otherwise."))

(defgeneric hide-cursor (target))
(defgeneric show-cursor (target))

(defgeneric flush-output (target)
  (:documentation "Ensure buffered terminal output for TARGET is flushed."))

(defgeneric apply-style (target style)
  (:documentation "Apply STYLE as the current terminal attributes."))

(defgeneric reset-style (target)
  (:documentation "Reset terminal attributes to defaults."))

;;; Default fallbacks (safe no-ops)
(defmethod clear-screen ((target t)) (declare (ignore target)) nil)
(defmethod clear-area ((target t) row col height width &key style)
  (declare (ignore target row col height width style))
  nil)
(defmethod draw-text-at ((target t) row col text &key style)
  (declare (ignore target row col text style))
  nil)
(defmethod draw-char-at ((target t) row col char &key style)
  (declare (ignore target row col char style))
  nil)
(defmethod fill-rectangle ((target t) row col height width &key char style)
  (declare (ignore target row col height width char style))
  nil)
(defmethod scroll-lines ((target t) count)
  (declare (ignore target count)) nil)
(defmethod set-cursor-position ((target t) row col)
  (declare (ignore target row col)) nil)
(defmethod get-cursor-position ((target t)) (values nil nil))
(defmethod hide-cursor ((target t)) (declare (ignore target)) nil)
(defmethod show-cursor ((target t)) (declare (ignore target)) nil)
(defmethod flush-output ((target t)) (declare (ignore target)) nil)
(defmethod apply-style ((target t) style) (declare (ignore target style)) nil)
(defmethod reset-style ((target t)) (declare (ignore target)) nil)
