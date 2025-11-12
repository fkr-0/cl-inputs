(defpackage :cl-inputs.tests
  (:use :cl :fiveam :cl-inputs.api :cl-inputs.util)
  (:export #:run-all-cl-inputs-tests))

(in-package :cl-inputs.tests)

(def-suite :cl-inputs
  :description "Tests for the cl-inputs library.")

(in-suite :cl-inputs)


(test smoke-test
  (is-true (fboundp 'cl-inputs:start-input-loop) "start-input-loop should be a function.")
  (is-true (fboundp 'cl-inputs.api:make-input-source) "make-input-source should be a function."))

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
  (let* ((dev (cl-inputs.device:make-device* :faketerm
                                             :script (list (string-to-utf-8-bytes "a"))))
         (src (make-input-source :device dev))
         (token (next-token src)))
    (is (eq #\a (getf (cl-inputs.tokens:input-token-data token) :code)))
    (close-input-source src)))

(test faketerm-inject-and-read
  (let* ((dev (cl-inputs.device:make-device* :faketerm))
         (src (make-input-source :device dev)))
    (cl-inputs.device::faketerm-inject! dev (string-to-utf-8-bytes "b"))
    (let ((token (next-token src)))
      (is (eq #\b (getf (cl-inputs.tokens:input-token-data token) :code))))
    (close-input-source src)))

(test push-loop
  (let* ((dev (cl-inputs.device:make-device* :faketerm))
         (received-tokens '())
         (sink (lambda (token) (push token received-tokens)))
         (loop-handle (cl-inputs:start-input-loop :device dev :sink sink)))
    (cl-inputs.device::faketerm-inject! dev (string-to-utf-8-bytes "c"))
    (sleep 0.1) ; give the loop time to process
    (stop-input-loop loop-handle)
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

(defun run-all-cl-inputs-tests ()
  "Run all elmtui tests (alias for run-tests)"
  (fiveam:run-all-tests))
