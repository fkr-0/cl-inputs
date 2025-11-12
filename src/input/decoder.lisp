;;;; cl-inputs.decoder.lisp
;;;
;;; Decoder logic for translating raw input bytes into token objects.
;;; This file is currently a reference/stub and not active in production.
;;; See cl-inputs.loop for the main decoding logic.
;;;
;;; Deprecated: This file is retained for reference and future refactoring.
;; (uiop:define-package :cl-inputs.decoder
;;   (:use :cl :alexandria :cl-inputs.tokens :cl-inputs.keymap)
;;   (:import-from #:log4cl #:log-info #:log-debug #:log-warn #:log-error)
;;   (:export
;;     ;; immutable decoder state (can be a plist/struct)
;;     (:import-from #:log4cl #:log-info #:log-debug #:log-warn #:log-error)
;;     (:export
;;       ;; immutable decoder state
;;       #:make-decoder #:decoder-state
;;       ;; functional decoding step
;;       #:decode-chunk)))
;; (in-package :cl-inputs.decoder)

;; ;; You can keep the state as a plist to honor your “no mutable class slots” ethos.
;; (defun make-decoder (&key (buf (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)) (paste-mode :off))
;;   (list :buf buf :paste paste-mode))

;; (defun decoder-state (dec) dec)

;; (defun %emit-key (code ts &optional mods)
;;   (cl-inputs.tokens:make-token cl-inputs.tokens:+k-key+ `(:code ,code :mods ,mods) ts))

;; (defun is-csi-final-byte? (byte)
;;   (and (>= byte 64) (<= byte 126)))

;; (defun parse-csi-mouse (params final-byte)
;;   ;; (format t "PARAMS: ~A, FINAL-BYTE: ~A~%" params final-byte)
;;   (let* ((cb (if (< 2 (length params ))(first params) 0))
;;           (cx (if (< 2 (length params ))(second params) (first params)))
;;           (cy (if (< 2 (length params ))(third params) (second params)))
;;           (press (char-code #\M))
;;           (release (char-code #\m))
;;           (event-type (cond
;;                         ((= final-byte press) :mouse-down)
;;                         ((= final-byte release) :mouse-up)
;;                         (t :mouse-move)))
;;           (button (logand cb 3))
;;           (mods (let ((mod-code (ash cb -2)))
;;                   (append (when (logbitp 0 mod-code) '(:shift))
;;                     (when (logbitp 1 mod-code) '(:alt))
;;                     (when (logbitp 2 mod-code) '(:control))))))
;;     (make-token :mouse `(:type ,event-type :x ,(1- cx) :y ,(1- cy) :button ,button :mods ,mods))))

;; (defun decode-chunk (decoder octet-vector &key (timestamp (get-universal-time)))
;;   "Pure step: consume OCTET-VECTOR, return (values tokens new-decoder).
;;    Keep incomplete escape sequences in decoder’s buffer."
;;   (log-info "Decoding chunk of ~A bytes" (length octet-vector))
;;   (let* ((old-buf (getf decoder :buf))
;;           (bytes (concatenate '(vector (unsigned-byte 8)) old-buf octet-vector))
;;           (pos 0)
;;           (tokens '()))
;;     (labels ((take (n) (prog1 (subseq bytes pos (min (length bytes) (+ pos n))) (incf pos n)))
;;               (remaining () (- (length bytes) pos))
;;               (peek (n) (and (>= (remaining) n) (subseq bytes pos (+ pos n))))
;;               (advance () (incf pos))
;;               (current () (aref bytes pos)))
;;       (loop while (< pos (length bytes)) do
;;         (let* ((byte (current))
;;                 (key (lookup-seq (vector byte))))
;;           (cond
;;             (key
;;               (push (%emit-key key timestamp) tokens)
;;               (advance))
;;             ;; ESC
;;             ((= byte 27)
;;               (let* ((next (peek 2)))
;;                 (format t "ESC at position ~D, next bytes: ~A~%" pos next)
;;                 (cond
;;                   ;; CSI
;;                   ((and next (equal (aref next 1) (char-code #\[)))
;;                     (let* ((end (position-if #'is-csi-final-byte? bytes :start (+ pos 2)))
;;                             (final-byte (when end (aref bytes end))))
;;                       (format t "End ~A Final Byte ~A~%" end final-byte)
;;                       (if (and end final-byte)
;;                         (let* ((seq (subseq bytes pos (+ 1 pos end)))
;;                                 (key (or (lookup-seq seq)
;;                                        ;; (lookup-seq (concatenate 'vector (subseq seq 0 (1- (length seq)))))
;;                                        )))

;;                           (if key
;;                             (progn
;;                               (push (%emit-key key timestamp) tokens)
;;                               (setf pos (1+ end)))
;;                             (let* ((params-str (map 'string #'code-char
;;                                                  (subseq bytes (+ pos 2) end)))
;;                                     ;; (params (mapcar
;;                                     ;;          (lambda (s)
;;                                     ;;            (parse-integer s :junk-allowed t))
;;                                     ;;          (uiop:split-string params-str :separator '(#\;))))
;;                                     )
;;                               ;; (format t "CSI sequence: ~A, params: ~A~% params-str: ~A~%"
;;                               ;;         seq params params-str)
;;                               (cond
;;                                 ((and (member final-byte ;; mouse event
;;                                         (list (char-code #\M) (char-code #\m)))
;;                                    (find #\< params-str)) ; SGR mouse
;;                                   (progn (push (parse-csi-mouse
;;                                                  (remove nil (mapcar
;;                                                                (lambda (s)
;;                                                                  (parse-integer s :junk-allowed t))
;;                                                                (uiop:split-string params-str :separator '(#\; #\<)))) final-byte) tokens)
;;                                     (setf pos (1+ end))))
;;                                 ((and t) ;; Unrecognized CSI sequence
;;                                   (progn
;;                                     (format t "Unrecognized CSI sequence: ~A~%" seq)
;;                                     (push (%emit-key (code-char byte) timestamp) tokens)
;;                                     (advance)))))))
;;                         ;; Incomplete CSI
;;                         (return))))
;;                   ;; Alt+char
;;                   ((and next)
;;                     (progn
;;                                         ;(format t "Alt+char sequence: ~A~%" (subseq bytes pos (+ pos 2)))
;;                       (push (%emit-key (code-char (aref next 0)) timestamp '(:alt)) tokens)
;;                       (take 2)))
;;                   ;; Lone ESC
;;                   ((and t)
;;                     (progn
;;                       (format t "Lone ESC character at position ~D~%" pos)
;;                       (push (%emit-key :escape timestamp) tokens)
;;                       (advance))))))
;;             ;; Other characters
;;             ((and t)
;;               (progn (push (%emit-key (code-char byte) timestamp) tokens)
;;                 (advance)))))))
;;     (values (nreverse tokens)
;;       (make-decoder :buf (subseq bytes pos) :paste-mode (getf decoder :paste)))))

;; == cl-inputs/src/decoder.lisp ==
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
    (cl-inputs.tokens:make-token
      :mouse `(:type ,etype :x ,(1- cx) :y ,(1- cy) :button ,button :mods ,mods) timestamp)))

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
;; NOTES / FIXES vs your draft:
;; - CSI `end` index is inclusive; we correctly use (1+ end) in subseq and move pos to (1+ end).
;; - Incomplete ESC/CSI sequences are preserved in :buf; previously they could be partially emitted.
;; - ALT path consumes exactly two bytes (ESC + byte); if the second byte isn't present, we buffer.
;; - Fallback on unknown CSI now avoids consuming full unknown blobs blindly: it emits :escape and advances by 1 to prevent deadlocks while staying conservative.
;; - All byte operations are on (unsigned-byte 8) arrays; no accidental character decoding paths.
;; == end/decoder.lisp ==
