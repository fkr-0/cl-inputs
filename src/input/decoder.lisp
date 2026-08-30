;;;; cl-inputs.decoder.lisp
;;;
;;; Semantic terminal-input decoder built on the bounded raw protocol recognizer.

(uiop:define-package :cl-inputs.decoder
  (:use :cl :alexandria :cl-inputs.tokens)
  (:import-from :cl-inputs.keymap #:lookup-seq)
  (:import-from :cl-inputs.escape #:decode-csi-to-token)
  (:import-from :cl-inputs.protocol
    #:make-protocol-parser #:protocol-parser-state #:protocol-next-deadline
    #:protocol-buffered-byte-count #:recognize-chunk #:finish-protocol
    #:decode-utf-8-octets #:protocol-event-category #:protocol-event-payload
    #:protocol-event-raw #:protocol-event-reason #:protocol-event-metadata)
  (:export
    #:make-decoder #:decoder-state #:decode-chunk #:finish-decoder
    #:decoder-next-deadline #:decoder-buffered-byte-count))

(in-package :cl-inputs.decoder)

(defstruct (decoder (:constructor %make-decoder (parser)))
  parser)

(defun make-decoder (&key clock
                          (escape-timeout cl-inputs.protocol:+default-escape-timeout+)
                          (max-sequence-bytes cl-inputs.protocol:+default-max-sequence-bytes+)
                          (max-paste-bytes cl-inputs.protocol:+default-max-paste-bytes+)
                          (max-buffer-bytes cl-inputs.protocol:+default-max-buffer-bytes+))
  "Create a semantic decoder with explicit raw-protocol bounds and ESC policy."
  (let ((arguments (list :escape-timeout escape-timeout
                         :max-sequence-bytes max-sequence-bytes
                         :max-paste-bytes max-paste-bytes
                         :max-buffer-bytes max-buffer-bytes)))
    (when clock
      (setf arguments (list* :clock clock arguments)))
    (%make-decoder (apply #'make-protocol-parser arguments))))

(defun decoder-state (decoder)
  "Return a diagnostic snapshot of DECODER's raw parser state."
  (protocol-parser-state (decoder-parser decoder)))

(defun decoder-next-deadline (decoder)
  "Return the pending ESC ambiguity deadline in monotonic seconds, or NIL."
  (protocol-next-deadline (decoder-parser decoder)))

(defun decoder-buffered-byte-count (decoder)
  "Return the number of bytes retained across decode calls."
  (protocol-buffered-byte-count (decoder-parser decoder)))

(defun %protocol-provenance (category raw reason metadata)
  (append (list :category category)
          (when reason (list :reason reason))
          (when raw (list :raw (copy-seq raw)))
          (when metadata (list :metadata (copy-list metadata)))))

(defun %key-token (code timestamp &key mods protocol)
  (make-token +k-key+
              (append (list :code code :mods mods)
                      (when protocol (list :protocol protocol)))
              timestamp))

(defun %protocol-token (category timestamp &key raw reason metadata)
  (make-token +k-protocol+
              (%protocol-provenance category raw reason metadata)
              timestamp))

(defun %terminal-response-token (response-type timestamp raw &rest data)
  (make-token +k-terminal-response+
              (append (list :response-type response-type)
                      data
                      (list :protocol (%protocol-provenance :csi raw nil nil)))
              timestamp))

(defun %same-octets-p (octets values)
  (and (= (length octets) (length values))
       (loop for index below (length values)
             always (= (aref octets index) (nth index values)))))

(defun %parse-decimal-fields (raw start end)
  (handler-case
      (let* ((string (map 'string #'code-char (subseq raw start end)))
             (parts (uiop:split-string string :separator (list (code-char 59)))))
        (when (and parts
                   (every (lambda (part)
                            (and (plusp (length part))
                                 (every #'digit-char-p part)))
                          parts))
          (mapcar #'parse-integer parts)))
    (error () nil)))

(defun %csi-terminal-response-token (raw timestamp)
  "Recognize bounded CSI replies that are terminal protocol responses, not keys."
  (when (and (>= (length raw) 3)
             (= (aref raw 0) 27)
             (= (aref raw 1) 91))
    (let* ((final (aref raw (1- (length raw))))
           (body-start 2)
           (body-end (1- (length raw))))
      (cond
        ;; Cursor Position Report (CPR): CSI row ; column R.
        ((= final (char-code #\R))
         (let ((fields (%parse-decimal-fields raw body-start body-end)))
           (when (and (= (length fields) 2)
                      (every #'plusp fields))
             (%terminal-response-token
              :cursor-position timestamp raw
              :row (first fields) :column (second fields)))))
        ;; Device Status Report (DSR): CSI status n.
        ((= final (char-code #\n))
         (let ((fields (%parse-decimal-fields raw body-start body-end)))
           (when (= (length fields) 1)
             (%terminal-response-token
              :device-status timestamp raw :status (first fields)))))
        ;; Primary/secondary Device Attributes (DA) capability replies.
        ((= final (char-code #\c))
         (when (< body-start body-end)
           (let* ((prefix (aref raw body-start))
                  (variant (cond ((= prefix (char-code #\?)) :primary-device-attributes)
                                 ((= prefix (char-code #\>)) :secondary-device-attributes)
                                 (t nil)))
                  (fields (and variant
                               (%parse-decimal-fields raw (1+ body-start) body-end))))
             (when (and variant fields)
               (%terminal-response-token
                variant timestamp raw :attributes fields)))))
        (t nil)))))

(defun %sgr-mouse-token (raw timestamp)
  (when (and (>= (length raw) 7)
             (= (aref raw 0) 27)
             (= (aref raw 1) 91)
             (= (aref raw 2) 60)
             (member (aref raw (1- (length raw))) '(77 109)))
    (let ((params (%parse-decimal-fields raw 3 (1- (length raw)))))
      (when (= (length params) 3)
        (destructuring-bind (cb column row) params
          (when (and (plusp column) (plusp row))
            (let* ((final (aref raw (1- (length raw))))
                   (event-type (cond
                                 ((= final 109) :mouse-up)
                                 ((logbitp 6 cb) :mouse-wheel)
                                 ((logbitp 5 cb) :mouse-move)
                                 (t :mouse-down)))
                   (mods (append (when (logbitp 2 cb) '(:shift))
                                 (when (logbitp 3 cb) '(:alt))
                                 (when (logbitp 4 cb) '(:control))))
                   (button (logand cb 3)))
              (make-token +k-mouse+
                          (list :type event-type
                                :x (1- column)
                                :y (1- row)
                                :button button
                                :mods mods
                                :protocol (%protocol-provenance :csi raw nil nil))
                          timestamp))))))))

(defun %control-sequence-tokens (event timestamp)
  (let* ((category (protocol-event-category event))
         (raw (protocol-event-raw event))
         (provenance (%protocol-provenance category raw nil
                                           (protocol-event-metadata event)))
         (response (and (eq category :csi)
                        (%csi-terminal-response-token raw timestamp)))
         (mouse (and (eq category :csi) (%sgr-mouse-token raw timestamp))))
    (cond
      (response
       (list response))
      ((and (eq category :csi) (%same-octets-p raw '(27 91 73)))
       (list (make-token +k-focus+ (list :gained t :protocol provenance) timestamp)))
      ((and (eq category :csi) (%same-octets-p raw '(27 91 79)))
       (list (make-token +k-focus+ (list :gained nil :protocol provenance) timestamp)))
      (mouse
       (list mouse))
      (t
       (let ((custom (and (eq category :csi) (decode-csi-to-token raw)))
             (mapped (lookup-seq raw)))
         (cond
           (custom (list custom))
           (mapped (list (%key-token mapped timestamp :protocol provenance)))
           (t (list (%protocol-token :unknown-sequence timestamp
                                     :raw raw
                                     :metadata (list :sequence-type category))))))))))

(defun %raw-event-tokens (event timestamp)
  (let ((category (protocol-event-category event))
        (payload (protocol-event-payload event))
        (raw (protocol-event-raw event))
        (reason (protocol-event-reason event))
        (metadata (protocol-event-metadata event)))
    (case category
      (:text
       (list (%key-token payload timestamp)))
      (:control
       (let ((mapped (lookup-seq (make-array 1
                                             :element-type '(unsigned-byte 8)
                                             :initial-contents
                                             (list (char-code payload))))))
         (list (%key-token (or mapped payload) timestamp
                           :protocol (%protocol-provenance :control raw nil metadata)))))
      (:escape
       (list (%key-token :escape timestamp
                         :protocol (%protocol-provenance :escape raw reason metadata))))
      (:alt-text
       (list (%key-token payload timestamp :mods '(:alt))))
      (:alt-control
       (let ((byte (char-code payload)))
         (list (%key-token
                (or (lookup-seq (make-array 1
                                            :element-type '(unsigned-byte 8)
                                            :initial-contents (list byte)))
                    payload)
                timestamp :mods '(:alt)
                :protocol (%protocol-provenance :alt-control raw nil metadata)))))
      ((:csi :ss3)
       (%control-sequence-tokens event timestamp))
      (:control-string
       (list (%protocol-token :unknown-sequence timestamp
                              :reason :unsupported-control-string
                              :metadata metadata)))
      (:paste
       (multiple-value-bind (content validp replacement-count)
           (decode-utf-8-octets payload)
         (append
          (unless validp
            (list (%protocol-token :malformed timestamp
                                   :reason :invalid-paste-utf8
                                   :metadata (list :replacement-count replacement-count
                                                   :byte-count (length payload)))))
          (list (make-token +k-paste+
                            (list :content content
                                  :byte-count (length payload)
                                  :encoding :utf-8
                                  :valid-utf8-p validp)
                            timestamp)))))
      ((:malformed :overflow)
       (list (%protocol-token category timestamp
                             :raw raw :reason reason :metadata metadata)))
      (otherwise
       (list (%protocol-token :unknown-event timestamp
                             :reason :unrecognized-raw-category
                             :metadata (list :raw-category category)))))))

(defun %events-to-tokens (events timestamp)
  (loop for event in events append (%raw-event-tokens event timestamp)))

(defun decode-chunk (decoder octet-vector
                     &key (timestamp (get-universal-time)) now)
  "Incrementally decode OCTET-VECTOR into semantic input tokens.

Chunk boundaries do not change semantic output. NOW, when supplied, is monotonic
seconds used only for externally controlled ambiguity-deadline evaluation."
  (declare (type (simple-array (unsigned-byte 8) (*)) octet-vector))
  (multiple-value-bind (events parser)
      (if now
          (recognize-chunk (decoder-parser decoder) octet-vector :now now)
          (recognize-chunk (decoder-parser decoder) octet-vector))
    (values (%events-to-tokens events timestamp)
            (%make-decoder parser))))

(defun finish-decoder (decoder &key (timestamp (get-universal-time)))
  "Finish DECODER at end-of-stream and return final tokens plus reset state."
  (multiple-value-bind (events parser)
      (finish-protocol (decoder-parser decoder))
    (values (%events-to-tokens events timestamp)
            (%make-decoder parser))))
