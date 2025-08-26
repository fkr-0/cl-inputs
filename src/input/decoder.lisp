(in-package :cl-inputs.decoder)

;; You can keep the state as a plist to honor your “no mutable class slots” ethos.
(defun make-decoder (&key (buf (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)) (paste-mode :off))
  (list :buf buf :paste paste-mode))

(defun decoder-state (dec) dec)

(defun %emit-key (code ts &optional mods)
  (cl-inputs.tokens:make-token cl-inputs.tokens:+k-key+ `(:code ,code :mods ,mods) ts))

(defun is-csi-final-byte? (byte)
  (and (>= byte 64) (<= byte 126)))

(defun parse-csi-mouse (params final-byte)
  ;; (format t "PARAMS: ~A, FINAL-BYTE: ~A~%" params final-byte)
  (let* ((cb (if (< 2 (length params ))(first params) 0))
         (cx (if (< 2 (length params ))(second params) (first params)))
         (cy (if (< 2 (length params ))(third params) (second params)))
         (press (char-code #\M))
         (release (char-code #\m))
         (event-type (cond
                       ((= final-byte press) :mouse-down)
                       ((= final-byte release) :mouse-up)
                       (t :mouse-move)))
         (button (logand cb 3))
         (mods (let ((mod-code (ash cb -2)))
                 (append (when (logbitp 0 mod-code) '(:shift))
                         (when (logbitp 1 mod-code) '(:alt))
                         (when (logbitp 2 mod-code) '(:control))))))
    (make-token :mouse `(:type ,event-type :x ,(1- cx) :y ,(1- cy) :button ,button :mods ,mods))))

(defun decode-chunk (decoder octet-vector &key (timestamp (get-universal-time)))
  "Pure step: consume OCTET-VECTOR, return (values tokens new-decoder).
   Keep incomplete escape sequences in decoder’s buffer."
  (let* ((old-buf (getf decoder :buf))
         (bytes (concatenate '(vector (unsigned-byte 8)) old-buf octet-vector))
         (pos 0)
         (tokens '()))
    (labels ((take (n) (prog1 (subseq bytes pos (min (length bytes) (+ pos n))) (incf pos n)))
             (remaining () (- (length bytes) pos))
             (peek (n) (and (>= (remaining) n) (subseq bytes pos (+ pos n))))
             (advance () (incf pos))
             (current () (aref bytes pos)))
      (loop while (< pos (length bytes)) do
        (let* ((byte (current))
               (key (lookup-seq (vector byte))))
          (cond
            (key
             (push (%emit-key key timestamp) tokens)
             (advance))
            ;; ESC
            ((= byte 27)
             (let* ((next (peek 2)))
               (format t "ESC at position ~D, next bytes: ~A~%" pos next)
               (cond
                 ;; CSI
                 ((and next (equal (aref next 1) (char-code #\[)))
                  (let* ((end (position-if #'is-csi-final-byte? bytes :start (+ pos 2)))
                         (final-byte (when end (aref bytes end))))
                    (format t "End ~A Final Byte ~A~%" end final-byte)
                    (if (and end final-byte)
                        (let* ((seq (subseq bytes pos (+ 1 pos end)))
                               (key (or (lookup-seq seq)
                                        ;; (lookup-seq (concatenate 'vector (subseq seq 0 (1- (length seq)))))
                                        )))

                          (if key
                              (progn
                                (push (%emit-key key timestamp) tokens)
                                (setf pos (1+ end)))
                              (let* ((params-str (map 'string #'code-char
                                                      (subseq bytes (+ pos 2) end)))
                                     ;; (params (mapcar
                                     ;;          (lambda (s)
                                     ;;            (parse-integer s :junk-allowed t))
                                     ;;          (uiop:split-string params-str :separator '(#\;))))
                                     )
                                ;; (format t "CSI sequence: ~A, params: ~A~% params-str: ~A~%"
                                ;;         seq params params-str)
                                (cond
                                  ((and (member final-byte ;; mouse event
                                                (list (char-code #\M) (char-code #\m)))
                                        (find #\< params-str)) ; SGR mouse
                                   (progn (push (parse-csi-mouse
                                                 (remove nil (mapcar
                                                              (lambda (s)
                                                                (parse-integer s :junk-allowed t))
                                                              (uiop:split-string params-str :separator '(#\; #\<)))) final-byte) tokens)
                                          (setf pos (1+ end))))
                                  ((and t) ;; Unrecognized CSI sequence
                                   (progn
                                     (format t "Unrecognized CSI sequence: ~A~%" seq)
                                     (push (%emit-key (code-char byte) timestamp) tokens)
                                     (advance)))))))
                        ;; Incomplete CSI
                        (return))))
                 ;; Alt+char
                 ((and next)
                  (progn
                                        ;(format t "Alt+char sequence: ~A~%" (subseq bytes pos (+ pos 2)))
                    (push (%emit-key (code-char (aref next 0)) timestamp '(:alt)) tokens)
                    (take 2)))
                 ;; Lone ESC
                 ((and t)
                  (progn
                    (format t "Lone ESC character at position ~D~%" pos)
                    (push (%emit-key :escape timestamp) tokens)
                    (advance))))))
            ;; Other characters
            ((and t)
             (progn (push (%emit-key (code-char byte) timestamp) tokens)
                    (advance)))))))
    (values (nreverse tokens)
            (make-decoder :buf (subseq bytes pos) :paste-mode (getf decoder :paste)))))
