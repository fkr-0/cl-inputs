;;;; cl-inputs.protocol.lisp
;;;
;;; Bounded, incremental recognition of terminal protocol bytes.

(uiop:define-package :cl-inputs.protocol
  (:use :cl :alexandria)
  (:import-from :cl-inputs.escape #:csi-final-byte-p)
  (:export
   #:+default-escape-timeout+
   #:+default-max-sequence-bytes+
   #:+default-max-paste-bytes+
   #:+default-max-buffer-bytes+
   #:make-protocol-parser
   #:protocol-parser-state
   #:protocol-next-deadline
   #:protocol-buffered-byte-count
   #:recognize-chunk
   #:finish-protocol
   #:decode-utf-8-octets
   #:protocol-event
   #:protocol-event-category
   #:protocol-event-payload
   #:protocol-event-raw
   #:protocol-event-reason
   #:protocol-event-metadata))

(in-package :cl-inputs.protocol)

(defun %monotonic-seconds ()
  (/ (coerce (get-internal-real-time) 'double-float)
     (coerce internal-time-units-per-second 'double-float)))

(defparameter +default-escape-timeout+ 0.025d0)
(defparameter +default-max-sequence-bytes+ 128)
(defparameter +default-max-paste-bytes+ (* 1024 1024))
(defparameter +default-max-buffer-bytes+ (+ +default-max-paste-bytes+ 128))
(defparameter +escape-byte+ 27)
(defparameter +csi-byte+ 91)
(defparameter +ss3-byte+ 79)
(defparameter +paste-open+
  (make-array 6 :element-type '(unsigned-byte 8)
                :initial-contents '(27 91 50 48 48 126)))
(defparameter +paste-close+
  (make-array 6 :element-type '(unsigned-byte 8)
                :initial-contents '(27 91 50 48 49 126)))

(defstruct protocol-event
  category
  payload
  raw
  reason
  metadata)

(defstruct (protocol-parser (:constructor %make-protocol-parser))
  (mode :ground)
  (sequence-buffer (make-array 0 :element-type '(unsigned-byte 8)))
  (utf8-buffer (make-array 0 :element-type '(unsigned-byte 8)))
  (utf8-expected 0 :type fixnum)
  (utf8-alt-p nil :type boolean)
  (paste-buffer (make-array 0 :element-type '(unsigned-byte 8)))
  (paste-discard-tail (make-array 0 :element-type '(unsigned-byte 8)))
  string-control-type
  escape-deadline
  (clock #'%monotonic-seconds :type function)
  (escape-timeout +default-escape-timeout+ :type real)
  (max-sequence-bytes +default-max-sequence-bytes+ :type (integer 3 *))
  (max-paste-bytes +default-max-paste-bytes+ :type (integer 0 *))
  (max-buffer-bytes +default-max-buffer-bytes+ :type (integer 6 *)))

(defun %buffer-from-sequence (sequence)
  (let* ((count (length sequence))
         (buffer (make-array count :element-type '(unsigned-byte 8)
                                   :adjustable t :fill-pointer count)))
    (replace buffer sequence)
    buffer))

(defun %empty-octets ()
  (%buffer-from-sequence '()))

(defun %octets (&rest bytes)
  (%buffer-from-sequence bytes))

(defun %freeze-octets (octets)
  (let ((result (make-array (length octets) :element-type '(unsigned-byte 8))))
    (replace result octets)
    result))

(defun %append-byte (octets byte)
  (let ((buffer (if (and (adjustable-array-p octets)
                         (array-has-fill-pointer-p octets))
                    octets
                    (%buffer-from-sequence octets))))
    (vector-push-extend byte buffer)
    buffer))

(defun %tail (octets count)
  (%buffer-from-sequence
   (subseq octets (max 0 (- (length octets) count)))))

(defun %same-octets-p (left right)
  (and (= (length left) (length right))
       (loop for index below (length left)
             always (= (aref left index) (aref right index)))))

(defun %ends-with-p (octets suffix)
  (let ((offset (- (length octets) (length suffix))))
    (and (not (minusp offset))
         (loop for index below (length suffix)
               always (= (aref octets (+ offset index))
                         (aref suffix index))))))

(defun %validate-limits (escape-timeout max-sequence-bytes max-paste-bytes max-buffer-bytes)
  (unless (and (realp escape-timeout) (not (minusp escape-timeout)))
    (error "ESCAPE-TIMEOUT must be a non-negative real, got ~S" escape-timeout))
  (unless (and (integerp max-sequence-bytes) (>= max-sequence-bytes 3))
    (error "MAX-SEQUENCE-BYTES must be at least 3, got ~S" max-sequence-bytes))
  (unless (and (integerp max-paste-bytes) (not (minusp max-paste-bytes)))
    (error "MAX-PASTE-BYTES must be non-negative, got ~S" max-paste-bytes))
  (unless (and (integerp max-buffer-bytes)
               (>= max-buffer-bytes max-sequence-bytes)
               (>= max-buffer-bytes (+ max-paste-bytes (length +paste-close+))))
    (error "MAX-BUFFER-BYTES ~S is smaller than a configured retained-state bound."
           max-buffer-bytes))
  t)

(defun make-protocol-parser (&key
                               (clock #'%monotonic-seconds)
                               (escape-timeout +default-escape-timeout+)
                               (max-sequence-bytes +default-max-sequence-bytes+)
                               (max-paste-bytes +default-max-paste-bytes+)
                               (max-buffer-bytes +default-max-buffer-bytes+))
  "Create a bounded incremental terminal-protocol recognizer.

CLOCK returns monotonic seconds. ESCAPE-TIMEOUT resolves only standalone Escape
ambiguity; the parser never sleeps. Sequence, paste, and aggregate retained
state are constrained by explicit hard limits."
  (check-type clock function)
  (%validate-limits escape-timeout max-sequence-bytes max-paste-bytes max-buffer-bytes)
  (%make-protocol-parser :clock clock
                         :escape-timeout escape-timeout
                         :max-sequence-bytes max-sequence-bytes
                         :max-paste-bytes max-paste-bytes
                         :max-buffer-bytes max-buffer-bytes))

(defun %copy-parser (parser)
  (let ((copy (copy-protocol-parser parser)))
    (setf (protocol-parser-sequence-buffer copy)
          (%buffer-from-sequence (protocol-parser-sequence-buffer parser))
          (protocol-parser-utf8-buffer copy)
          (%buffer-from-sequence (protocol-parser-utf8-buffer parser))
          (protocol-parser-paste-buffer copy)
          (%buffer-from-sequence (protocol-parser-paste-buffer parser))
          (protocol-parser-paste-discard-tail copy)
          (%buffer-from-sequence (protocol-parser-paste-discard-tail parser)))
    copy))

(defun protocol-buffered-byte-count (parser)
  (+ (length (protocol-parser-sequence-buffer parser))
     (length (protocol-parser-utf8-buffer parser))
     (length (protocol-parser-paste-buffer parser))
     (length (protocol-parser-paste-discard-tail parser))))

(defun protocol-next-deadline (parser)
  (and (eq (protocol-parser-mode parser) :escape)
       (protocol-parser-escape-deadline parser)))

(defun protocol-parser-state (parser)
  "Return a diagnostic snapshot with copies of retained protocol bytes only."
  (list :mode (protocol-parser-mode parser)
        :sequence-buffer (%freeze-octets (protocol-parser-sequence-buffer parser))
        :utf8-buffer (%freeze-octets (protocol-parser-utf8-buffer parser))
        :paste (if (member (protocol-parser-mode parser) '(:paste :paste-discarding))
                   :on :off)
        :paste-buffered-byte-count (length (protocol-parser-paste-buffer parser))
        :string-control-type (protocol-parser-string-control-type parser)
        :buffered-byte-count (protocol-buffered-byte-count parser)
        :escape-deadline (protocol-next-deadline parser)
        :escape-timeout (protocol-parser-escape-timeout parser)
        :max-sequence-bytes (protocol-parser-max-sequence-bytes parser)
        :max-paste-bytes (protocol-parser-max-paste-bytes parser)
        :max-buffer-bytes (protocol-parser-max-buffer-bytes parser)))

(defun %reset-ground (parser)
  (setf (protocol-parser-mode parser) :ground
        (protocol-parser-sequence-buffer parser) (%empty-octets)
        (protocol-parser-utf8-buffer parser) (%empty-octets)
        (protocol-parser-utf8-expected parser) 0
        (protocol-parser-utf8-alt-p parser) nil
        (protocol-parser-paste-buffer parser) (%empty-octets)
        (protocol-parser-paste-discard-tail parser) (%empty-octets)
        (protocol-parser-string-control-type parser) nil
        (protocol-parser-escape-deadline parser) nil)
  parser)

(defun %start-escape (parser now)
  (setf (protocol-parser-mode parser) :escape
        (protocol-parser-sequence-buffer parser) (%octets +escape-byte+)
        (protocol-parser-escape-deadline parser)
        (+ now (protocol-parser-escape-timeout parser)))
  parser)

(defun %string-control-type-for-byte (byte)
  (case byte
    (93 :osc)
    (80 :dcs)
    (88 :sos)
    (94 :pm)
    (95 :apc)
    (otherwise nil)))

(defun %start-string-control (parser byte)
  (setf (protocol-parser-mode parser) :control-string
        (protocol-parser-sequence-buffer parser) (%octets +escape-byte+ byte)
        (protocol-parser-string-control-type parser) (%string-control-type-for-byte byte)
        (protocol-parser-escape-deadline parser) nil)
  parser)

(defun %control-string-overflow (parser emit)
  (%emit-overflow emit :sequence-too-long
                  :metadata (list :sequence-type
                                  (protocol-parser-string-control-type parser)
                                  :limit (protocol-parser-max-sequence-bytes parser)))
  (setf (protocol-parser-sequence-buffer parser) (%empty-octets)
        (protocol-parser-mode parser) :control-string-discarding))

(defun %append-control-string-byte (parser byte emit)
  (if (>= (length (protocol-parser-sequence-buffer parser))
          (protocol-parser-max-sequence-bytes parser))
      (progn
        (%control-string-overflow parser emit)
        nil)
      (progn
        (setf (protocol-parser-sequence-buffer parser)
              (%append-byte (protocol-parser-sequence-buffer parser) byte))
        t)))

(defun %emit-control-string (parser emit terminator)
  (funcall emit
           (make-protocol-event
            :category :control-string
            :metadata (list :sequence-type (protocol-parser-string-control-type parser)
                            :byte-count (length (protocol-parser-sequence-buffer parser))
                            :terminator terminator)))
  (%reset-ground parser))

(defun %utf8-lead-length (byte)
  (cond
    ((<= #xC2 byte #xDF) 2)
    ((<= #xE0 byte #xEF) 3)
    ((<= #xF0 byte #xF4) 4)
    (t nil)))

(defun %continuation-byte-p (byte)
  (<= #x80 byte #xBF))

(defun %decode-one-utf8 (octets)
  "Decode one complete UTF-8 scalar. Return character, validity, and reason."
  (let ((count (length octets)))
    (labels ((continuation-p (index)
               (and (< index count)
                    (%continuation-byte-p (aref octets index)))))
      (cond
        ((and (= count 1) (< (aref octets 0) #x80))
         (values (code-char (aref octets 0)) t nil))
        ((and (= count 2)
              (<= #xC2 (aref octets 0) #xDF)
              (continuation-p 1))
         (values (code-char
                  (logior (ash (logand (aref octets 0) #x1F) 6)
                          (logand (aref octets 1) #x3F)))
                 t nil))
        ((and (= count 3)
              (<= #xE0 (aref octets 0) #xEF)
              (continuation-p 1)
              (continuation-p 2)
              (or (/= (aref octets 0) #xE0) (>= (aref octets 1) #xA0))
              (or (/= (aref octets 0) #xED) (<= (aref octets 1) #x9F)))
         (let* ((codepoint
                  (logior (ash (logand (aref octets 0) #x0F) 12)
                          (ash (logand (aref octets 1) #x3F) 6)
                          (logand (aref octets 2) #x3F)))
                (character (code-char codepoint)))
           (if character
               (values character t nil)
               (values nil nil :unsupported-codepoint))))
        ((and (= count 4)
              (<= #xF0 (aref octets 0) #xF4)
              (continuation-p 1)
              (continuation-p 2)
              (continuation-p 3)
              (or (/= (aref octets 0) #xF0) (>= (aref octets 1) #x90))
              (or (/= (aref octets 0) #xF4) (<= (aref octets 1) #x8F)))
         (let* ((codepoint
                  (logior (ash (logand (aref octets 0) #x07) 18)
                          (ash (logand (aref octets 1) #x3F) 12)
                          (ash (logand (aref octets 2) #x3F) 6)
                          (logand (aref octets 3) #x3F)))
                (character (and (<= codepoint #x10FFFF) (code-char codepoint))))
           (if character
               (values character t nil)
               (values nil nil :unsupported-codepoint))))
        (t
         (values nil nil :invalid-utf8))))))

(defun decode-utf-8-octets (octets &key (replacement (code-char #xFFFD)))
  "Decode OCTETS, replacing malformed bytes deterministically.
Return string, validity, and number of replacement events."
  (declare (type (simple-array (unsigned-byte 8) (*)) octets))
  (let ((output (make-array 0 :element-type 'character
                              :adjustable t :fill-pointer 0))
        (errors 0)
        (position 0))
    (loop while (< position (length octets)) do
      (let* ((first (aref octets position))
             (expected (if (< first #x80) 1 (%utf8-lead-length first))))
        (cond
          ((or (null expected)
               (> (+ position expected) (length octets)))
           (vector-push-extend replacement output)
           (incf errors)
           (incf position))
          (t
           (multiple-value-bind (character validp reason)
               (%decode-one-utf8 (subseq octets position (+ position expected)))
             (declare (ignore reason))
             (if validp
                 (progn
                   (vector-push-extend character output)
                   (incf position expected))
                 (progn
                   (vector-push-extend replacement output)
                   (incf errors)
                   (incf position))))))))
    (values (coerce output 'string) (zerop errors) errors)))

(defun %emit-malformed (emit reason &key raw metadata)
  (funcall emit
           (make-protocol-event :category :malformed
                                :raw (and raw (%freeze-octets raw))
                                :reason reason
                                :metadata metadata)))

(defun %emit-overflow (emit reason &key raw metadata)
  (funcall emit
           (make-protocol-event :category :overflow
                                :raw (and raw (%freeze-octets raw))
                                :reason reason
                                :metadata metadata)))

(defun %expire-escape-if-due (parser now emit)
  (when (and (eq (protocol-parser-mode parser) :escape)
             (protocol-parser-escape-deadline parser)
             (>= now (protocol-parser-escape-deadline parser)))
    (funcall emit
             (make-protocol-event :category :escape
                                  :raw (%octets +escape-byte+)
                                  :reason :ambiguity-deadline))
    (%reset-ground parser)))

(defun %start-utf8 (parser byte alt-p)
  (setf (protocol-parser-mode parser) :utf8
        (protocol-parser-utf8-buffer parser) (%octets byte)
        (protocol-parser-utf8-expected parser) (%utf8-lead-length byte)
        (protocol-parser-utf8-alt-p parser) alt-p
        (protocol-parser-escape-deadline parser) nil)
  parser)

(defun %emit-ascii (emit byte &key alt-p)
  (let* ((control-p (or (< byte 32) (= byte 127)))
         (category (cond
                     ((and alt-p control-p) :alt-control)
                     (alt-p :alt-text)
                     (control-p :control)
                     (t :text)))
         (raw (and control-p
                   (if alt-p
                       (%octets +escape-byte+ byte)
                       (%octets byte)))))
    (funcall emit
             (make-protocol-event :category category
                                  :payload (code-char byte)
                                  :raw raw
                                  :metadata (list :encoding :ascii
                                                  :byte-count (if alt-p 2 1))))))

(defun %sequence-overflow (parser emit sequence-type current-byte)
  (%emit-overflow emit :sequence-too-long
                  :raw (protocol-parser-sequence-buffer parser)
                  :metadata (list :sequence-type sequence-type
                                  :limit (protocol-parser-max-sequence-bytes parser)))
  (setf (protocol-parser-sequence-buffer parser) (%empty-octets)
        (protocol-parser-escape-deadline parser) nil)
  (if (csi-final-byte-p current-byte)
      (%reset-ground parser)
      (setf (protocol-parser-mode parser) :sequence-discarding)))

(defun %feed-byte (parser byte now emit)
  (labels ((process-byte (current)
             (case (protocol-parser-mode parser)
               (:ground
                (cond
                  ((= current +escape-byte+)
                   (%start-escape parser now))
                  ((< current #x80)
                   (%emit-ascii emit current))
                  ((%utf8-lead-length current)
                   (%start-utf8 parser current nil))
                  (t
                   (%emit-malformed emit :invalid-utf8-leading-byte
                                    :metadata (list :byte-count 1)))))
               (:escape
                (cond
                  ((= current +escape-byte+)
                   (funcall emit
                            (make-protocol-event :category :escape
                                                 :raw (%octets +escape-byte+)
                                                 :reason :followed-by-escape))
                   (%start-escape parser now))
                  ((= current +csi-byte+)
                   (setf (protocol-parser-mode parser) :csi
                         (protocol-parser-sequence-buffer parser)
                         (%octets +escape-byte+ +csi-byte+)
                         (protocol-parser-escape-deadline parser) nil))
                  ((= current +ss3-byte+)
                   (setf (protocol-parser-mode parser) :ss3
                         (protocol-parser-sequence-buffer parser)
                         (%octets +escape-byte+ +ss3-byte+)
                         (protocol-parser-escape-deadline parser) nil))
                  ((%string-control-type-for-byte current)
                   (%start-string-control parser current))
                  ((< current #x80)
                   (%emit-ascii emit current :alt-p t)
                   (%reset-ground parser))
                  ((%utf8-lead-length current)
                   (%start-utf8 parser current t))
                  (t
                   (%emit-malformed emit :invalid-alt-utf8-leading-byte
                                    :metadata (list :byte-count 2 :alt t))
                   (%reset-ground parser))))
               (:utf8
                (cond
                  ((not (%continuation-byte-p current))
                   (%emit-malformed emit :invalid-utf8-continuation
                                    :metadata
                                    (list :byte-count
                                          (length (protocol-parser-utf8-buffer parser))
                                          :alt (protocol-parser-utf8-alt-p parser)))
                   (%reset-ground parser)
                   (process-byte current))
                  (t
                   (setf (protocol-parser-utf8-buffer parser)
                         (%append-byte (protocol-parser-utf8-buffer parser) current))
                   (when (= (length (protocol-parser-utf8-buffer parser))
                            (protocol-parser-utf8-expected parser))
                     (let ((octets (protocol-parser-utf8-buffer parser))
                           (alt-p (protocol-parser-utf8-alt-p parser)))
                       (multiple-value-bind (character validp reason)
                           (%decode-one-utf8 octets)
                         (if validp
                             (funcall emit
                                      (make-protocol-event
                                       :category (if alt-p :alt-text :text)
                                       :payload character
                                       :metadata (list :encoding :utf-8
                                                       :byte-count
                                                       (+ (length octets)
                                                          (if alt-p 1 0)))))
                             (%emit-malformed emit reason
                                              :metadata
                                              (list :byte-count (length octets)
                                                    :alt alt-p))))
                       (%reset-ground parser))))))
               ((:csi :ss3)
                (let ((sequence-type (protocol-parser-mode parser)))
                  (cond
                    ((= current +escape-byte+)
                     (%emit-malformed emit :interrupted-sequence
                                      :raw (protocol-parser-sequence-buffer parser)
                                      :metadata (list :sequence-type sequence-type))
                     (%reset-ground parser)
                     (%start-escape parser now))
                    ((> (1+ (length (protocol-parser-sequence-buffer parser)))
                        (protocol-parser-max-sequence-bytes parser))
                     (%sequence-overflow parser emit sequence-type current))
                    (t
                     (setf (protocol-parser-sequence-buffer parser)
                           (%append-byte (protocol-parser-sequence-buffer parser) current))
                     (when (csi-final-byte-p current)
                       (let ((raw (protocol-parser-sequence-buffer parser)))
                         (if (and (eq sequence-type :csi)
                                  (%same-octets-p raw +paste-open+))
                             (setf (protocol-parser-mode parser) :paste
                                   (protocol-parser-sequence-buffer parser) (%empty-octets)
                                   (protocol-parser-paste-buffer parser) (%empty-octets))
                             (progn
                               (funcall emit
                                        (make-protocol-event :category sequence-type
                                                             :raw (%freeze-octets raw)))
                               (%reset-ground parser)))))))))
               (:control-string
                (cond
                  ((and (eq (protocol-parser-string-control-type parser) :osc)
                        (= current 7))
                   (if (%append-control-string-byte parser current emit)
                       (%emit-control-string parser emit :bel)
                       (%reset-ground parser)))
                  ((= current +escape-byte+)
                   (when (%append-control-string-byte parser current emit)
                     (setf (protocol-parser-mode parser) :control-string-escape)))
                  (t
                   (%append-control-string-byte parser current emit))))
               (:control-string-escape
                (cond
                  ((= current 92)
                   (if (%append-control-string-byte parser current emit)
                       (%emit-control-string parser emit :st)
                       (%reset-ground parser)))
                  ((= current +escape-byte+)
                   (%append-control-string-byte parser current emit))
                  (t
                   (when (%append-control-string-byte parser current emit)
                     (setf (protocol-parser-mode parser) :control-string)))))
               (:control-string-discarding
                (cond
                  ((and (eq (protocol-parser-string-control-type parser) :osc)
                        (= current 7))
                   (%reset-ground parser))
                  ((= current +escape-byte+)
                   (setf (protocol-parser-mode parser) :control-string-discard-escape))))
               (:control-string-discard-escape
                (cond
                  ((= current 92)
                   (%reset-ground parser))
                  ((= current +escape-byte+)
                   nil)
                  (t
                   (setf (protocol-parser-mode parser) :control-string-discarding))))
               (:sequence-discarding
                (cond
                  ((= current +escape-byte+)
                   (%reset-ground parser)
                   (%start-escape parser now))
                  ((csi-final-byte-p current)
                   (%reset-ground parser))))
               (:paste
                (setf (protocol-parser-paste-buffer parser)
                      (%append-byte (protocol-parser-paste-buffer parser) current))
                (cond
                  ((%ends-with-p (protocol-parser-paste-buffer parser) +paste-close+)
                   (let* ((buffer (protocol-parser-paste-buffer parser))
                          (payload-count (- (length buffer) (length +paste-close+))))
                     (if (> payload-count (protocol-parser-max-paste-bytes parser))
                         (%emit-overflow emit :paste-too-long
                                         :metadata
                                         (list :limit (protocol-parser-max-paste-bytes parser)
                                               :minimum-byte-count payload-count))
                         (funcall emit
                                  (make-protocol-event
                                   :category :paste
                                   :payload (subseq buffer 0 payload-count)
                                   :metadata (list :byte-count payload-count))))
                     (%reset-ground parser)))
                  ((> (length (protocol-parser-paste-buffer parser))
                      (+ (protocol-parser-max-paste-bytes parser)
                         (1- (length +paste-close+))))
                   (let ((buffered (length (protocol-parser-paste-buffer parser))))
                     (%emit-overflow
                      emit :paste-too-long
                      :metadata
                      (list :limit (protocol-parser-max-paste-bytes parser)
                            :minimum-byte-count
                            (- buffered (1- (length +paste-close+)))))
                     (setf (protocol-parser-mode parser) :paste-discarding
                           (protocol-parser-paste-discard-tail parser)
                           (%tail (protocol-parser-paste-buffer parser)
                                  (1- (length +paste-close+)))
                           (protocol-parser-paste-buffer parser) (%empty-octets))))))
               (:paste-discarding
                (let ((tail (%append-byte (protocol-parser-paste-discard-tail parser)
                                          current)))
                  (setf (protocol-parser-paste-discard-tail parser)
                        (%tail tail (length +paste-close+)))
                  (when (%ends-with-p (protocol-parser-paste-discard-tail parser)
                                      +paste-close+)
                    (%reset-ground parser))))
               (otherwise
                (error "Unknown protocol parser mode ~S" (protocol-parser-mode parser))))))
    (process-byte byte)))

(defun recognize-chunk (parser octet-vector &key now)
  "Consume OCTET-VECTOR, returning raw events and a fresh parser state.

NOW is a monotonic timestamp in seconds. If omitted, the injected parser clock
is called once. Retained parser state is copied so the supplied PARSER remains
unchanged."
  (declare (type (simple-array (unsigned-byte 8) (*)) octet-vector))
  (let* ((next (%copy-parser parser))
         (step-now (if now now (funcall (protocol-parser-clock next))))
         (events '()))
    (labels ((emit (event) (push event events)))
      ;; Evaluate an already-pending ambiguity deadline at step entry only.
      ;; A new ESC observed in this same chunk must remain pending until the
      ;; caller supplies a subsequent monotonic time, even for a zero timeout;
      ;; otherwise chunk boundaries themselves would change semantics.
      (%expire-escape-if-due next step-now #'emit)
      (loop for byte across octet-vector do
        (%feed-byte next byte step-now #'emit)))
    (assert (<= (protocol-buffered-byte-count next)
                (protocol-parser-max-buffer-bytes next)))
    (values (nreverse events) next)))

(defun finish-protocol (parser)
  "Finish a byte stream and convert retained incomplete input to typed events."
  (let ((next (%copy-parser parser))
        (events '()))
    (labels ((emit (event) (push event events)))
      (case (protocol-parser-mode next)
        (:ground nil)
        (:escape
         (emit (make-protocol-event :category :escape
                                    :raw (%octets +escape-byte+)
                                    :reason :end-of-stream)))
        (:utf8
         (%emit-malformed #'emit :truncated-utf8
                          :metadata
                          (list :byte-count (length (protocol-parser-utf8-buffer next))
                                :alt (protocol-parser-utf8-alt-p next))))
        ((:csi :ss3)
         (%emit-malformed #'emit :truncated-sequence
                          :raw (protocol-parser-sequence-buffer next)
                          :metadata (list :sequence-type (protocol-parser-mode next))))
        ((:control-string :control-string-escape)
         (%emit-malformed #'emit :truncated-control-string
                          :metadata
                          (list :sequence-type (protocol-parser-string-control-type next)
                                :buffered-byte-count
                                (length (protocol-parser-sequence-buffer next)))))
        ((:sequence-discarding :control-string-discarding
          :control-string-discard-escape)
         nil)
        (:paste
         (%emit-malformed #'emit :truncated-paste
                          :metadata
                          (list :buffered-byte-count
                                (length (protocol-parser-paste-buffer next)))))
        (:paste-discarding nil)
        (otherwise
         (%emit-malformed #'emit :unknown-parser-state
                          :metadata (list :mode (protocol-parser-mode next)))))
      (%reset-ground next))
    (values (nreverse events) next)))
