;;;; cl-inputs.device.faketerm.lisp
;;;
;;; Fake terminal device backend for cl-inputs.
;;; Implements the device API using in-memory queues for testing and simulation.

(uiop:define-package :cl-inputs.device.faketerm
  (:use :cl :alexandria )
  (:import-from
    #:cl-inputs.util #:as-utf-8-bytes #:string-to-utf-8-bytes)
  (:import-from #:sb-ext #:run-program  #:process-pid #:process-pty #:process-kill)
  (:import-from #:sb-sys #:make-fd-stream #:fd-stream-fd)
  (:use #:sb-unix)

  ;; #:sb-posix #:termios #:tcgetattr #:tcsetattr
  ;;             #:tcsanow #:icanon #:echo #:vmin #:vtime
  (:import-from :cl-inputs.device.api
    ;; Device port (generics; default stub prints warnings)
    #:make-device
    #:device-kind
    #:open-device #:close-device
    #:enable-raw-mode #:disable-raw-mode
    #:enable-raw-char-mode #:disable-raw-char-mode
    #:device-read-bytes #:device-write-bytes
    #:device-capabilities
    #:device-set-modes
    #:device-set-nonblocking
    #:device-wait-readable)
  (:import-from :cl-inputs.terminal.api
    #:clear-screen #:clear-area #:draw-text-at #:draw-char-at #:fill-rectangle
    #:scroll-lines #:set-cursor-position #:get-cursor-position #:hide-cursor #:show-cursor
    #:flush-output #:apply-style #:reset-style)
  (:export #:faketerm-screen-lines))

(in-package :cl-inputs.device.faketerm)
;; A simple queue implementation using cons cells.

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

(defstruct faketerm-cell
  (char #\Space :type character)
  (style nil :type list))

(defstruct faketerm-device
  "Fake terminal device for testing.

Fields:
  IN-QUEUE  -- input queue (type: list of octet vectors)
  OUT-QUEUE -- output queue (type: list of octet vectors)
  CAPS      -- device capabilities (type: plist)

All fields are required."
  in-queue
  out-queue
  caps
  (width 80 :type (integer 1 *))
  (height 24 :type (integer 1 *))
  (screen nil :type (or null (simple-array faketerm-cell (* *))))
  (cursor-row 0 :type integer)
  (cursor-col 0 :type integer)
  (cursor-visible-p t :type boolean)
  (log '() :type list)
  (current-style nil :type list))

(defun %make-screen (width height &optional style)
  (let ((screen (make-array (list height width) :element-type 'faketerm-cell
                  :initial-element (make-faketerm-cell :style style))))
    (dotimes (r height)
      (dotimes (c width)
        (setf (aref screen r c) (make-faketerm-cell :style style))))
    screen))

(defun %ensure-screen (dev)
  (or (faketerm-device-screen dev)
    (setf (faketerm-device-screen dev)
      (%make-screen (faketerm-device-width dev)
        (faketerm-device-height dev) (faketerm-device-current-style dev)))))

(defun %reset-screen (dev)
  (setf (faketerm-device-screen dev)
    (%make-screen (faketerm-device-width dev)
      (faketerm-device-height dev) (faketerm-device-current-style dev))))

(defun faketerm-screen-lines (dev &key (trim-right t))
  "Return the fake screen contents as a list of strings."
  (let* ((screen (%ensure-screen dev))
          (height (array-dimension screen 0))
          (width (array-dimension screen 1)))
    (loop for r below height
      collect
      (let* ((chars (loop for c below width collect (faketerm-cell-char (aref screen r c))))
              (str (coerce chars 'string)))
        (if trim-right
          (string-right-trim " " str)
          str)))))

(defun faketerm-cell-style-at (dev row col)
  "Return the style plist stored at ROW/COL."
  (faketerm-cell-style (aref (%ensure-screen dev) row col)))

(defun %screen-size (dev)
  (let ((screen (%ensure-screen dev)))
    (values (array-dimension screen 0)
      (array-dimension screen 1))))

(defun %set-cell (dev row col char style)
  (multiple-value-bind (height width) (%screen-size dev)
    (when (and (<= 0 row) (< row height) (<= 0 col) (< col width))
      (let ((cell (aref (%ensure-screen dev) row col)))
        (setf (faketerm-cell-char cell) char
          (faketerm-cell-style cell) style)))))

(defun %effective-style (dev style)
  (or style (faketerm-device-current-style dev)))

(defun %make-faketerm-device ()
  "Construct a creator closure for faketerm devices."
  (lambda (&key (script nil) (caps '(:truecolor t :mouse nil :paste nil :focus nil))
            (width 80) (height 24))
    (let ((in (make-queue)) (out (make-queue)))
      (when script
        (if (pathnamep script)
          (with-open-file (s script :element-type '(unsigned-byte 8))
            (loop with buf = (make-array 4096 :element-type '(unsigned-byte 8))
              for n = (read-sequence buf s) while (> n 0)
              do (queue-push in (subseq buf 0 n))))
          (dolist (chunk script)
            (queue-push in chunk))))
      (make-faketerm-device :in-queue in :out-queue out :caps caps
        :width width :height height
        :screen (%make-screen width height)
        :current-style '(:fg :default :bg :default :attrs nil)))))

(defmethod make-device ((backend (eql :faketerm)) &rest initargs &key &allow-other-keys)
  "Instantiate a new faketerm-device for the :faketerm backend."
  (declare (ignore backend))
  (apply (%make-faketerm-device) initargs))

(defmethod device-kind ((dev faketerm-device)) :faketerm)

(defmethod open-device ((dev faketerm-device)) dev)

(defmethod close-device ((dev faketerm-device)) t)

(defmethod enable-raw-mode ((dev faketerm-device)) t)

(defmethod disable-raw-mode ((dev faketerm-device)) t)

(defmethod enable-raw-char-mode ((dev faketerm-device)
                                  &key vmin vtime canonical echo isig)
  (declare (ignore dev vmin vtime canonical echo isig))
  t)

(defmethod disable-raw-char-mode ((dev faketerm-device))
  t)

(defmethod device-read-bytes ((dev faketerm-device) buffer start end)
  "Read a chunk from the input queue into BUFFER[start..end).
Returns number of bytes read, or :eof if the queue is empty."
  (if (queue-empty-p (faketerm-device-in-queue dev))
    :eof
    (let ((chunk (queue-pop (faketerm-device-in-queue dev))))
      (replace buffer chunk :start1 start)
      (length chunk))))

(defmethod device-write-bytes ((dev faketerm-device) buffer start end)
  "Push BUFFER[start..end) as a chunk to the output queue.
Returns the number of bytes written."
  (queue-push (faketerm-device-out-queue dev) (subseq buffer start end))
  (- end start))

(defmethod device-capabilities ((dev faketerm-device))
  "Return a copy of the device's capabilities plist."
  (copy-list (faketerm-device-caps dev)))

(defmethod device-set-modes ((dev faketerm-device) _modes)
  "No-op for faketerm-device. Always returns T."
  (declare (ignore _modes))
  t)

(defmethod device-set-nonblocking ((dev faketerm-device) _flag)
  "Non-blocking toggles do not apply to the queue-backed faketerm device."
  (declare (ignore dev _flag))
  t)

(defmethod device-wait-readable ((dev faketerm-device) _timeout-ms)
  "Return true as soon as there is data waiting in the fake queue."
  (declare (ignore _timeout-ms))
  (not (queue-empty-p (faketerm-device-in-queue dev))))

;;; ---------------------------------------------------------------------------
;;; High-level terminal functionality

(defmethod clear-screen ((dev faketerm-device))
  (%reset-screen dev)
  (setf (faketerm-device-cursor-row dev) 0
    (faketerm-device-cursor-col dev) 0)
  t)

(defmethod clear-area ((dev faketerm-device) row col height width &key style)
  (let ((style (%effective-style dev style)))
    (dotimes (dy height)
      (dotimes (dx width)
        (%set-cell dev (+ row dy) (+ col dx) #\Space style))))
  t)

(defmethod draw-text-at ((dev faketerm-device) row col text &key style)
  (let ((style (%effective-style dev style)))
    (loop for i from 0 below (length text) do
      (%set-cell dev row (+ col i) (char text i) style)))
  (setf (faketerm-device-cursor-row dev) row
    (faketerm-device-cursor-col dev) (+ col (length text)))
  t)

(defmethod draw-char-at ((dev faketerm-device) row col char &key style)
  (%set-cell dev row col char (%effective-style dev style))
  (setf (faketerm-device-cursor-row dev) row
    (faketerm-device-cursor-col dev) col)
  t)

(defmethod fill-rectangle ((dev faketerm-device) row col height width &key (char #\Space) style)
  (let ((style (%effective-style dev style)))
    (dotimes (dy height)
      (dotimes (dx width)
        (%set-cell dev (+ row dy) (+ col dx) char style))))
  t)

(defun %scroll-screen (dev count)
  (multiple-value-bind (height width) (%screen-size dev)
    (let ((screen (%ensure-screen dev)))
      (cond
        ((> count 0)
          (dotimes (r height)
            (let ((src (+ r count)))
              (dotimes (c width)
                (if (< src height)
                  (let ((cell (aref screen src c)))
                    (setf (aref screen r c)
                      (make-faketerm-cell
                        :char (faketerm-cell-char cell)
                        :style (faketerm-cell-style cell))))
                  (setf (aref screen r c)
                    (make-faketerm-cell :style (faketerm-device-current-style dev))))))))
        ((< count 0)
          (let ((delta (- count)))
            (loop for r from (1- height) downto 0 do
              (let ((src (- r delta)))
                (dotimes (c width)
                  (if (>= src 0)
                    (let ((cell (aref screen src c)))
                      (setf (aref screen r c)
                        (make-faketerm-cell
                          :char (faketerm-cell-char cell)
                          :style (faketerm-cell-style cell))))
                    (setf (aref screen r c)
                      (make-faketerm-cell :style (faketerm-device-current-style dev)))))))))))))

(defmethod scroll-lines ((dev faketerm-device) count)
  (%scroll-screen dev count)
  t)

(defmethod set-cursor-position ((dev faketerm-device) row col)
  (setf (faketerm-device-cursor-row dev) row
    (faketerm-device-cursor-col dev) col)
  t)

(defmethod get-cursor-position ((dev faketerm-device))
  (values (faketerm-device-cursor-row dev)
    (faketerm-device-cursor-col dev)))

(defmethod hide-cursor ((dev faketerm-device))
  (setf (faketerm-device-cursor-visible-p dev) nil)
  t)

(defmethod show-cursor ((dev faketerm-device))
  (setf (faketerm-device-cursor-visible-p dev) t)
  t)

(defmethod flush-output ((dev faketerm-device))
  (declare (ignore dev))
  t)

(defmethod apply-style ((dev faketerm-device) style)
  (setf (faketerm-device-current-style dev) style)
  t)

(defmethod reset-style ((dev faketerm-device))
  (setf (faketerm-device-current-style dev) '(:fg :default :bg :default :attrs nil))
  t)

;;; Test helpers:

(defun faketerm-inject! (dev octets)
  "Inject OCTETS into the input queue of DEV."
  (queue-push (faketerm-device-in-queue dev) octets))

(defun faketerm-captured (dev)
  "Return all octets captured in the output queue of DEV."
  (cdr (first (faketerm-device-out-queue dev))))
