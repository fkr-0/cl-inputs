(uiop:define-package :cl-inputs.tests.decoder
  (:use :cl :fiveam)
  (:import-from :cl-inputs.decoder
    #:make-decoder #:decoder-state #:decode-chunk #:finish-decoder
    #:decoder-next-deadline #:decoder-buffered-byte-count)
  (:import-from :cl-inputs.tokens #:input-token-kind #:input-token-data)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:export #:decoder-tests))

(in-package :cl-inputs.tests.decoder)

(def-suite decoder-tests
  :description "Tests for cl-inputs.decoder module"
  :in :cl-inputs)

(in-suite decoder-tests)

(defun escape-bytes (suffix)
  (string-to-utf-8-bytes
   (concatenate 'string (string #\Esc) suffix)))

(test make-decoder-default
  "Test creating a default decoder"
  (let* ((dec (make-decoder))
         (state (decoder-state dec)))
    (is (eq :ground (getf state :mode)))
    (is (eq :off (getf state :paste)))
    (is (zerop (decoder-buffered-byte-count dec)))
    (is (null (decoder-next-deadline dec)))))

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
          (bytes (escape-bytes "[A"))
          (tokens (nth-value 0 (decode-chunk dec bytes))))
    (is (= 1 (length tokens)))
    (is (eq :up (getf (input-token-data (first tokens)) :code)))))

(test utf8-is-incremental-and-semantic
  (let* ((bytes (string-to-utf-8-bytes (string (code-char #x03BB))))
         (decoder (make-decoder)))
    (multiple-value-bind (first-tokens pending)
        (decode-chunk decoder (subseq bytes 0 1) :timestamp 7 :now 0d0)
      (is (null first-tokens))
      (multiple-value-bind (tokens done)
          (decode-chunk pending (subseq bytes 1) :timestamp 7 :now 0d0)
        (is (= 1 (length tokens)))
        (is (char= (code-char #x03BB)
                   (getf (input-token-data (first tokens)) :code)))
        (is (eq :ground (getf (decoder-state done) :mode)))))))

(test ss3-focus-mouse-and-bracketed-paste
  (let ((f1 (nth-value 0 (decode-chunk (make-decoder) (escape-bytes "OP") :now 0d0)))
        (focus-in (nth-value 0 (decode-chunk (make-decoder) (escape-bytes "[I") :now 0d0)))
        (focus-out (nth-value 0 (decode-chunk (make-decoder) (escape-bytes "[O") :now 0d0)))
        (mouse (nth-value 0 (decode-chunk (make-decoder) (escape-bytes "[<0;3;4M") :now 0d0)))
        (paste (nth-value 0
                 (decode-chunk
                  (make-decoder)
                  (string-to-utf-8-bytes
                   (concatenate 'string (string #\Esc) "[200~paste"
                                (string #\Esc) "[201~"))
                  :now 0d0))))
    (is (eq :f1 (getf (input-token-data (first f1)) :code)))
    (is (eq :focus (input-token-kind (first focus-in))))
    (is-true (getf (input-token-data (first focus-in)) :gained))
    (is-false (getf (input-token-data (first focus-out)) :gained))
    (is (eq :mouse (input-token-kind (first mouse))))
    (is (= 2 (getf (input-token-data (first mouse)) :x)))
    (is (= 3 (getf (input-token-data (first mouse)) :y)))
    (is (eq :paste (input-token-kind (first paste))))
    (is (equal "paste" (getf (input-token-data (first paste)) :content)))
    (is (null (getf (input-token-data (first paste)) :raw)))))

(test escape-deadline-is-explicit-and-injectable
  (multiple-value-bind (tokens pending)
      (decode-chunk (make-decoder :escape-timeout 0.05d0)
                    (make-array 1 :element-type '(unsigned-byte 8)
                                  :initial-contents '(27))
                    :timestamp 9 :now 10d0)
    (is (null tokens))
    (is (= 10.05d0 (decoder-next-deadline pending)))
    (let ((expired (nth-value 0
                     (decode-chunk pending
                                   (make-array 0 :element-type '(unsigned-byte 8))
                                   :timestamp 9 :now 10.05d0))))
      (is (= 1 (length expired)))
      (is (eq :escape (getf (input-token-data (first expired)) :code)))
      (is (eq :ambiguity-deadline
              (getf (getf (input-token-data (first expired)) :protocol) :reason))))))

(test terminal-cursor-report-is-not-user-input
  (let ((tokens (nth-value 0
                  (decode-chunk
                   (make-decoder)
                   (string-to-utf-8-bytes
                    (concatenate 'string (string #\Esc) "[12;34R"))
                   :now 0d0))))
    (is (= 1 (length tokens)))
    (is (eq :terminal-response (input-token-kind (first tokens))))
    (is (eq :cursor-position
            (getf (input-token-data (first tokens)) :response-type)))
    (is (= 12 (getf (input-token-data (first tokens)) :row)))
    (is (= 34 (getf (input-token-data (first tokens)) :column)))))

(test device-attributes-capability-replies-are-typed
  (dolist (case '(("[?1;2c" :primary-device-attributes (1 2))
                  ("[>0;95;0c" :secondary-device-attributes (0 95 0))))
    (destructuring-bind (suffix expected attributes) case
      (let ((token (first (nth-value 0
                           (decode-chunk
                            (make-decoder)
                            (string-to-utf-8-bytes
                             (concatenate 'string (string #\Esc) suffix))
                            :now 0d0)))))
        (is (eq :terminal-response (input-token-kind token)))
        (is (eq expected (getf (input-token-data token) :response-type)))
        (is (equal attributes (getf (input-token-data token) :attributes)))))))

(test malformed-cursor-report-recovers-without-stealing-following-key
  (let ((tokens (nth-value 0
                  (decode-chunk
                   (make-decoder)
                   (string-to-utf-8-bytes
                    (concatenate 'string (string #\Esc) "[12;Rz"))
                   :now 0d0))))
    (is (= 2 (length tokens)))
    (is (eq :protocol (input-token-kind (first tokens))))
    (is (eq :key (input-token-kind (second tokens))))
    (is (char= #\z (getf (input-token-data (second tokens)) :code)))))

(test unknown-csi-is-protocol-not-user-key
  (let ((tokens (nth-value 0
                  (decode-chunk (make-decoder)
                                (string-to-utf-8-bytes
                                 (concatenate 'string (string #\Esc) "[?999zx"))
                                :now 0d0))))
    (is (= 2 (length tokens)))
    (is (eq :protocol (input-token-kind (first tokens))))
    (is (eq :unknown-sequence (getf (input-token-data (first tokens)) :category)))
    (is (eq :key (input-token-kind (second tokens))))
    (is (char= #\x (getf (input-token-data (second tokens)) :code)))))

(test unsupported-string-control-is-protocol-not-user-text
  (let ((tokens (nth-value 0
                  (decode-chunk
                   (make-decoder)
                   (make-array 11 :element-type '(unsigned-byte 8)
                                  :initial-contents
                                  '(27 93 48 59 116 105 116 108 101 7 120))
                   :now 0d0))))
    (is (= 2 (length tokens)))
    (is (eq :protocol (input-token-kind (first tokens))))
    (is (eq :unknown-sequence (getf (input-token-data (first tokens)) :category)))
    (is (eq :unsupported-control-string
            (getf (input-token-data (first tokens)) :reason)))
    (is (null (getf (input-token-data (first tokens)) :raw)))
    (is (char= #\x (getf (input-token-data (second tokens)) :code)))))

(test malformed-utf8-is-typed-and-recovers
  (let ((tokens (nth-value 0
                  (decode-chunk (make-decoder)
                                (make-array 3 :element-type '(unsigned-byte 8)
                                              :initial-contents (list #xC2 65 66))
                                :now 0d0))))
    (is (equal '(:protocol :key :key) (mapcar #'input-token-kind tokens)))
    (is (eq :invalid-utf8-continuation
            (getf (input-token-data (first tokens)) :reason)))
    (is (char= #\A (getf (input-token-data (second tokens)) :code)))
    (is (char= #\B (getf (input-token-data (third tokens)) :code)))))

(test oversized-paste-is-typed-without-content-provenance
  (let* ((decoder (make-decoder :max-sequence-bytes 16
                                :max-paste-bytes 3
                                :max-buffer-bytes 32))
         (bytes (string-to-utf-8-bytes
                 (concatenate 'string (string #\Esc) "[200~secret"
                              (string #\Esc) "[201~x")))
         (tokens (nth-value 0 (decode-chunk decoder bytes :now 0d0))))
    (is (= 2 (length tokens)))
    (is (eq :protocol (input-token-kind (first tokens))))
    (is (eq :paste-too-long (getf (input-token-data (first tokens)) :reason)))
    (is (null (getf (input-token-data (first tokens)) :raw)))
    (is (eq :key (input-token-kind (second tokens))))
    (is (char= #\x (getf (input-token-data (second tokens)) :code)))))

(test finish-decoder-reports-truncation-and-resets
  (multiple-value-bind (tokens pending)
      (decode-chunk (make-decoder)
                    (make-array 2 :element-type '(unsigned-byte 8)
                                  :initial-contents (list #xE2 #x82))
                    :timestamp 11 :now 0d0)
    (is (null tokens))
    (multiple-value-bind (final reset)
        (finish-decoder pending :timestamp 11)
      (is (= 1 (length final)))
      (is (eq :protocol (input-token-kind (first final))))
      (is (eq :truncated-utf8 (getf (input-token-data (first final)) :reason)))
      (is (eq :ground (getf (decoder-state reset) :mode)))
      (is (zerop (decoder-buffered-byte-count reset))))))

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
          (tokens (nth-value 0 (decode-chunk dec bytes :now 0d0)))
          (new-dec (nth-value 1 (decode-chunk dec bytes :now 0d0))))
    (is (null tokens))
    (is (eq :csi (getf (decoder-state new-dec) :mode)))
    (is (= 2 (decoder-buffered-byte-count new-dec)))))

(test decode-state-preservation
  "Test that decoder state is preserved across calls"
  (let* ((dec (make-decoder))
          ;; First call sends ESC without the rest
          (bytes1 (make-array 1 :element-type '(unsigned-byte 8)
                               :initial-contents (list 27)))
          (new-dec (nth-value 1 (decode-chunk dec bytes1)))
          ;; Second call completes the sequence
          (bytes2 (string-to-utf-8-bytes "[A"))
          (tokens (nth-value 0 (decode-chunk new-dec bytes2))))
    (is (= 1 (length tokens)))
    (is (eq :up (getf (input-token-data (first tokens)) :code)))))
