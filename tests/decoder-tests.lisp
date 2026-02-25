(uiop:define-package :cl-inputs.tests.decoder
  (:use :cl :fiveam)
  (:import-from :cl-inputs.decoder #:make-decoder #:decode-chunk)
  (:import-from :cl-inputs.tokens #:input-token-kind #:input-token-data)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:export #:decoder-tests))

(in-package :cl-inputs.tests.decoder)

(def-suite decoder-tests
  :description "Tests for cl-inputs.decoder module"
  :in :cl-inputs)

(in-suite decoder-tests)

(test make-decoder-default
  "Test creating a default decoder"
  (let ((dec (make-decoder)))
    (is (listp dec))
    (is (getf dec :buf))
    (is (eq :off (getf dec :paste)))))

(test decode-single-char
  "Test decoding a single character"
  (let* ((dec (make-decoder))
          (bytes (string-to-utf-8-bytes "X"))
          (tokens (nth-value 0 (decode-chunk dec bytes))))
    (is (= 1 (length tokens)))
    (is (eq :key (input-token-kind (first tokens))))
    (is (eq #\X (getf (input-token-data (first tokens)) :code)))))

(test decode-multiple-chars
  "Test decoding multiple characters at once"
  (let* ((dec (make-decoder))
          (bytes (string-to-utf-8-bytes "ABC"))
          (tokens (nth-value 0 (decode-chunk dec bytes))))
    (is (= 3 (length tokens)))
    (is (eq #\A (getf (input-token-data (first tokens)) :code)))
    (is (eq #\B (getf (input-token-data (second tokens)) :code)))
    (is (eq #\C (getf (input-token-data (third tokens)) :code)))))

(test decode-esc-sequence
  "Test decoding ESC [ A (up arrow)"
  (let* ((dec (make-decoder))
          (bytes (string-to-utf-8-bytes "^[A"))
          (tokens (nth-value 0 (decode-chunk dec bytes))))
    (is (= 1 (length tokens)))
    (is (eq :up (getf (input-token-data (first tokens)) :code)))))

(test decode-tab-key
  "Test decoding Tab key"
  (let* ((dec (make-decoder))
          (bytes (string-to-utf-8-bytes (string #\Tab)))
          (tokens (nth-value 0 (decode-chunk dec bytes))))
    (is (= 1 (length tokens)))
    (is (eq :tab (getf (input-token-data (first tokens)) :code)))))

(test decode-backspace
  "Test decoding Backspace"
  (let* ((dec (make-decoder))
          (bytes (string-to-utf-8-bytes (string #\Backspace)))
          (tokens (nth-value 0 (decode-chunk dec bytes))))
    (is (= 1 (length tokens)))
    (is (eq :backspace (getf (input-token-data (first tokens)) :code)))))

(test decode-incomplete-esc
  "Test that incomplete ESC sequences are buffered"
  (let* ((dec (make-decoder))
          (bytes (make-array 2 :element-type '(unsigned-byte 8)
                              :initial-contents (list 27 91))) ;; ESC [
          (tokens (nth-value 0 (decode-chunk dec bytes)))
          (new-dec (nth-value 1 (decode-chunk dec bytes))))
    (is (null tokens)) ;; No tokens from incomplete sequence
    (is (plusp (length (getf new-dec :buf)))))) ;; Buffer has leftovers

(test decode-state-preservation
  "Test that decoder state is preserved across calls"
  (let* ((dec (make-decoder))
          ;; First call sends ESC without the rest
          (bytes1 (make-array 1 :element-type '(unsigned-byte 8)
                               :initial-contents (list 27)))
          (_ (decode-chunk dec bytes1))
          (new-dec (nth-value 1 (decode-chunk dec bytes1)))
          ;; Second call completes the sequence
          (bytes2 (string-to-utf-8-bytes "[A"))
          (tokens (nth-value 0 (decode-chunk new-dec bytes2))))
    (is (= 1 (length tokens)))
    (is (eq :up (getf (input-token-data (first tokens)) :code)))))
