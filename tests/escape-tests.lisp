(uiop:define-package :cl-inputs.tests.escape
  (:use :cl :fiveam)
  (:import-from :cl-inputs.escape
                #:csi-final-byte-p #:decode-csi-to-token)
  (:export #:escape-tests))

(in-package :cl-inputs.tests.escape)

(def-suite escape-tests
  :description "Tests for cl-inputs.escape module"
  :in :cl-inputs)

(in-suite escape-tests)

(test csi-final-byte-p-valid
  "Test CSI final byte detection for valid bytes"
  ;; CSI final bytes are 0x40-0x7E (@ through ~)
  (is-true (csi-final-byte-p 64))   ;; @
  (is-true (csi-final-byte-p 65))   ;; A
  (is-true (csi-final-byte-p 90))   ;; Z
  (is-true (csi-final-byte-p 126))  ;; ~
  )

(test csi-final-byte-p-invalid
  "Test CSI final byte detection for invalid bytes"
  (is-false (csi-final-byte-p 63))  ;; ?
  (is-false (csi-final-byte-p 127)) ;; DEL
  (is-false (csi-final-byte-p 0))   ;; NUL
  )

(test decode-csi-to-token-default
  "Test that decode-csi-to-token returns NIL by default"
  (let* ((bytes (string-to-utf-8-bytes "^[A"))
          (result (decode-csi-to-token bytes)))
    (is (null result))))
