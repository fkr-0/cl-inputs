;;;; cl-inputs.escape.lisp
;;;
;;; Utilities for handling ECMA-48 CSI/ESC sequences and mapping them to tokens.
;;; Extend this module to support additional escape sequence decoding.
(uiop:define-package :cl-inputs.escape
  (:use :cl :alexandria :log4cl)
  (:import-from :cl-inputs.keymap #:lookup-seq)
  (:import-from :cl-inputs.tokens #:input-token-kind)
  (:export #:csi-final-byte-p
    #:decode-csi-to-token))  ;; stub hook you can extend
;; == cl-inputs/src/escape.lisp ==
(in-package :cl-inputs.escape)

(defun csi-final-byte-p (byte)
  "Return T if BYTE is an ECMA-48 final byte (0x40..0x7E), NIL otherwise."
  (<= #x40 byte #x7E))

(defun decode-csi-to-token (octets)
  "Attempt to map a full CSI/ESC sequence (OCTETS) to a token.
Return NIL to let the generic path try SGR mouse or fallback handling.
Override this function to provide custom escape sequence decoding."
  (declare (type (simple-array (unsigned-byte 8) (*)) octets)
           (ignore octets))
  ;; Deliberately no raw-sequence logging here. Protocol diagnostics retain
  ;; bounded control-sequence provenance without exposing user/paste text.
  nil)
;; == end/escape.lisp ==
