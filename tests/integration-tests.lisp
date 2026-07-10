(uiop:define-package :cl-inputs.tests.integration
  (:use :cl :fiveam)
  (:import-from :cl-inputs.api #:make-ready-input-source)
  (:import-from :cl-inputs.loop #:next-token #:close-input-source)
  (:import-from :cl-inputs.device.api #:make-device)
  (:import-from :cl-inputs.decoder #:make-decoder)
  (:import-from :cl-inputs.tokens #:input-token-kind)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:export #:integration-tests))

(in-package :cl-inputs.tests.integration)

(def-suite integration-tests
  :description "Integration tests for cl-inputs"
  :in :cl-inputs)

(in-suite integration-tests)

(defun escape-bytes (suffix)
  (string-to-utf-8-bytes
   (concatenate 'string (string #\Esc) suffix)))

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
        (bytes (escape-bytes "[C"))) ;; Right arrow
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
  (let* ((device (make-device :faketerm
                              :script (list (string-to-utf-8-bytes "X"))))
         (source (make-ready-input-source :device device)))
    (unwind-protect
         (is (eq #\X
                 (getf (cl-inputs.tokens:input-token-data (next-token source))
                       :code)))
      (is-true (close-input-source source)))))
