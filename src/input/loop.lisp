(in-package :cl-inputs.api)

(defstruct input-loop dev thread stop? decoder sink)

(defun %deliver (sink token)
  (cond
    ((functionp sink) (funcall sink token))
    (t
     (accept-token sink token)
     (ecase (cl-inputs.tokens:input-token-kind token)
       (:key    (on-key sink token))
       (:mouse  (on-mouse sink token))
       (:resize (on-resize sink token))
       (:ctrl-c (on-ctrl-c sink token))
       (:paste  (on-paste sink token))
       (:focus  (on-focus sink token))))))

(defun start-input-loop (&key (device (cl-inputs.device:make-device :tty))
                           (sink (fn-sink (lambda (_tok) (declare (ignore _tok)) nil)))
                           (decoder (cl-inputs.decoder:make-decoder)))
  "Reads from DEVICE, decodes via DECODER, pushes to SINK. Returns an INPUT-LOOP handle."
  (cl-inputs.device:enable-raw-mode device)
  (let ((in-loop (make-input-loop :dev device :sink sink :decoder decoder)))
    (setf (input-loop-thread in-loop)
          (bt:make-thread
           (lambda ()
             (let ((buf (make-array 64 :element-type '(unsigned-byte 8))))
               (unwind-protect
                    (loop until (input-loop-stop? in-loop) do
                      (let ((n (cl-inputs.device:device-read-bytes device buf 0 (length buf))))
                        (when (or (eql n :eof) (null n)) (return))
                        (multiple-value-bind (tokens dec2)
                            (cl-inputs.decoder:decode-chunk (input-loop-decoder in-loop)
                                                            (subseq buf 0 n))
                          (setf (input-loop-decoder in-loop) dec2)
                          (dolist (to tokens) (%deliver (input-loop-sink in-loop) to)))))
                 (cl-inputs.device:disable-raw-mode device))))
           :name "cl-inputs.loop"))
    in-loop))

(defun stop-input-loop (in-loop)
  (setf (input-loop-stop? in-loop) t)
  (cl-inputs.device:close-device (input-loop-dev in-loop))
  t)

;;; Pull mode: a source object that yields tokens on demand
;; (defstruct (input-source
;; :constructor make-input-source)
;;   "A source of input tokens, reading from a device and decoding them."
;;   (dev nil :type cl-inputs.device:device)
;;   (decoder nil :type cl-inputs.decoder:decoder)
;;   (buf nil :type (array (unsigned-byte 8) (*)) :read-only t))
(defstruct (input-source (:constructor %make-input-source))
  "A source of input tokens, typically from a device."
  dev decoder buf)

(defun make-input-source (&key (device (cl-inputs.device:make-device :tty))
                            (decoder (cl-inputs.decoder:make-decoder)))

  (cl-inputs.device:enable-raw-mode device)
  (%make-input-source :dev device :decoder decoder :buf (make-array 4096 :element-type '(unsigned-byte 8))))

(defun next-token (src &key (timeout nil))
  "Blocking read (or timed if DEVICE supports it). Returns a token or NIL on EOF."
  (declare (ignore timeout)) ; extend in your device impl
  (let* ((n
           (cl-inputs.device:device-read-bytes
            (input-source-dev src)
            (input-source-buf src) 0 4096)))
    (cond
      ((or (eql n :eof) (null n) (zerop n)) nil)
      (t
       (multiple-value-bind (tokens dec2)
           (cl-inputs.decoder:decode-chunk (input-source-decoder src)
                                           (subseq (input-source-buf src) 0 n))
         (setf (input-source-decoder src) dec2)
         (first tokens))))))

(defun close-input-source (src)
  (cl-inputs.device:disable-raw-mode (input-source-dev src))
  (cl-inputs.device:close-device (input-source-dev src))
  t)
