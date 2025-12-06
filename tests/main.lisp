(defpackage :cl-inputs.tests
  (:use :cl :fiveam :cl-inputs.api :cl-inputs.util :cl-inputs.loop)
  (:export #:run-all-cl-inputs-tests))

(in-package :cl-inputs.tests)

(defmacro with-faketerm ((var &key (width 8) (height 4)) &body body)
  `(let ((,var (cl-inputs.device.api:make-device :faketerm :width ,width :height ,height)))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (cl-inputs.device.api:close-device ,var)))))

(defmacro faketerm-assert-screen (device &rest rows)
  `(is (equal ',rows (cl-inputs.device.faketerm:faketerm-screen-lines ,device))))

(def-suite :cl-inputs
  :description "Tests for the cl-inputs library.")

(in-suite :cl-inputs)


(test smoke-test
  (is-true (fboundp 'cl-inputs:start-input-loop) "start-input-loop should be a function.")
  (is-true (fboundp 'cl-inputs.loop:make-input-source) "make-input-source should be a function."))

(test decode-simple-chars
  (let* ((decoder (cl-inputs.decoder:make-decoder))
          (bytes (string-to-utf-8-bytes "abc"))
          (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
    (is (= 3 (length tokens)) "Should decode 3 characters.")
    (is (eql #\a (getf (cl-inputs.tokens:input-token-data (first tokens)) :code)))
    (is (eql #\b (getf (cl-inputs.tokens:input-token-data (second tokens)) :code)))
    (is (eql #\c (getf (cl-inputs.tokens:input-token-data (third tokens)) :code)))))

(test decode-arrow-keys
  (let ((decoder (cl-inputs.decoder:make-decoder)))
    (let* ((bytes (make-array 3
                    :element-type '(unsigned-byte 8)
                    :initial-contents
                    (list 27 91 65))) ; Up
            (tokens (nth-value
                      0
                      (cl-inputs.decoder:decode-chunk decoder bytes))))
      ;; tokens))
      (is (= 1 (length tokens)))
      (is (eq :up (getf (cl-inputs.tokens:input-token-data (first tokens)) :code))))
    (let* ((bytes (make-array 3 :element-type '(unsigned-byte 8) :initial-contents (list 27 91 66))) ; Down
            (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
      (is (= 1 (length tokens)))
      (is (eq :down (getf (cl-inputs.tokens:input-token-data (first tokens)) :code))))))

(test decode-mouse-event
  (let* ((decoder (cl-inputs.decoder:make-decoder))
          ;; SGR mouse press: ESC [ < 0 ; 10 ; 20 M
          ;; 0 here indicates the button pressed, 10 is x, 20 is y]
          ;; instead of 0, we can use 4 for button 1, 5 for button 2, etc.
          (bytes (string-to-utf-8-bytes "[<7;10;20M"))
          ;; (tt (cl-inputs.decoder:decode-chunk decoder bytes))
          (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
    ;; tt)
    ;; tokens))
    (is (= 1 (length tokens)) "Should decode one mouse token.")
    (let ((token-data (cl-inputs.tokens:input-token-data (first tokens))))
      (is (eq :mouse (cl-inputs.tokens:input-token-kind (first tokens))))
      (is (eq :mouse-down (getf token-data :type)))
      (is (= 9 (getf token-data :x)))
      (is (= 19 (getf token-data :y))))))

(test faketerm-backend-read
  (let* ((dev (cl-inputs.device.api:make-device :faketerm
                :script (list (string-to-utf-8-bytes "a"))))
          (src (make-input-source :device dev))
          (token (next-token src)))
    (is (eq #\a (getf (cl-inputs.tokens:input-token-data token) :code)))
    (close-input-source src)))

(test faketerm-inject-and-read
  (let* ((dev (cl-inputs.device.api:make-device :faketerm))
          (src (make-input-source :device dev)))
    (cl-inputs.device.faketerm::faketerm-inject! dev (string-to-utf-8-bytes "b"))
    (let ((token (next-token src)))
      (is (eq #\b (getf (cl-inputs.tokens:input-token-data token) :code))))
    (close-input-source src)))

(test push-loop
  (let* ((dev (cl-inputs.device.api:make-device :faketerm))
          (received-tokens '())
          (sink (lambda (token) (push token received-tokens)))
          (loop-handle (cl-inputs:start-input-loop :device dev :sink sink)))
    (cl-inputs.device.faketerm::faketerm-inject! dev (string-to-utf-8-bytes "c"))
    (sleep 0.1) ; give the loop time to process
    (cl-inputs.loop::stop-input-loop loop-handle)
    (is (= 1 (length received-tokens)))
    (is (eql #\c (getf (cl-inputs.tokens:input-token-data (first received-tokens)) :code)))))

(test incomplete-sequence
  (let* ((decoder (cl-inputs.decoder:make-decoder))
          (bytes (string-to-utf-8-bytes "[<0;10;")) ; Incomplete mouse sequence
          (values (multiple-value-list (cl-inputs.decoder:decode-chunk decoder bytes)))
          (tokens (first values))
          (new-decoder (second values)))
    (is (null tokens) "Should not emit tokens for incomplete sequences.")
    (is (plusp (length (getf new-decoder :buf))) "Buffer should contain the incomplete sequence.")))

(test terminal-draw-and-clear-faketerm
  (with-faketerm (term :width 8 :height 3)
    (cl-inputs:draw-text-at term 0 0 "hello")
    (cl-inputs:draw-text-at term 1 2 "xy")
    (cl-inputs:clear-area term 0 2 1 2)
    (faketerm-assert-screen term
      "he  o"
      "  xy"
      "")
    (is (equal '(:fg :default :bg :default :attrs nil)
               (cl-inputs.device.faketerm::faketerm-cell-style-at term 0 0)))))

(test terminal-fill-rectangle
  (with-faketerm (term :width 6 :height 3)
    (cl-inputs:fill-rectangle term 0 0 2 3 :char #\# :style '(:fg :red))
    (cl-inputs:draw-char-at term 1 1 #\Space)
    (faketerm-assert-screen term
      "###"
      "# #"
      "")
    (is (equal '(:fg :red)
               (cl-inputs.device.faketerm::faketerm-cell-style-at term 0 0)))))

(test terminal-style-and-cursor-controls
  (with-faketerm (term :width 3 :height 2)
    (cl-inputs:apply-style term '(:fg :green :bg :black))
    (is (equal '(:fg :green :bg :black)
               (cl-inputs.device.faketerm::faketerm-device-current-style term)))
    (cl-inputs:reset-style term)
    (is (equal '(:fg :default :bg :default :attrs nil)
               (cl-inputs.device.faketerm::faketerm-device-current-style term)))
    (cl-inputs:set-cursor-position term 1 2)
    (multiple-value-bind (row col) (cl-inputs:get-cursor-position term)
      (is (= 1 row))
      (is (= 2 col)))
    (cl-inputs:hide-cursor term)
    (is (null (cl-inputs.device.faketerm::faketerm-device-cursor-visible-p term)))
    (cl-inputs:show-cursor term)
    (is (cl-inputs.device.faketerm::faketerm-device-cursor-visible-p term))))

(test terminal-modes-and-wait
  (with-faketerm (term)
    (is (cl-inputs:device-set-modes term '(:mouse :sgr :paste t :focus t)))
    (is (null (cl-inputs:device-wait-readable term 0)))
    (cl-inputs.device.faketerm::faketerm-inject! term (string-to-utf-8-bytes "z"))
    (is (cl-inputs:device-wait-readable term 0))))

(test terminal-scroll-lines
  (with-faketerm (term :width 5 :height 4)
    (loop for row below 4 do
      (cl-inputs:draw-text-at term row 0 (format nil "row~d" row)))
    (cl-inputs:scroll-lines term 2)
    (faketerm-assert-screen term
      "row2"
      "row3"
      ""
      "")
    (cl-inputs:scroll-lines term -1)
    (faketerm-assert-screen term
      ""
      "row2"
      "row3"
      ""))
  t)

#+sbcl
(test tty-read-into-buffer
  (multiple-value-bind (read-fd write-fd) (uiop:symbol-call :sb-posix :pipe)
    (flet ((close-fd (fd)
             (when fd
               (ignore-errors (uiop:symbol-call :sb-posix :close fd)))))
      (unwind-protect
        (let* ((payload (string-to-utf-8-bytes "tty"))
                (buffer (make-array 16 :element-type '(unsigned-byte 8) :initial-element 0))
                (count (length payload)))
          (let ((out-stream (sb-sys:make-fd-stream write-fd :output t :input nil
                              :element-type '(unsigned-byte 8)
                              :buffering :none)))
            (write-sequence payload out-stream :end count)
            (finish-output out-stream)
            (close out-stream)
            (setf write-fd nil))
          (let ((read-count (cl-inputs.device.tty::%tty-read-into-buffer
                              read-fd buffer 4 count nil)))
            (is (= count read-count))
            (dotimes (i read-count)
              (is (= (aref payload i) (aref buffer (+ 4 i))))))
          (is (= 0 (cl-inputs.device.tty::%tty-read-into-buffer read-fd buffer 0 1 nil))))
        (close-fd read-fd)
        (close-fd write-fd)))))



(defun run-all-cl-inputs-tests ()
  "Run all elmtui tests (alias for run-tests)"
  (fiveam:run-all-tests))

;; Integration test placeholder for a simple defapplication using faketerm
;; (Currently a stub; enable once pipeline supports headless run cleanly)
;; (fiveam:def-suite* :cl-inputs/defapp :in :cl-inputs)
;; (fiveam:test run-defapp-smoke
;;   (is-true t))
