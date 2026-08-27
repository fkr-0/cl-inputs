;;;; cl-inputs.decoder.lisp
;;;
;;; Byte-stream decoder for terminal input. Decoder state retains incomplete
;;; escape sequences between chunks; DECODE-CHUNK returns tokens plus the next
;;; decoder state without mutating the caller-provided state.

(uiop:define-package :cl-inputs.decoder
  (:use :cl :alexandria :cl-inputs.tokens :cl-inputs.keymap :cl-inputs.escape)
  (:import-from #:log4cl #:log-info #:log-debug #:log-warn #:log-error)
  (:export #:make-decoder #:decoder-state #:decode-chunk))
(in-package :cl-inputs.decoder)

;;; State: keep a growable byte buffer for partial sequences; keep paste-mode if you need it later.
(defun make-decoder (&key (buf (make-array 0 :element-type '(unsigned-byte 8)
                                 :adjustable t :fill-pointer 0))
                      (paste-mode :off))
  (list :buf buf :paste paste-mode))

(defun decoder-state (dec) dec)

(defun %emit-key (code ts &optional mods)
  ;; NOTE: upstream token constructor assumed.
  (cl-inputs.tokens:make-token cl-inputs.tokens:+k-key+ `(:code ,code :mods ,mods) ts))

(defun %u8v (&rest bytes)
  (coerce (apply #'vector bytes) '(simple-array (unsigned-byte 8) (*))))

(defun %concat-u8 (a b)
  (let* ((na (length a)) (nb (length b))
          (out (make-array (+ na nb) :element-type '(unsigned-byte 8))))
    (replace out a :start1 0 :start2 0 :end2 na)
    (replace out b :start1 na :start2 0 :end2 nb)
    out))

(defun %lookup-1 (byte)
  "Single-byte lookup via your keymap (returns NIL if unknown)."
  (cl-inputs.keymap:lookup-seq (%u8v byte)))

(defun %parse-csi-params (bytes start end-excl)
  "Parse decimal parameters separated by ';' or '<' in BYTES[start,end)."
  (let* ((s (map 'string #'code-char (subseq bytes start end-excl)))
          (parts (uiop:split-string s :separator '(#\; #\<))))
    (remove nil (mapcar (lambda (str) (parse-integer str :junk-allowed t)) parts))))

(defun %parse-csi-mouse (params final-byte timestamp)
  ;; SGR 1006 mode: <cb;x;y>M or m
  (let* ((press (char-code #\M))
          (release (char-code #\m))
          (etype (cond ((= final-byte press) :mouse-down)
                   ((= final-byte release) :mouse-up)
                   (t :mouse-move)))
          (cb (or (first params) 0))
          (cx (or (second params) 1))
          (cy (or (third  params) 1))
          (button (logand cb 3))
          (mods   (let ((m (ash cb -2)))
                    (append (when (logbitp 0 m) '(:shift))
                      (when (logbitp 1 m) '(:alt))
                      (when (logbitp 2 m) '(:control))))))
    (when (and (integerp cx) (integerp cy) (plusp cx) (plusp cy))
      (cl-inputs.tokens:make-token
        :mouse `(:type ,etype :x ,(1- cx) :y ,(1- cy) :button ,button :mods ,mods) timestamp))))

(defun decode-chunk (decoder octet-vector &key (timestamp (get-universal-time)))
  "Pure step: consume OCTET-VECTOR (u8 vector), produce (values TOKENS NEW-DECODER).
   Incomplete escape sequences are preserved in the decoder buffer."
  (declare (type (simple-array (unsigned-byte 8) (*)) octet-vector))
  (let* ((old-buf (getf decoder :buf))
          ;; concat preserves existing incomplete sequence
          (bytes   (%concat-u8 old-buf octet-vector))
          (len     (length bytes))
          (pos     0)
          (tokens  '()))
    (labels
      ((remaining () (- len pos))
        (cur () (when (< pos len) (aref bytes pos)))
        (peek (n) (and (<= n (remaining)) (subseq bytes pos (+ pos n))))
        (advance (&optional (n 1)) (incf pos n))
        (emit (tok) (when tok (push tok tokens)))
        ;; CSI scan: returns (values end-index final-byte) or NIL if incomplete
        (scan-csi ()
          ;; after ESC [ we are at pos pointing to ESC; next is '['
          (let* ((start (+ pos 2))
                  (end   (position-if #'cl-inputs.escape:csi-final-byte-p bytes
                           :start start)))
            (when end
              (values end (aref bytes end)))))
        (handle-esc ()
          ;; ESC dispatch: CSI, ALT+char, or lone ESC (kept as :escape key)
          (let ((two (peek 2)))
            (cond
              ;; Incomplete ESC (only ESC available) → buffer it
              ((not two) (return-from handle-esc :incomplete))

              ;; CSI: ESC [
              ((= (aref two 1) (char-code #\[))
                (multiple-value-bind (end final) (scan-csi)
                  (if end
                    (progn
                      ;; include ESC..final (end inclusive)
                      (let* ((seq  (subseq bytes pos (1+ end)))
                              (mapped (cl-inputs.escape:decode-csi-to-token seq)))
                        (cond
                          ;; user-provided full mapping wins
                          (mapped
                            (emit mapped)
                            (setf pos (1+ end)))
                          ;; SGR 1006 mouse: ESC [ < params final
                          ((and (find (char-code #\<) seq)
                             (member final (list (char-code #\M) (char-code #\m))))
                            (let* ((params (%parse-csi-params bytes (+ pos 2) end)))
                              (emit (%parse-csi-mouse params final timestamp))
                              (setf pos (1+ end))))
                          ;; Otherwise: try keymap table with full seq; if unknown, drop gracefully.
                          (t
                            (let ((key (cl-inputs.keymap:lookup-seq seq)))
                              (if key
                                (progn (emit (%emit-key key timestamp)) (setf pos (1+ end)))
                                ;; Fallback: emit the ESC literally, advance by 1 to avoid stalling
                                (emit (%emit-key :escape timestamp)))
                              (advance 1)))))
                      :done)
                    ;; incomplete CSI: keep in buffer
                    :incomplete)))

              ;; ALT+char: ESC <byte> where the second byte is not '['.
              (t
                ;; consume ESC+char → emit ALT char
                (let ((ch (aref two 1)))
                  (emit (%emit-key (code-char ch) timestamp '(:alt)))
                  (advance 2))
                :done)))))
      (loop
        (when (>= pos len) (return))
        (let ((b (cur)))
          ;; Single-byte direct mapping first (fast path)
          (let ((key (cl-inputs.keymap:lookup-seq (%u8v b))))
            (cond
              (key (emit (%emit-key key timestamp)) (advance 1))
              ((= b 27) ; ESC
                (let ((r (handle-esc)))
                  (when (eq r :incomplete) (return))))
              (t
                ;; ordinary byte → emit as key (ASCII path)
                (emit (%emit-key (code-char b) timestamp))
                (advance 1)))))))

    ;; any leftovers are incomplete → keep in new state
    (values (nreverse tokens)
      (make-decoder :buf (if (< pos len) (subseq bytes pos) (%u8v))
        :paste-mode (getf decoder :paste)))))

;;; Decoder invariants: incomplete ESC/CSI sequences remain buffered, ALT consumes
;;; ESC plus one byte, and all stream operations stay on unsigned-byte octets.
