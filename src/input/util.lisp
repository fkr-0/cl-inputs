;;;; cl-inputs.util.lisp
;;;
;;; Utility functions and macros for cl-inputs.
;;; Provides UTF-8 encoding helpers for string and character conversion.

(uiop:define-package :cl-inputs.util
  (:use :cl :alexandria)
  (:export #:as-utf-8-bytes #:write-output
    #:string-to-utf-8-bytes))

(in-package :cl-inputs.util)

(defmacro as-utf-8-bytes (char writer)
  "Call WRITER for every byte in the UTF-8 encoding of CHAR.

Arguments:
  CHAR   -- a character to encode (type: character)
  WRITER -- a function or macro accepting a single byte (type: (function (unsigned-byte) *))

Side Effects:
  Calls WRITER for each byte of the UTF-8 encoding of CHAR. WRITER may have side effects.

Return Value:
  None (macro expands to a series of WRITER calls)."
  (let ((char-code (gensym)))
    `(let ((,char-code (char-code ,char)))
       (declare (type fixnum ,char-code))
       (cond ((< ,char-code 128) (,writer ,char-code))
         ((< ,char-code 2048)
           (,writer (logior #b11000000 (ldb (byte 5 6) ,char-code)))
           (,writer (logior #b10000000 (ldb (byte 6 0) ,char-code))))
         ((< ,char-code 65536)
           (,writer (logior #b11100000 (ldb (byte 4 12) ,char-code)))
           (,writer (logior #b10000000 (ldb (byte 6 6) ,char-code)))
           (,writer (logior #b10000000 (ldb (byte 6 0) ,char-code))))
         (t
           (,writer (logior #b11110000 (ldb (byte 3 18) ,char-code)))
           (,writer (logior #b10000000 (ldb (byte 6 12) ,char-code)))
           (,writer (logior #b10000000 (ldb (byte 6 6) ,char-code)))
           (,writer (logior #b10000000 (ldb (byte 6 0) ,char-code))))))))

(defun string-to-utf-8-bytes (str)
  "Convert STR to a freshly allocated (unsigned-byte 8) vector holding its UTF-8 bytes.

Arguments:
  STR -- a string to encode (type: string)

Return Value:
  A vector of (unsigned-byte 8) containing the UTF-8 encoding of STR. The vector
  is adjustable with a fill pointer so callers can re-use it if desired.

Side Effects:
  None."
  (let ((buffer (make-array 0 :element-type '(unsigned-byte 8)
                  :adjustable t :fill-pointer 0)))
    (loop for ch across str do
      (as-utf-8-bytes ch
        (lambda (byte)
          (vector-push-extend byte buffer))))
    (let* ((len (length buffer))
            (result (make-array len :element-type '(unsigned-byte 8))))
      (replace result buffer)
      result)))

(defun write-output (output stream)
  "Write output to the terminal
This method should be implemented by subclasses of low-level-terminal."
  ;; (declare (ignore style))
  ;; ;; (with-lock (term)
  ;; (exec-sequence term :cursor-set-position y x)
  (dotimes (i (length output))
    (as-utf-8-bytes (char output i) (lambda (x) (write-byte x stream)))))
