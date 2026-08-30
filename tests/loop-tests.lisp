(uiop:define-package :cl-inputs.tests.loop
  (:use :cl :fiveam)
  (:import-from :cl-inputs.loop
                #:make-input-source #:next-token #:close-input-source
                #:cancel-input-source #:input-source-state
                #:input-source-terminal-outcome #:input-source-owns-device-p
                #:send-terminal-query #:wait-terminal-response
                #:expect-terminal-response #:take-unmatched-terminal-response
                #:take-input-protocol-diagnostic)
  (:import-from :cl-inputs.device.api #:make-device)
  (:import-from :cl-inputs.device.faketerm
                #:faketerm-device-open-p #:faketerm-device-closed-p
                #:faketerm-device-raw-depth #:faketerm-device-nonblocking-p
                #:faketerm-device-read-count #:faketerm-device-wait-count
                #:faketerm-device-close-count #:faketerm-captured
                #:faketerm-inject!)
  (:import-from :cl-inputs.decoder #:make-decoder)
  (:import-from :cl-inputs.tokens #:input-token-kind #:input-token-data)
  (:import-from :cl-inputs.routing
                #:response-correlation-state #:response-correlation-response-type)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:export #:loop-tests))

(in-package :cl-inputs.tests.loop)

(def-suite loop-tests :description "Tests for pull-mode input sources" :in :cl-inputs)
(in-suite loop-tests)

(test input-source-drains-decoded-token-buffer
  (let* ((device (make-device :faketerm
                              :script (list (string-to-utf-8-bytes "xy"))))
         (source (make-input-source :device device)))
    (unwind-protect
         (progn
           (is (char= #\x (getf (input-token-data (next-token source)) :code)))
           (is (char= #\y (getf (input-token-data (next-token source)) :code)))
           (is (null (next-token source :timeout 0))))
      (is-true (close-input-source source)))))

(test source-owns-open-raw-nonblocking-and-idempotent-close
  (let* ((device (make-device :faketerm))
         (source (make-input-source :device device)))
    (is-true (input-source-owns-device-p source))
    (is (eq :open (input-source-state source)))
    (is-true (faketerm-device-open-p device))
    (is (= 1 (faketerm-device-raw-depth device)))
    (is-true (faketerm-device-nonblocking-p device))
    (is-true (close-input-source source))
    (is-true (close-input-source source))
    (is (eq :closed (input-source-state source)))
    (is (eq :closed (input-source-terminal-outcome source)))
    (is-true (faketerm-device-closed-p device))
    (is (= 0 (faketerm-device-raw-depth device)))
    (is (= 1 (faketerm-device-close-count device)))))

(test source-idempotent-cancel
  (let* ((device (make-device :faketerm))
         (source (make-input-source :device device)))
    (is-true (cancel-input-source source))
    (is-true (cancel-input-source source))
    (is (eq :cancelled (input-source-state source)))
    (is (eq :cancelled (input-source-terminal-outcome source)))
    (is (= 1 (faketerm-device-close-count device)))))

(test source-eintr-retry-preserves-budget
  (let* ((device (make-device :faketerm
                              :script (list :interrupted
                                            (string-to-utf-8-bytes "z"))))
         (source (make-input-source :device device)))
    (unwind-protect
      (progn
        (is (char= #\z (getf (input-token-data (next-token source :timeout 1d0)) :code)))
        (is (= 2 (faketerm-device-read-count device)))
        (is (= 2 (faketerm-device-wait-count device))))
      (close-input-source source))))

(test source-eagain-returns-to-readiness-without-read-spin
  (let* ((device (make-device :faketerm
                              :script (list :would-block
                                            (string-to-utf-8-bytes "q"))))
         (source (make-input-source :device device)))
    (unwind-protect
      (progn
        (is (char= #\q (getf (input-token-data (next-token source :timeout 1d0)) :code)))
        (is (= 2 (faketerm-device-read-count device)))
        (is (= 2 (faketerm-device-wait-count device))))
      (close-input-source source))))

(test source-timeout-consumes-exact-remaining-budget
  (let ((now 10d0))
    (flet ((clock () now)
           (wait-and-advance (_dev timeout-ms)
             (declare (ignore _dev))
             (incf now (/ timeout-ms 1000d0))
             nil))
      (let* ((device (make-device :faketerm :eof-on-empty-p nil
                                  :wait-function #'wait-and-advance))
             (source (make-input-source :device device :clock #'clock)))
        (unwind-protect
          (progn
            (is (null (next-token source :timeout 0.12d0)))
            (is (= 3 (faketerm-device-wait-count device)))
            (is (< (abs (- now 10.12d0)) 1d-9)))
          (close-input-source source))))))

(test source-propagates-decoder-pending-escape-deadline
  (let ((now 20d0))
    (flet ((clock () now)
           (wait-and-advance (_dev timeout-ms)
             (declare (ignore _dev))
             (incf now (/ timeout-ms 1000d0))
             nil))
      (let* ((device (make-device
                      :faketerm
                      :script (list (make-array 1 :element-type '(unsigned-byte 8)
                                                :initial-contents '(27)))
                      :eof-on-empty-p nil
                      :wait-function #'wait-and-advance))
             (decoder (make-decoder :clock #'clock :escape-timeout 0.025d0))
             (source (make-input-source :device device :decoder decoder :clock #'clock)))
        (unwind-protect
          (let ((token (next-token source :timeout 0.2d0)))
            (is (eq :escape (getf (input-token-data token) :code)))
            (is (< (abs (- now 20.025d0)) 1d-9))
            (is (= 2 (faketerm-device-wait-count device))))
          (close-input-source source))))))

(test source-partial-open-failure-cleans-owned-device
  (let ((device (make-device :faketerm :fail-on-raw-p t)))
    (signals error (make-input-source :device device))
    (is-true (faketerm-device-closed-p device))
    (is (= 0 (faketerm-device-raw-depth device)))
    (is (= 1 (faketerm-device-close-count device)))))

(defun %make-race-device ()
  (let ((entered (sb-thread:make-semaphore :count 0)))
    (values
     (make-device
      :faketerm :eof-on-empty-p nil
      :wait-function
      (lambda (_dev timeout-ms)
        (declare (ignore _dev))
        (sb-thread:signal-semaphore entered)
        (sleep (/ timeout-ms 1000d0))
        nil))
     entered)))

(test source-read-vs-close-unstrands-reader
  (multiple-value-bind (device entered) (%make-race-device)
    (let* ((source (make-input-source :device device))
           (reader-result :unset)
           (reader (bt:make-thread (lambda ()
                                     (setf reader-result (next-token source))))))
      (is-true (sb-thread:wait-on-semaphore entered :timeout 1d0))
      (is-true (close-input-source source))
      (bt:join-thread reader)
      (is (null reader-result))
      (is (eq :closed (input-source-state source)))
      (is (= 1 (faketerm-device-close-count device))))))

(test source-read-vs-cancel-unstrands-reader
  (multiple-value-bind (device entered) (%make-race-device)
    (let* ((source (make-input-source :device device))
           (reader-result :unset)
           (reader (bt:make-thread (lambda ()
                                     (setf reader-result (next-token source))))))
      (is-true (sb-thread:wait-on-semaphore entered :timeout 1d0))
      (is-true (cancel-input-source source))
      (bt:join-thread reader)
      (is (null reader-result))
      (is (eq :cancelled (input-source-state source)))
      (is (= 1 (faketerm-device-close-count device))))))

(test source-close-vs-close-cleans-once
  (let* ((device (make-device :faketerm))
         (source (make-input-source :device device))
         (threads (loop repeat 2
                        collect (bt:make-thread
                                 (lambda () (close-input-source source))))))
    (dolist (thread threads) (bt:join-thread thread))
    (is (eq :closed (input-source-state source)))
    (is (= 1 (faketerm-device-close-count device)))))

(test source-cancel-vs-cancel-cleans-once
  (let* ((device (make-device :faketerm))
         (source (make-input-source :device device))
         (threads (loop repeat 2
                        collect (bt:make-thread
                                 (lambda () (cancel-input-source source))))))
    (dolist (thread threads) (bt:join-thread thread))
    (is (eq :cancelled (input-source-state source)))
    (is (= 1 (faketerm-device-close-count device)))))

(test source-query-matches-response-without-stealing-interleaved-user-input
  (let* ((bytes (string-to-utf-8-bytes
                 (concatenate 'string "u" (string #\Esc) "[7;8R")))
         (device (make-device :faketerm :script (list bytes)))
         (source (make-input-source :device device)))
    (unwind-protect
         (let* ((correlation (send-terminal-query source :cursor-position :timeout 1d0))
                (response (wait-terminal-response source correlation :timeout 1d0)))
           (is (eq :matched (response-correlation-state correlation)))
           (is (eq :cursor-position (response-correlation-response-type correlation)))
           (is (eq :terminal-response (input-token-kind response)))
           (is (= 7 (getf (input-token-data response) :row)))
           (is (= 8 (getf (input-token-data response) :column)))
           (is (equal '(27 91 54 110)
                      (coerce (first (faketerm-captured device)) 'list)))
           (let ((user-token (next-token source :timeout 0)))
             (is (eq :key (input-token-kind user-token)))
             (is (char= #\u (getf (input-token-data user-token) :code)))))
      (close-input-source source))))

(test source-unmatched-response-is-retained-not-delivered-as-input
  (let* ((bytes (string-to-utf-8-bytes
                 (concatenate 'string (string #\Esc) "[0nx")))
         (device (make-device :faketerm :script (list bytes)))
         (source (make-input-source :device device)))
    (unwind-protect
         (progn
           (let ((user-token (next-token source :timeout 1d0)))
             (is (eq :key (input-token-kind user-token)))
             (is (char= #\x (getf (input-token-data user-token) :code))))
           (let ((response (take-unmatched-terminal-response source)))
             (is (eq :terminal-response (input-token-kind response)))
             (is (eq :device-status
                     (getf (input-token-data response) :response-type)))
             (is (= 0 (getf (input-token-data response) :status)))))
      (close-input-source source))))

(test source-expired-correlation-rejects-late-response
  (let ((now 30d0))
    (flet ((clock () now))
      (let* ((bytes (string-to-utf-8-bytes
                     (concatenate 'string (string #\Esc) "[2;3Rz")))
             (device (make-device :faketerm :script (list bytes)))
             (source (make-input-source :device device :clock #'clock))
             (correlation (expect-terminal-response
                           source :cursor-position :timeout 0.1d0)))
        (unwind-protect
             (progn
               (setf now 30.1d0)
               (let ((user-token (next-token source :timeout 0)))
                 (is (eq :key (input-token-kind user-token)))
                 (is (char= #\z (getf (input-token-data user-token) :code))))
               (is (eq :expired (response-correlation-state correlation :now now)))
               (let ((late (take-unmatched-terminal-response source)))
                 (is (eq :terminal-response (input-token-kind late)))
                 (is (eq :cursor-position
                         (getf (input-token-data late) :response-type)))))
          (close-input-source source))))))

(test source-malformed-response-recovers-to-user-input-and-diagnostic
  (let* ((bytes (string-to-utf-8-bytes
                 (concatenate 'string (string #\Esc) "[12;Rq")))
         (device (make-device :faketerm :script (list bytes)))
         (source (make-input-source :device device)))
    (unwind-protect
         (progn
           (let ((user-token (next-token source :timeout 1d0)))
             (is (eq :key (input-token-kind user-token)))
             (is (char= #\q (getf (input-token-data user-token) :code))))
           (let ((diagnostic (take-input-protocol-diagnostic source)))
             (is (eq :protocol (input-token-kind diagnostic)))
             (is (eq :unknown-sequence
                     (getf (input-token-data diagnostic) :category)))))
      (close-input-source source))))

(test source-capability-query-response-is-correlated
  (let* ((bytes (string-to-utf-8-bytes
                 (concatenate 'string (string #\Esc) "[?1;2c")))
         (device (make-device :faketerm :script (list bytes)))
         (source (make-input-source :device device)))
    (unwind-protect
         (let* ((correlation
                  (send-terminal-query source :primary-device-attributes :timeout 1d0))
                (response (wait-terminal-response source correlation :timeout 1d0)))
           (is (eq :matched (response-correlation-state correlation)))
           (is (eq :primary-device-attributes
                   (getf (input-token-data response) :response-type)))
           (is (equal '(1 2) (getf (input-token-data response) :attributes))))
      (close-input-source source))))

(test source-query-short-write-cancels-stale-correlation
  (let ((write-count 0))
    (let* ((device
             (make-device
              :faketerm :eof-on-empty-p nil
              :write-function
              (lambda (_dev _buffer start end)
                (declare (ignore _dev _buffer))
                (incf write-count)
                (if (= write-count 1)
                    (max 0 (1- (- end start)))
                    (- end start)))))
           (source (make-input-source :device device)))
      (unwind-protect
           (progn
             (signals error
               (send-terminal-query source :cursor-position :timeout 1d0))
             (let ((correlation
                     (send-terminal-query source :cursor-position :timeout 1d0)))
               (faketerm-inject!
                device
                (string-to-utf-8-bytes
                 (concatenate 'string (string #\Esc) "[4;5R")))
               (let ((response
                       (wait-terminal-response source correlation :timeout 1d0)))
                 (is (eq :matched (response-correlation-state correlation)))
                 (is (= 4 (getf (input-token-data response) :row)))
                 (is (= 5 (getf (input-token-data response) :column))))))
        (close-input-source source)))))

(test source-query-write-error-cancels-stale-correlation
  (let ((write-count 0))
    (let* ((device
             (make-device
              :faketerm :eof-on-empty-p nil
              :write-function
              (lambda (_dev _buffer start end)
                (declare (ignore _dev _buffer))
                (incf write-count)
                (if (= write-count 1)
                    (error "Injected query write failure.")
                    (- end start)))))
           (source (make-input-source :device device)))
      (unwind-protect
           (progn
             (signals error
               (send-terminal-query source :device-status :timeout 1d0))
             (let ((correlation
                     (send-terminal-query source :device-status :timeout 1d0)))
               (faketerm-inject!
                device
                (string-to-utf-8-bytes
                 (concatenate 'string (string #\Esc) "[0n")))
               (let ((response
                       (wait-terminal-response source correlation :timeout 1d0)))
                 (is (eq :matched (response-correlation-state correlation)))
                 (is (= 0 (getf (input-token-data response) :status))))))
        (close-input-source source)))))

(test source-close-while-waiting-cancels-response-correlation
  (multiple-value-bind (device entered) (%make-race-device)
    (let* ((source (make-input-source :device device))
           (correlation (expect-terminal-response
                         source :cursor-position :timeout 5d0))
           (wait-result :unset)
           (waiter
             (bt:make-thread
              (lambda ()
                (setf wait-result
                      (wait-terminal-response source correlation))))))
      (is-true (sb-thread:wait-on-semaphore entered :timeout 1d0))
      (is-true (close-input-source source))
      (bt:join-thread waiter)
      (is (null wait-result))
      (is (eq :cancelled (response-correlation-state correlation)))
      (is (eq :closed (input-source-state source))))))

(test source-cancel-while-waiting-cancels-response-correlation
  (multiple-value-bind (device entered) (%make-race-device)
    (let* ((source (make-input-source :device device))
           (correlation (expect-terminal-response
                         source :cursor-position :timeout 5d0))
           (wait-result :unset)
           (waiter
             (bt:make-thread
              (lambda ()
                (setf wait-result
                      (wait-terminal-response source correlation))))))
      (is-true (sb-thread:wait-on-semaphore entered :timeout 1d0))
      (is-true (cancel-input-source source))
      (bt:join-thread waiter)
      (is (null wait-result))
      (is (eq :cancelled (response-correlation-state correlation)))
      (is (eq :cancelled (input-source-state source))))))
