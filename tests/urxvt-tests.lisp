(uiop:define-package :cl-inputs.tests.urxvt
  (:use :cl :fiveam)
  (:import-from :cl-inputs.device.api
                #:device-kind #:open-device #:close-device
                #:device-output-stream #:device-fd #:device-capabilities
                #:device-read-bytes #:device-write-bytes #:device-set-modes)
  (:import-from :cl-inputs.terminal.api
                #:clear-screen #:clear-area #:fill-rectangle
                #:draw-text-at #:draw-char-at #:hide-cursor #:show-cursor
                #:get-cursor-position #:flush-output)
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
