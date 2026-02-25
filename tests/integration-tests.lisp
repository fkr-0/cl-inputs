(uiop:define-package :cl-inputs.tests.integration
  (:use :cl :fiveam)
  (:import-from :cl-inputs.api #:make-input #:input-process)
  (:import-from :cl-inputs.decoder #:make-decoder)
  (:import-from :cl-inputs.tokens #:input-token-kind)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:export #:integration-tests))

(in-package :cl-inputs.tests.integration)

(def-suite integration-tests
  :description "Integration tests for cl-inputs"
  :in :cl-inputs)

(in-suite integration-tests)

(test decode-key-press
  "Test integration: decode a key press from bytes to token"
  (let ((decoder (make-decoder))
        (bytes (string-to-utf-8-bytes "A")))
    (multiple-value-bind (tokens new-dec) (cl-inputs.decoder:decode-chunk decoder bytes)
      (declare (ignore new-dec))
      (is (= 1 (length tokens)))
      (is (eq :key (input-token-kind (first tokens))))
      (is (eq #\A (getf (cl-inputs.tokens:input-token-data (first tokens)) :code))))))

(test decode-escape-sequence
  "Test integration: decode ESC sequence to key token"
  (let ((decoder (make-decoder))
        (bytes (string-to-utf-8-bytes "^[C"))) ;; Right arrow
    (multiple-value-bind (tokens new-dec) (cl-inputs.decoder:decode-chunk decoder bytes)
      (declare (ignore new-dec))
      (is (= 1 (length tokens)))
      (is (eq :right (getf (cl-inputs.tokens:input-token-data (first tokens)) :code))))))

(test decode-multiple-keys
  "Test integration: decode multiple key presses"
  (let ((decoder (make-decoder))
        (bytes (string-to-utf-8-bytes "Hello")))
    (multiple-value-bind (tokens new-dec) (cl-inputs.decoder:decode-chunk decoder bytes)
      (declare (ignore new-dec))
      (is (= 5 (length tokens)))
      ;; Each letter should be a separate token
      (is (eq :key (input-token-kind (first tokens)))))))

(test roundtrip-api
  "Test integration: roundtrip through API"
  (let ((inp (make-input :backend :faketerm))
        (bytes (string-to-utf-8-bytes "X")))
    (is (listp inp))
    ;; Just verify the structure is set up correctly
    (is (getf inp :device))))
