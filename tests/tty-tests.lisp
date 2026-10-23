(uiop:define-package :cl-inputs.tests.tty
  (:use :cl :fiveam)
  (:import-from :cl-inputs.device.api #:make-device #:device-kind)
  (:export #:tty-tests))

(in-package :cl-inputs.tests.tty)

(def-suite tty-tests
  :description "Tests for cl-inputs.device.tty module"
  :in :cl-inputs)

(in-suite tty-tests)

;; Note: TTY tests require actual /dev/tty access
;; These tests are minimal to avoid hanging in CI/CD

(test make-tty-device
  "Test creating a TTY device"
  (handler-case
      (let ((dev (make-device :tty)))
        (is (not (null dev)))
        (is (eq :tty (device-kind dev))))
    (sb-posix:syscall-error ()
      (skip "No controlling TTY is available in this test environment."))))

(test unopened-tty-device-is-idempotently-closable
  "A constructed but unopened device must not leak a descriptor or raw state."
  (let ((dev (cl-inputs.device.tty:make-tty-device
              :path "/dev/tty")))
    (is (eq :tty (device-kind dev)))
    (is (null (cl-inputs.device.api:device-fd dev)))
    (is (null (cl-inputs.device.api:device-input-stream dev)))
    (is (null (cl-inputs.device.api:device-output-stream dev)))
    (is-true (cl-inputs.device.api:disable-raw-mode dev))
    (is-true (cl-inputs.device.api:close-device dev))
    (is-true (cl-inputs.device.api:close-device dev))
    (is (null (cl-inputs.device.api:device-fd dev)))))

(test tty-open-failure-cleans-up-and-allows-second-close
  "An impossible path must signal and leave no half-open device."
  (let* ((path (merge-pathnames
                 (format nil "cl-inputs-no-tty-~A" (gensym))
                 (uiop:temporary-directory)))
         (dev (cl-inputs.device.tty:make-tty-device
               :path (namestring path))))
    (signals sb-posix:syscall-error (cl-inputs.device.api:open-device dev))
    (is (null (cl-inputs.device.api:device-input-stream dev)))
    (is (null (cl-inputs.device.api:device-output-stream dev)))
    (is (null (cl-inputs.device.api:device-fd dev)))
    (is-true (cl-inputs.device.api:close-device dev))
    (is-true (cl-inputs.device.api:close-device dev))))

(defun call-with-test-tty (thunk)
  "Keep the PTY master and slave owned through the entire test."
  (multiple-value-bind (master slave path)
      (cl-inputs.device.urxvt::find-a-pty)
    (let ((dev (cl-inputs.device.tty:make-tty-device :path path)))
      (unwind-protect
           (funcall thunk dev master)
        (ignore-errors (cl-inputs.device.api:close-device dev))
        (ignore-errors (sb-posix:close slave))
        (ignore-errors (sb-posix:close master))))))



(defun %read-test-master-output (fd)
  "Collect emitted terminal bytes with bounded readiness; never block forever."
  (let ((buffer (make-array 4096 :element-type '(unsigned-byte 8)))
        (result (make-array 0 :element-type 'character
                            :adjustable t :fill-pointer 0)))
    (loop repeat 12
          while (sb-sys:wait-until-fd-usable fd :input 0.05d0)
          do (sb-sys:with-pinned-objects (buffer)
               (let ((count (sb-posix:read fd (sb-sys:vector-sap buffer)
                                           (length buffer))))
                 (loop for i below count
                       do (vector-push-extend (code-char (aref buffer i))
                                              result))))
          finally (return result))))

(test tty-kernel-pty-readiness-offsets-and-write
  "One syscall per read: offset correctness, idle status, and output are real."
  (call-with-test-tty
   (lambda (dev master)
     (cl-inputs.device.api:open-device dev)
     (cl-inputs.device.api:enable-raw-mode dev)
     (is-true (cl-inputs.device.api:device-set-nonblocking dev t))
     (let ((bytes (make-array 6 :element-type '(unsigned-byte 8)
                               :initial-element 99))
           (input (make-array 3 :element-type '(unsigned-byte 8)
                                :initial-contents '(65 66 67))))
       (is (= 0 (cl-inputs.device.api:device-read-bytes dev bytes 2 2)))
       (is (eq :would-block
               (cl-inputs.device.api:device-read-bytes dev bytes 1 4)))
       (is (null (cl-inputs.device.api:device-wait-readable dev 0)))
       (sb-sys:with-pinned-objects (input)
         (is (= 3 (sb-posix:write master (sb-sys:vector-sap input) 3))))
       (is-true (cl-inputs.device.api:device-wait-readable dev 200))
       (is (= 3 (cl-inputs.device.api:device-read-bytes dev bytes 1 4)))
       (is (equalp #(99 65 66 67 99 99) bytes))
       (is (eq :would-block
               (cl-inputs.device.api:device-read-bytes dev bytes 1 4)))
       (is (null (cl-inputs.device.api:device-set-nonblocking dev nil)))
       (is (null (cl-inputs.device.tty::%tty-nonblock? dev)))
       (is-true (cl-inputs.device.api:device-set-nonblocking dev t))
       (let ((output (make-array 3 :element-type '(unsigned-byte 8)
                                  :initial-contents '(88 89 90))))
         (is (= 3 (cl-inputs.device.api:device-write-bytes
                    dev output 0 3)))
         (is (search "XYZ" (%read-test-master-output master))))))))

(test tty-kernel-pty-control-escapes-and-tracked-cursor
  "Observe ANSI mode switching and drawing without consuming terminal replies."
  (call-with-test-tty
   (lambda (dev master)
     (cl-inputs.device.api:open-device dev)
     (let ((caps (cl-inputs.device.api:device-capabilities dev)))
       (is (getf caps :truecolor))
       (is (eq :sgr (getf caps :mouse)))
       (is (getf caps :paste)))
     (is-true (cl-inputs.device.api:device-set-modes
                dev '(:mouse :sgr :paste t :focus t)))
     (is-true (cl-inputs.device.api:device-set-modes dev '(:mouse :off)))
     (is-true (cl-inputs.device.api:device-set-modes dev '(:mouse :x10)))
     (is-true (cl-inputs.terminal.api:clear-screen dev))
     (is (null (cl-inputs.terminal.api:clear-area dev 0 0 0 2)))
     (is (null (cl-inputs.terminal.api:fill-rectangle dev 0 0 2 0)))
     (is-true (cl-inputs.terminal.api:clear-area
                dev 0 1 2 3 :style '(:fg :red)))
     (is-true (cl-inputs.terminal.api:fill-rectangle
                dev 2 2 2 2 :char #\#))
     (is-true (cl-inputs.terminal.api:draw-text-at
                dev 4 5 "OK" :style '(:fg :green :attrs (:bold))))
     (multiple-value-bind (row col)
         (cl-inputs.terminal.api:get-cursor-position dev)
       (is (= 4 row))
       (is (= 7 col)))
     (is-true (cl-inputs.terminal.api:draw-char-at dev 5 6 #\!))
     (is-true (cl-inputs.terminal.api:scroll-lines dev 3))
     (is-true (cl-inputs.terminal.api:scroll-lines dev -2))
     (is-true (cl-inputs.terminal.api:scroll-lines dev 0))
     (is-true (cl-inputs.terminal.api:hide-cursor dev))
     (is (null (cl-inputs.device.tty::%tty-cursor-visible? dev)))
     (is-true (cl-inputs.terminal.api:show-cursor dev))
     (is-true (cl-inputs.terminal.api:apply-style dev '(:fg :blue)))
     (is-true (cl-inputs.terminal.api:reset-style dev))
     (is (null (cl-inputs.device.tty::%tty-current-style dev)))
     (is-true (cl-inputs.terminal.api:flush-output dev))
     (let ((output (%read-test-master-output master))
           (esc (string #\Esc)))
       (dolist (seq (list "[?1006h" "[?1003h" "[?2004h" "[?1004h"
                          "[?1006l" "[?1003l" "[?9h" "[2J" "[H"
                          "[1;2H" "[31m" "[3;3H##" "[5;6H"
                          "[32;1m" "[6;7H!" "[3S" "[2T" "[?25l"
                          "[?25h" "[34m" "[0m"))
         (is (search (concatenate 'string esc seq) output)))))))



(test tty-kernel-pty-resize-uses-ioctl-not-input
  "Fresh TIOCGWINSZ dimensions and invalid geometry never consume key bytes."
  (call-with-test-tty
   (lambda (dev master)
     (cl-inputs.device.api:open-device dev)
     (flet ((resize (height width)
              (let ((buffer (make-array 8 :element-type '(unsigned-byte 8)
                                        :initial-element 0)))
                (setf (aref buffer 0) (logand height 255)
                      (aref buffer 1) (ash height -8)
                      (aref buffer 2) (logand width 255)
                      (aref buffer 3) (ash width -8))
                (sb-sys:with-pinned-objects (buffer)
                  (is (= 0 (cl-inputs.device.tty::%tty-winsize-ioctl
                             master #x5414
                             (sb-alien:sap-alien
                              (sb-sys:vector-sap buffer)
                              (* sb-alien:unsigned-char)))))))))
       (resize 0 0)
       (signals error (cl-inputs.terminal.api:get-terminal-size dev))
       (resize 37 113)
       (multiple-value-bind (width height)
           (cl-inputs.terminal.api:get-terminal-size dev)
         (is (= 113 width))
         (is (= 37 height)))
       (resize 29 97)
       (multiple-value-bind (width height)
           (cl-inputs.terminal.api:get-terminal-size dev)
         (is (= 97 width))
         (is (= 29 height))))
     (cl-inputs.device.api:enable-raw-mode dev)
     (is-true (cl-inputs.device.api:device-set-nonblocking dev t))
     (let ((input (make-array 1 :element-type '(unsigned-byte 8)
                               :initial-element 75))
           (result (make-array 1 :element-type '(unsigned-byte 8)
                                :initial-element 0)))
       (sb-sys:with-pinned-objects (input)
         (is (= 1 (sb-posix:write master (sb-sys:vector-sap input) 1))))
       (is-true (cl-inputs.device.api:device-wait-readable dev 200))
       (is (= 1 (cl-inputs.device.api:device-read-bytes dev result 0 1)))
       (is (= 75 (aref result 0)))))))



(test tty-raw-options-are-applied-and-restored-independently
  "Explicit canonical, echo, signal and VMIN/VTIME settings stay local to PTY."
  (call-with-test-tty
   (lambda (dev master)
     (declare (ignore master))
     (cl-inputs.device.api:open-device dev)
     (let ((before (sb-posix:tcgetattr (cl-inputs.device.api:device-fd dev))))
       (is-true (cl-inputs.device.api:enable-raw-char-mode
                  dev :canonical t :echo t :isig nil :vmin 3 :vtime 4))
       (let ((during (sb-posix:tcgetattr (cl-inputs.device.api:device-fd dev))))
         (is (not (zerop (logand sb-posix:icanon
                                (sb-posix:termios-lflag during)))))
         (is (not (zerop (logand sb-posix:echo
                                (sb-posix:termios-lflag during)))))
         (is (zerop (logand sb-posix:isig
                           (sb-posix:termios-lflag during))))
         (is (= 3 (aref (sb-posix:termios-cc during) sb-posix:vmin)))
         (is (= 4 (aref (sb-posix:termios-cc during) sb-posix:vtime))))
       (is-true (cl-inputs.device.api:disable-raw-char-mode dev))
       (let ((after (sb-posix:tcgetattr (cl-inputs.device.api:device-fd dev))))
         (is (= (sb-posix:termios-lflag before)
                (sb-posix:termios-lflag after)))
         (is (equalp (sb-posix:termios-cc before)
                     (sb-posix:termios-cc after))))))))

(test tty-kernel-pty-raw-depth-unwind-and-restoration
  "Use a real kernel PTY without /dev/tty to verify nested ownership."
  (call-with-test-tty
   (lambda (dev master)
     (declare (ignore master))
     (cl-inputs.device.api:open-device dev)
     (let ((before (sb-posix:tcgetattr (cl-inputs.device.api:device-fd dev))))
       (is-true (cl-inputs.device.api:enable-raw-mode dev))
       (is (= 1 (cl-inputs.device.tty::%tty-raw-depth dev)))
       (let ((during (sb-posix:tcgetattr (cl-inputs.device.api:device-fd dev))))
         (is (zerop (logand sb-posix:icanon (sb-posix:termios-lflag during))))
         (is (zerop (logand sb-posix:echo (sb-posix:termios-lflag during))))
         (is (not (zerop (logand sb-posix:isig
                                (sb-posix:termios-lflag during)))))
         (is (= (sb-posix:termios-oflag before)
                (sb-posix:termios-oflag during))))
       (signals simple-error
         (cl-inputs.device.api:with-raw-char-mode (dev)
           (is (= 2 (cl-inputs.device.tty::%tty-raw-depth dev)))
           (error "Injected nested terminal failure")))
       (is (= 1 (cl-inputs.device.tty::%tty-raw-depth dev)))
       (is-true (cl-inputs.device.api:disable-raw-mode dev))
       (is-true (cl-inputs.device.api:disable-raw-mode dev))
       (is (= 0 (cl-inputs.device.tty::%tty-raw-depth dev)))
       (let ((after (sb-posix:tcgetattr (cl-inputs.device.api:device-fd dev))))
         (is (= (sb-posix:termios-lflag before)
                (sb-posix:termios-lflag after)))
         (is (equalp (sb-posix:termios-cc before)
                     (sb-posix:termios-cc after))))
       (is-true (cl-inputs.device.api:enable-raw-mode dev))
       (is-true (cl-inputs.device.api:close-device dev))
       (is (null (cl-inputs.device.api:device-fd dev)))
       (is (= 0 (cl-inputs.device.tty::%tty-raw-depth dev)))
       (is (null (cl-inputs.device.tty::%tty-orig-termios dev)))))))
