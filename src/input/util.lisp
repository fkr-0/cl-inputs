;;;; cl-inputs.util.lisp
;;;
;;; Utility functions and macros for cl-inputs.
;;; Provides UTF-8 encoding helpers for string and character conversion.

(uiop:define-package :cl-inputs.util
  (:use :cl :alexandria)
  (:export #:as-utf-8-bytes
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
  "Convert STR to a sequence of UTF-8 bytes.

Arguments:
  STR -- a string to encode (type: string)

Return Value:
  A vector of (unsigned-byte 8) containing the UTF-8 encoding of STR.

Side Effects:
  None."
  (let ((result (make-array (length str) :element-type '(unsigned-byte 8))))
    (loop for i from 0 below (length str)
      do (as-utf-8-bytes (char str i)
           (lambda (byte) (setf (aref result i) byte))))
    result))
