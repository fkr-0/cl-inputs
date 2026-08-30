(uiop:define-package :cl-inputs.tests.protocol
  (:use :cl :fiveam)
  (:import-from :cl-inputs.protocol
    #:make-protocol-parser #:protocol-parser-state #:protocol-next-deadline
    #:protocol-buffered-byte-count #:recognize-chunk #:finish-protocol
    #:protocol-event-category #:protocol-event-payload #:protocol-event-raw
    #:protocol-event-reason #:protocol-event-metadata)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:export #:protocol-tests))

(in-package :cl-inputs.tests.protocol)

(def-suite protocol-tests
  :description "Bounded incremental terminal protocol recognition"
  :in :cl-inputs)

(in-suite protocol-tests)

(defun u8 (&rest bytes)
  (make-array (length bytes)
              :element-type '(unsigned-byte 8)
              :initial-contents bytes))

(defun concat-octets (&rest vectors)
  (let* ((size (reduce #'+ vectors :key #'length :initial-value 0))
         (result (make-array size :element-type '(unsigned-byte 8)))
         (offset 0))
    (dolist (vector vectors result)
      (replace result vector :start1 offset)
      (incf offset (length vector)))))

(defun event-signature (event)
  (let ((payload (protocol-event-payload event))
        (raw (protocol-event-raw event)))
    (list (protocol-event-category event)
          (if (typep payload '(array (unsigned-byte 8) (*)))
              (coerce payload 'list)
              payload)
          (and raw (coerce raw 'list))
          (protocol-event-reason event)
          (protocol-event-metadata event))))

(defun event-signatures (events)
  (mapcar #'event-signature events))

(defun recognize-pieces (pieces &key (parser (make-protocol-parser)))
  (let ((state parser)
        (events '()))
    (dolist (piece pieces)
      (multiple-value-bind (step-events next-state)
          (recognize-chunk state piece :now 0d0)
        (setf events (nconc events step-events)
              state next-state)))
    (values events state)))

(defun mixed-protocol-stream ()
  (concat-octets
   (u8 120)
   (string-to-utf-8-bytes (string (code-char #x03BB)))
   (u8 27 91 65)
   (u8 27 79 80)
   (u8 27 91 73)
   (u8 27 91 60 48 59 51 59 52 77)
   (u8 27 91 50 48 48 126)
   (string-to-utf-8-bytes (concatenate 'string (string (code-char #x03BB)) "p"))
   (u8 27 91 50 48 49 126)
   ;; Unsupported OSC is still recognized as protocol, not user text.
   (u8 27 93 48 59 116 105 116 108 101 7)
   (u8 121)))

(test arbitrary-split-points-match-whole-stream
  (let* ((bytes (mixed-protocol-stream))
         (whole (nth-value 0 (recognize-pieces (list bytes))))
         (signature (event-signatures whole)))
    (loop for split from 0 to (length bytes) do
      (multiple-value-bind (events state)
          (recognize-pieces (list (subseq bytes 0 split)
                                  (subseq bytes split)))
        (is (equal signature (event-signatures events)))
        (is (eq :ground (getf (protocol-parser-state state) :mode)))))))

(test byte-at-a-time-matches-whole-stream
  (let* ((bytes (mixed-protocol-stream))
         (whole (nth-value 0 (recognize-pieces (list bytes))))
         (pieces (loop for index below (length bytes)
                       collect (subseq bytes index (1+ index)))))
    (is (equal (event-signatures whole)
               (event-signatures (nth-value 0 (recognize-pieces pieces)))))))

(test deterministic-varied-chunking-matches-whole-stream
  (let* ((bytes (mixed-protocol-stream))
         (whole (event-signatures
                 (nth-value 0 (recognize-pieces (list bytes)))))
         (pieces '())
         (position 0)
         (step 1))
    (loop while (< position (length bytes)) do
      (let ((end (min (length bytes) (+ position step))))
        (push (subseq bytes position end) pieces)
        (setf position end
              step (1+ (mod (* step 3) 7)))))
    (is (equal whole
               (event-signatures
                (nth-value 0 (recognize-pieces (nreverse pieces))))))))

(test escape-ambiguity-uses-explicit-deadline
  (let ((parser (make-protocol-parser :escape-timeout 0.05d0)))
    (multiple-value-bind (events pending)
        (recognize-chunk parser (u8 27) :now 10d0)
      (is (null events))
      (is (= 10.05d0 (protocol-next-deadline pending)))
      (is (null (nth-value 0 (recognize-chunk pending (u8) :now 10.049d0))))
      (let ((expired (nth-value 0 (recognize-chunk pending (u8) :now 10.05d0))))
        (is (= 1 (length expired)))
        (is (eq :escape (protocol-event-category (first expired))))
        (is (eq :ambiguity-deadline (protocol-event-reason (first expired))))))))

(test zero-timeout-still-requires-a-subsequent-deadline-step
  (let ((parser (make-protocol-parser :escape-timeout 0d0)))
    (multiple-value-bind (events pending)
        (recognize-chunk parser (u8 27) :now 0d0)
      (is (null events))
      (is (= 0d0 (protocol-next-deadline pending)))
      (let ((expired (nth-value 0
                       (recognize-chunk pending (u8) :now 0d0))))
        (is (= 1 (length expired)))
        (is (eq :escape (protocol-event-category (first expired))))
        (is (eq :ambiguity-deadline
                (protocol-event-reason (first expired))))))))

(test parser-step-does-not-mutate-input-state
  (let ((parser (make-protocol-parser)))
    (multiple-value-bind (events pending)
        (recognize-chunk parser (u8 27) :now 0d0)
      (is (null events))
      (is (eq :ground (getf (protocol-parser-state parser) :mode)))
      (is (eq :escape (getf (protocol-parser-state pending) :mode)))
      (is (zerop (protocol-buffered-byte-count parser)))
      (is (= 1 (protocol-buffered-byte-count pending))))))

(test invalid-utf8-is-typed-and-recovers
  (multiple-value-bind (events state)
      (recognize-pieces (list (u8 #xC2 65 66)))
    (is (equal '(:malformed :text :text)
               (mapcar #'protocol-event-category events)))
    (is (eq :invalid-utf8-continuation
            (protocol-event-reason (first events))))
    (is (char= #\A (protocol-event-payload (second events))))
    (is (char= #\B (protocol-event-payload (third events))))
    (is (zerop (protocol-buffered-byte-count state)))))

(test sequence-overflow-is-bounded-and-recovers
  (let ((parser (make-protocol-parser :max-sequence-bytes 4
                                      :max-paste-bytes 3
                                      :max-buffer-bytes 128)))
    (multiple-value-bind (events state)
        (recognize-pieces (list (u8 27 91 49 50 51 126 120)) :parser parser)
      (is (equal '(:overflow :text)
                 (mapcar #'protocol-event-category events)))
      (is (eq :sequence-too-long (protocol-event-reason (first events))))
      (is (char= #\x (protocol-event-payload (second events))))
      (is (<= (protocol-buffered-byte-count state) 128)))))

(test paste-overflow-never-exposes-paste-content
  (let* ((parser (make-protocol-parser :max-sequence-bytes 16
                                       :max-paste-bytes 3
                                       :max-buffer-bytes 32))
         (bytes (concat-octets (u8 27 91 50 48 48 126)
                               (u8 97 98 99 100 101 102 103 104 105)
                               (u8 27 91 50 48 49 126)
                               (u8 122))))
    (multiple-value-bind (events state)
        (recognize-pieces (list bytes) :parser parser)
      (is (equal '(:overflow :text)
                 (mapcar #'protocol-event-category events)))
      (is (eq :paste-too-long (protocol-event-reason (first events))))
      (is (null (protocol-event-raw (first events))))
      (is (null (protocol-event-payload (first events))))
      (is (char= #\z (protocol-event-payload (second events))))
      (is (<= (protocol-buffered-byte-count state) 32)))))

(test unsupported-control-strings-are-bounded-protocol-events
  (multiple-value-bind (events state)
      (recognize-pieces
       (list (u8 27 93 48 59 116 105 116 108 101 7 120)))
    (is (equal '(:control-string :text)
               (mapcar #'protocol-event-category events)))
    (is (null (protocol-event-raw (first events))))
    (is (eq :osc (getf (protocol-event-metadata (first events)) :sequence-type)))
    (is (eq :bel (getf (protocol-event-metadata (first events)) :terminator)))
    (is (char= #\x (protocol-event-payload (second events))))
    (is (zerop (protocol-buffered-byte-count state)))))

(test oversized-control-string-is-typed-and-recovers
  (let ((parser (make-protocol-parser :max-sequence-bytes 6
                                      :max-paste-bytes 3
                                      :max-buffer-bytes 32)))
    (multiple-value-bind (events state)
        (recognize-pieces (list (u8 27 93 49 50 51 52 53 54 7 120))
                          :parser parser)
      (is (equal '(:overflow :text)
                 (mapcar #'protocol-event-category events)))
      (is (eq :sequence-too-long (protocol-event-reason (first events))))
      (is (null (protocol-event-raw (first events))))
      (is (eq :osc (getf (protocol-event-metadata (first events)) :sequence-type)))
      (is (char= #\x (protocol-event-payload (second events))))
      (is (zerop (protocol-buffered-byte-count state))))))

(test finish-turns-truncation-into-typed-outcome
  (multiple-value-bind (events pending)
      (recognize-chunk (make-protocol-parser) (u8 #xE2 #x82) :now 0d0)
    (is (null events))
    (multiple-value-bind (final reset)
        (finish-protocol pending)
      (is (= 1 (length final)))
      (is (eq :malformed (protocol-event-category (first final))))
      (is (eq :truncated-utf8 (protocol-event-reason (first final))))
      (is (eq :ground (getf (protocol-parser-state reset) :mode))))))

(test finish-reports-truncated-control-sequence
  (multiple-value-bind (events pending)
      (recognize-chunk (make-protocol-parser) (u8 27 91 49 59) :now 0d0)
    (is (null events))
    (let ((final (nth-value 0 (finish-protocol pending))))
      (is (= 1 (length final)))
      (is (eq :truncated-sequence (protocol-event-reason (first final)))))))

(test finish-reports-truncated-control-string-without-content
  (multiple-value-bind (events pending)
      (recognize-chunk (make-protocol-parser)
                       (u8 27 93 115 101 99 114 101 116)
                       :now 0d0)
    (is (null events))
    (let ((final (nth-value 0 (finish-protocol pending))))
      (is (= 1 (length final)))
      (is (eq :truncated-control-string (protocol-event-reason (first final))))
      (is (null (protocol-event-raw (first final))))
      (is (null (protocol-event-payload (first final)))))))

(test finish-reports-truncated-paste-without-content
  (multiple-value-bind (events pending)
      (recognize-chunk (make-protocol-parser)
                       (concat-octets (u8 27 91 50 48 48 126) (u8 115 101 99 114 101 116))
                       :now 0d0)
    (is (null events))
    (let ((final (nth-value 0 (finish-protocol pending))))
      (is (= 1 (length final)))
      (is (eq :truncated-paste (protocol-event-reason (first final))))
      (is (null (protocol-event-raw (first final))))
      (is (null (protocol-event-payload (first final)))))))
