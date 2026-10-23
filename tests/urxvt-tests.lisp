(uiop:define-package :cl-inputs.tests.urxvt
  (:use :cl :fiveam)
  (:import-from :cl-inputs.device.api
                #:device-kind #:open-device #:close-device
                #:device-output-stream #:device-fd #:device-capabilities
                #:device-read-bytes #:device-write-bytes #:device-set-modes
                #:disable-raw-mode)
  (:import-from :cl-inputs.terminal.api
                #:clear-screen #:clear-area #:fill-rectangle
                #:draw-text-at #:draw-char-at #:hide-cursor #:show-cursor
                #:get-cursor-position #:flush-output #:scroll-lines
                #:apply-style #:reset-style)
  (:export #:urxvt-tests))
(in-package :cl-inputs.tests.urxvt)

(def-suite urxvt-tests
  :description "URxvt backend tests without spawning an external terminal"
  :in :cl-inputs)
(in-suite urxvt-tests)

(test unopened-urxvt-cleanup-and-fail-closed-io
  (let ((dev (cl-inputs.device.urxvt::make-urxvt-device)))
    (is (eq :urxvt (device-kind dev)))
    (is (eq dev (open-device dev)))
    (is (= -1 (device-fd dev)))
    (is (null (device-output-stream dev)))
    (let ((caps (device-capabilities dev)))
      (is-true (getf caps :urxvt))
      (is (not (eq caps (device-capabilities dev)))))
    (signals error (device-read-bytes
                    dev (make-array 1 :element-type '(unsigned-byte 8)) 0 1))
    (signals error (device-write-bytes
                    dev (make-array 1 :element-type '(unsigned-byte 8)) 0 1))
    (is (null (clear-area dev 0 0 0 3)))
    (is (null (fill-rectangle dev 0 0 3 0)))
    (is-true (flush-output dev))
    (is-true (close-device dev))
    (is-true (close-device dev))))

(test urxvt-control-escapes-through-binary-fd
  "Exercise output and cursor state on a real file descriptor."
  (let* ((path (merge-pathnames
                (format nil "cl-inputs-urxvt-~A.bin" (gensym))
                (uiop:temporary-directory)))
         (stream (open path :direction :output :if-exists :supersede
                            :element-type '(unsigned-byte 8)))
         (dev (cl-inputs.device.urxvt::make-urxvt-device
               :stream stream :master-fd -1 :slave-fd -1)))
    (unwind-protect
         (progn
           (is (eq stream (device-output-stream dev)))
           (is-true (clear-screen dev))
           (is-true (draw-text-at dev 1 2 "OK"))
           (is-true (draw-char-at dev 2 4 #\@))
           (is-true (hide-cursor dev))
           (is-true (show-cursor dev))
           (is-true (device-set-modes dev '(:paste t :focus t)))
           (is-true (flush-output dev))
           (multiple-value-bind (row col) (get-cursor-position dev)
             (is (= row 2))
             (is (= col 4)))
           (with-open-file (input path :element-type '(unsigned-byte 8))
             (let ((bytes (make-array (file-length input)
                                      :element-type '(unsigned-byte 8))))
               (read-sequence bytes input)
               (let ((output (map 'string #'code-char bytes)))
                 (is (search (format nil "~C[2J~C[H" #\Esc #\Esc) output))
                 (is (search (format nil "~C[2;3HOK" #\Esc) output))
                 (is (search (format nil "~C[?25l" #\Esc) output))
                 (is (search (format nil "~C[?25h" #\Esc) output))
                 (is (search (format nil "~C[?2004h" #\Esc) output))))))
      (ignore-errors (close-device dev))
      (when (probe-file path) (delete-file path)))
    (is (null (device-output-stream dev)))
    (is (= -1 (device-fd dev)))))

(test urxvt-pipe-read-honors-slice-would-block-and-eof
  "No terminal process is needed to qualify bounded PTY-side reads."
  (multiple-value-bind (read-fd write-fd) (sb-posix:pipe)
    (let ((dev (cl-inputs.device.urxvt::make-urxvt-device
                :master-fd read-fd :slave-fd -1))
          (writer-open-p t)
          (buffer (make-array 5 :element-type '(unsigned-byte 8)
                                :initial-element 99))
          (payload (make-array 2 :element-type '(unsigned-byte 8)
                                 :initial-contents '(65 66))))
      (unwind-protect
           (progn
             ;; A zero-length call is always immediate even if the pipe is idle.
             (is (= 0 (device-read-bytes dev buffer 2 2)))
             (let ((flags (sb-posix:fcntl read-fd sb-posix:f-getfl)))
               (sb-posix:fcntl read-fd sb-posix:f-setfl
                               (logior flags sb-posix:o-nonblock)))
             (is (eq :would-block (device-read-bytes dev buffer 1 3)))
             (sb-sys:with-pinned-objects (payload)
               (is (= 2 (sb-posix:write write-fd
                                       (sb-sys:vector-sap payload) 2))))
             (is (eq t (cl-inputs.device.api:device-wait-readable dev 100)))
             (is (= 2 (device-read-bytes dev buffer 1 3)))
             (is (equalp #(99 65 66 99 99) buffer))
             (is (eq :would-block (device-read-bytes dev buffer 1 3)))
             (sb-posix:close write-fd)
             (setf writer-open-p nil)
             ;; EOF is distinct from :WOULD-BLOCK.
             (is (eq :eof (device-read-bytes dev buffer 1 3))))
        (when writer-open-p (ignore-errors (sb-posix:close write-fd)))
        (ignore-errors (close-device dev))))))

(test urxvt-raw-mode-unwinds-to-original-pty-attributes
  "A fresh kernel PTY allows raw/restoration tests without /dev/tty or urxvt."
  (multiple-value-bind (master slave name)
      (cl-inputs.device.urxvt::find-a-pty)
    (declare (ignore name))
    (let ((dev (cl-inputs.device.urxvt::make-urxvt-device
                :master-fd master :slave-fd -1)))
      (unwind-protect
           (let ((before (sb-posix:tcgetattr master)))
             (signals simple-error
               (cl-inputs.device.urxvt::with-raw-mode (dev)
                 (let ((during (sb-posix:tcgetattr master)))
                   (is (zerop (logand sb-posix:icanon
                                     (sb-posix:termios-lflag during))))
                   (is (zerop (logand sb-posix:echo
                                     (sb-posix:termios-lflag during)))))
                 (error "intentional unwind")))
             (let ((after (sb-posix:tcgetattr master)))
               (is (= (sb-posix:termios-lflag before)
                      (sb-posix:termios-lflag after)))
               (is (equalp (sb-posix:termios-cc before)
                           (sb-posix:termios-cc after))))
             (is (null (cl-inputs.device.urxvt::urxvt-device-original-termios dev)))
             (is-true (disable-raw-mode dev)))
        (ignore-errors (close-device dev))
        (ignore-errors (sb-posix:close slave))))))


(test urxvt-close-restores-raw-state-and-nonblocking-fd
  "Close must restore the PTY slave and release the master's owning stream."
  (multiple-value-bind (master slave name)
      (cl-inputs.device.urxvt::find-a-pty)
    (declare (ignore name))
    (let ((dev nil)
          (stream nil)
          ;; Keep the kernel PTY alive after DEV closes its master stream.
          (observer-fd (sb-posix:dup master)))
      (unwind-protect
           (let ((before (sb-posix:tcgetattr slave)))
             (setf stream (sb-sys:make-fd-stream master
                                                 :input t :output t
                                                 :element-type '(unsigned-byte 8)
                                                 :buffering :none)
                   dev (cl-inputs.device.urxvt::make-urxvt-device
                         :stream stream :master-fd master :slave-fd -1))
             (is-true (cl-inputs.device.api:enable-raw-mode dev))
             (is (not (null
                       (cl-inputs.device.urxvt::urxvt-device-original-termios dev))))
             (is-true (cl-inputs.device.api:device-set-nonblocking dev t))
             (is (not (cl-inputs.device.urxvt::urxvt-device-blocking dev)))
             (is (null (cl-inputs.device.api:device-set-nonblocking dev nil)))
             (is (cl-inputs.device.urxvt::urxvt-device-blocking dev))
             (is-true (close-device dev))
             (is (null (device-output-stream dev)))
             (is (= -1 (device-fd dev)))
             (is-true (close-device dev))
             (let ((after (sb-posix:tcgetattr slave)))
               (is (= (sb-posix:termios-lflag before)
                      (sb-posix:termios-lflag after)))
               (is (equalp (sb-posix:termios-cc before)
                           (sb-posix:termios-cc after)))))
        (if dev
            (ignore-errors (close-device dev))
            (if stream
                (ignore-errors (close stream))
                (ignore-errors (sb-posix:close master))))
        (ignore-errors (sb-posix:close observer-fd))
        (ignore-errors (sb-posix:close slave))))))

(test urxvt-renders-bounded-areas-styles-and-scrolling
  "Check exact emitted bytes; no alternate screen or terminal subprocess."
  (let* ((path (merge-pathnames
                (format nil "cl-inputs-urxvt-render-~A.bin" (gensym))
                (uiop:temporary-directory)))
         (stream (open path :direction :output :if-exists :supersede
                            :element-type '(unsigned-byte 8)))
         (dev (cl-inputs.device.urxvt::make-urxvt-device
               :stream stream :master-fd -1 :slave-fd -1)))
    (unwind-protect
         (progn
           (is (null (clear-area dev 0 0 0 4)))
           (is (null (fill-rectangle dev 0 0 1 0)))
           (is-true (clear-area dev 1 2 2 3 :style '(:fg :red)))
           (is-true (fill-rectangle dev 3 4 2 2 :char #\#))
           (is-true (scroll-lines dev 2))
           (is-true (scroll-lines dev -3))
           (is-true (scroll-lines dev 0))
           (is-true (apply-style dev '(:fg :green :attrs (:bold))))
           (is-true (reset-style dev))
           (is-true (draw-text-at dev 5 6 "XY" :style '(:fg :blue)))
           (multiple-value-bind (row col) (get-cursor-position dev)
             (is (= 5 row))
             (is (= 8 col)))
           (is-true (flush-output dev))
           (with-open-file (input path :element-type '(unsigned-byte 8))
             (let ((bytes (make-array (file-length input)
                                      :element-type '(unsigned-byte 8))))
               (read-sequence bytes input)
               (let ((output (map 'string #'code-char bytes))
                     (esc (string #\Esc)))
                 (is (search (format nil "~A[2;3H~A[31m   ~A[0m"
                                     esc esc esc) output))
                 (is (search (format nil "~A[4;5H##" esc) output))
                 (is (search (format nil "~A[2S~A[3T" esc esc) output))
                 (is (search (format nil "~A[32;1m~A[0m" esc esc) output))
                 (is (search (format nil "~A[6;7H~A[34mXY~A[0m"
                                     esc esc esc) output))))))
      (ignore-errors (close-device dev))
      (when (probe-file path) (delete-file path)))))
