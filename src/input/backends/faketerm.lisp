(in-package :cl-inputs.device)

(defun make-queue ()
  (let ((head (cons nil nil)))
    (list head head)))

(defun queue-push (queue obj)
  (let ((new (cons obj nil)))
    (setf (cdr (second queue)) new)
    (setf (second queue) new))
  queue)

(defun queue-pop (queue)
  (pop (cdr (first queue))))

(defun queue-empty-p (queue)
  (null (cdr (first queue))))

(defstruct faketerm-device in-queue out-queue caps)

(register-backend :faketerm
  (lambda (&key (script nil) (caps '(:truecolor t :mouse nil :paste nil :focus nil)))
    ;; SCRIPT may be a list of octet vectors or a file path to preload bytes.
    (let ((in (make-queue)) (out (make-queue)))
      (when script
        (if (pathnamep script)
            (with-open-file (s script :element-type '(unsigned-byte 8))
              (loop with buf = (make-array 4096 :element-type '(unsigned-byte 8))
                    for n = (read-sequence buf s) while (> n 0)
                    do (queue-push in (subseq buf 0 n))))
            (dolist (chunk script)
              (queue-push in chunk))))
      (make-faketerm-device :in-queue in :out-queue out :caps caps))))

(defmethod device-kind ((dev faketerm-device)) :faketerm)

(defmethod open-device ((dev faketerm-device)) dev)

(defmethod close-device ((dev faketerm-device)) t)

(defmethod enable-raw-mode ((dev faketerm-device)) t)

(defmethod disable-raw-mode ((dev faketerm-device)) t)

(defmethod device-read-bytes ((dev faketerm-device) buffer start end)
  (if (queue-empty-p (faketerm-device-in-queue dev))
      :eof
      (let ((chunk (queue-pop (faketerm-device-in-queue dev))))
        (replace buffer chunk :start1 start)
        (length chunk))))

(defmethod device-write-bytes ((dev faketerm-device) buffer start end)
  (queue-push (faketerm-device-out-queue dev) (subseq buffer start end))
  (- end start))

(defmethod device-capabilities ((dev faketerm-device))
  (copy-list (faketerm-device-caps dev)))

(defmethod device-set-modes ((dev faketerm-device) _modes)
  (declare (ignore _modes))
  t)

;;; Test helpers:
(defun faketerm-inject! (dev octets)
  (queue-push (faketerm-device-in-queue dev) octets))

(defun faketerm-captured (dev)
  (cdr (first (faketerm-device-out-queue dev))))