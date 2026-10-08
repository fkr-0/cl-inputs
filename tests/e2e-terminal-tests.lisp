;;;; End-to-end contracts exercised through the public input-source/device boundary.
;;;; These tests intentionally do not call the decoder directly.
(uiop:define-package :cl-inputs.tests.terminal-e2e
  (:use :cl :fiveam)
  (:export #:terminal-e2e-tests))
(in-package :cl-inputs.tests.terminal-e2e)

(def-suite terminal-e2e-tests
  :description "Terminal byte-stream -> source -> token + output/lifecycle E2E"
  :in :cl-inputs)
(in-suite terminal-e2e-tests)

(defun %octets (&rest bytes)
  (make-array (length bytes) :element-type '(unsigned-byte 8)
              :initial-contents bytes))

(defun %utf8 (string)
  (cl-inputs.util:string-to-utf-8-bytes string))

(defun %join (&rest chunks)
  (let ((out (make-array (reduce #'+ chunks :key #'length :initial-value 0)
                         :element-type '(unsigned-byte 8)))
        (offset 0))
    (dolist (chunk chunks out)
      (replace out chunk :start1 offset)
      (incf offset (length chunk)))))

(defun %esc (suffix)
  (%utf8 (concatenate 'string (string #\Esc) suffix)))

(defun %signature (token)
  (let ((data (cl-inputs.tokens:input-token-data token)))
    (case (cl-inputs.tokens:input-token-kind token)
      (:key (list :key (getf data :code) (getf data :mods)))
      (:focus (list :focus (getf data :gained)))
      (:mouse (list :mouse (getf data :type) (getf data :x)
                    (getf data :y) (getf data :button) (getf data :mods)))
      (:paste (list :paste (getf data :content)
                    (getf data :valid-utf8-p)))
      (otherwise (list (cl-inputs.tokens:input-token-kind token) data)))))

(defun %drain-source (source &key (limit 128))
  "Pull through EOF; hard-cap tokens to expose accidental infinite delivery."
  (loop repeat limit
        for token = (cl-inputs.loop:next-token source :timeout 0.3d0)
        while token collect token))

(defun %script-signatures (pieces &key decoder)
  (let* ((dev (cl-inputs.device.api:make-device :faketerm :script pieces))
         (src (cl-inputs.loop:make-input-source :device dev :decoder decoder)))
    (unwind-protect
         (mapcar #'%signature (%drain-source src))
      (cl-inputs.loop:close-input-source src))))

(defun %mixed-stream ()
  (%join (%utf8 "x")
         (%utf8 (string (code-char #x03bb)))
         (%esc "[A")
         (%esc "[<0;3;4M")
         (%esc "[I")
         (%esc "[O")
         (%esc "[200~")
         (%utf8 (format nil "hello~%~A" (code-char #x03bb)))
         (%esc "[201~")
         (%utf8 "z")))

(defun %expected-mixed ()
  (list (list :key #\x nil)
        (list :key (code-char #x03bb) nil)
        (list :key :up nil)
        (list :mouse :mouse-down 2 3 0 nil)
        (list :focus t)
        (list :focus nil)
        (list :paste (format nil "hello~%~A" (code-char #x03bb)) t)
        (list :key #\z nil)))

(test mixed-terminal-input-through-owned-source
  (let* ((dev (cl-inputs.device.api:make-device :faketerm
                    :script (list (%mixed-stream))))
         (src (cl-inputs.loop:make-input-source :device dev)))
    (unwind-protect
         (progn
           (is (equal (%expected-mixed)
                      (mapcar #'%signature (%drain-source src))))
           (is (eq :eof (cl-inputs.loop:input-source-state src)))
           (is (eq :eof (cl-inputs.loop:input-source-terminal-outcome src))))
      (cl-inputs.loop:close-input-source src))
    (is (= 0 (cl-inputs.device.faketerm:faketerm-device-raw-depth dev)))
    (is (= 1 (cl-inputs.device.faketerm:faketerm-device-close-count dev)))))

(test mixed-terminal-input-at-every-two-chunk-boundary
  "Every possible split, including inside UTF-8 and CSI/paste delimiters."
  (let ((stream (%mixed-stream)) (expected (%expected-mixed)))
    (loop for split from 1 below (length stream) do
      (is (equal expected
                 (%script-signatures
                   (list (subseq stream 0 split)
                         (subseq stream split))))
          "Unexpected split at byte ~D" split))))

(test mixed-terminal-input-byte-by-byte
  (let ((stream (%mixed-stream)))
    (is (equal (%expected-mixed)
               (%script-signatures
                 (loop for byte across stream collect (%octets byte)))))))

(test interrupted-and-would-block-read-recover-across-escape
  (let ((script (list (%octets 27) :interrupted :would-block
                      (%utf8 "[C") (%utf8 "q"))))
    (is (equal '((:key :right nil) (:key #\q nil))
               (%script-signatures script)))))

(test eof-flushes-truncated-escape-to-diagnostic-without-user-key
  (let* ((dev (cl-inputs.device.api:make-device
                :faketerm :script (list (%octets 27 91 49 59))))
         (src (cl-inputs.loop:make-input-source :device dev)))
    (unwind-protect
         (progn
           (is (null (cl-inputs.loop:next-token src :timeout 0.3d0)))
           (let ((diag (cl-inputs.loop:take-input-protocol-diagnostic src)))
             (is (eq :protocol (cl-inputs.tokens:input-token-kind diag)))
             (is (eq :truncated-sequence
                     (getf (cl-inputs.tokens:input-token-data diag) :reason))))
           (is (null (cl-inputs.loop:take-input-protocol-diagnostic src)))
           (is (eq :eof (cl-inputs.loop:input-source-state src))))
      (cl-inputs.loop:close-input-source src))))

(test bounded-paste-overflow-recovers-and-does-not-expose-content
  (let* ((dev (cl-inputs.device.api:make-device
                :faketerm
                :script (list (%join (%esc "[200~") (%utf8 "SECRET-PAYLOAD")
                                     (%esc "[201~") (%utf8 "a")))))
         (decoder (cl-inputs.decoder:make-decoder
                   :max-paste-bytes 4 :max-buffer-bytes 128))
         (src (cl-inputs.loop:make-input-source :device dev :decoder decoder)))
    (unwind-protect
         (progn
           (is (equal '((:key #\a nil))
                      (mapcar #'%signature (%drain-source src))))
           (let* ((diag (cl-inputs.loop:take-input-protocol-diagnostic src))
                  (data (and diag (cl-inputs.tokens:input-token-data diag))))
             (is (eq :protocol (cl-inputs.tokens:input-token-kind diag)))
             (is (eq :overflow (getf data :category)))
             (is (eq :paste-too-long (getf data :reason)))
             (is (null (getf data :raw)))
             (is (null (getf data :content)))))
      (cl-inputs.loop:close-input-source src))))

(test query-reply-interleaving-retains-user-order-and-unmatched-replies
  (let* ((input (%join (%utf8 "a") (%esc "[0n") (%esc "[7;19R")
                       (%esc "[?1;2c") (%utf8 "b")))
         (dev (cl-inputs.device.api:make-device :faketerm :script (list input)))
         (src (cl-inputs.loop:make-input-source :device dev)))
    (unwind-protect
         (let* ((correlation (cl-inputs.loop:send-terminal-query
                              src :cursor-position :timeout 1d0))
                (response (cl-inputs.loop:wait-terminal-response
                           src correlation :timeout 1d0)))
           (is (eq :matched
                   (cl-inputs.routing:response-correlation-state correlation)))
           (is (eq :terminal-response
                   (cl-inputs.tokens:input-token-kind response)))
           (is (= 7 (getf (cl-inputs.tokens:input-token-data response) :row)))
           (is (= 19 (getf (cl-inputs.tokens:input-token-data response) :column)))
           (is (equal '((:key #\a nil) (:key #\b nil))
                      (mapcar #'%signature (%drain-source src))))
           (let ((first (cl-inputs.loop:take-unmatched-terminal-response src))
                 (second (cl-inputs.loop:take-unmatched-terminal-response src)))
             (is (eq :device-status
                     (getf (cl-inputs.tokens:input-token-data first) :response-type)))
             (is (eq :primary-device-attributes
                     (getf (cl-inputs.tokens:input-token-data second) :response-type)))
             (is (null (cl-inputs.loop:take-unmatched-terminal-response src))))
           (is (equal '(27 91 54 110)
                      (coerce (first
                               (cl-inputs.device.faketerm:faketerm-captured dev))
                              'list))))
      (cl-inputs.loop:close-input-source src))))

(test borrowed-source-does-not-alter-device-lifetime
  (let* ((dev (cl-inputs.device.api:make-device
               :faketerm :script (list (%utf8 "b")))))
    (cl-inputs.device.api:open-device dev)
    (cl-inputs.device.api:enable-raw-char-mode dev)
    (cl-inputs.device.api:device-set-nonblocking dev t)
    (unwind-protect
         (let ((src (cl-inputs.loop:make-input-source
                     :device dev :owns-device-p nil)))
           (is-false (cl-inputs.loop:input-source-owns-device-p src))
           (is (equal '((:key #\b nil))
                      (mapcar #'%signature (%drain-source src))))
           (cl-inputs.loop:close-input-source src)
           (is-true (cl-inputs.device.faketerm:faketerm-device-open-p dev))
           (is (= 1 (cl-inputs.device.faketerm:faketerm-device-raw-depth dev)))
           (is (= 0 (cl-inputs.device.faketerm:faketerm-device-close-count dev))))
      (cl-inputs.device.api:disable-raw-char-mode dev)
      (cl-inputs.device.api:close-device dev))
    (is (= 1 (cl-inputs.device.faketerm:faketerm-device-close-count dev)))))

(test public-scoped-api-restores-on-normal-and-exceptional-exit
  (dolist (fail '(nil t))
    (let ((dev (cl-inputs.device.api:make-device :faketerm)))
      (handler-case
          (cl-inputs.api:with-input-source (src :device dev)
            (is (eq :open (cl-inputs.loop:input-source-state src)))
            (is (= 1 (cl-inputs.device.faketerm:faketerm-device-raw-depth dev)))
            (when fail (error "Injected scoped body failure")))
        (error (condition)
          (unless (and fail (search "Injected scoped" (princ-to-string condition)))
            (error condition))))
      (is (= 0 (cl-inputs.device.faketerm:faketerm-device-raw-depth dev)))
      (is (= 1 (cl-inputs.device.faketerm:faketerm-device-close-count dev))))))

(test with-raw-input-unwinds-and-raw-activation-failure-closes
  (dolist (fail '(nil t))
    (let ((dev (cl-inputs.device.api:make-device :faketerm)))
      (handler-case
          (cl-inputs.api:with-raw-input (dev)
            (is (= 1 (cl-inputs.device.faketerm:faketerm-device-raw-depth dev)))
            (when fail (error "Injected raw body failure")))
        (error (condition)
          (unless (and fail (search "Injected raw" (princ-to-string condition)))
            (error condition))))
      (is (= 0 (cl-inputs.device.faketerm:faketerm-device-raw-depth dev)))
      (is (= 1 (cl-inputs.device.faketerm:faketerm-device-close-count dev)))))
  (let ((dev (cl-inputs.device.api:make-device :faketerm :fail-on-raw-p t)))
    (signals error (cl-inputs.api:with-raw-input (dev) (error "Unreachable")))
    (is (= 1 (cl-inputs.device.faketerm:faketerm-device-close-count dev)))))

(test async-input-loop-delivers-in-order-and-releases-device
  (let* ((dev (cl-inputs.device.api:make-device
                :faketerm :script (list (%utf8 "a") (%esc "[D") (%utf8 "b"))))
         (seen '())
         (loop (cl-inputs.loop:start-input-loop
                :device dev :mode :async :sink (lambda (token)
                                                (push (%signature token) seen))))
         (thread (cl-inputs.loop::input-loop-thread loop)))
    (unwind-protect
         (progn
           (is (not (eq :timed-out
                        (sb-thread:join-thread thread :timeout 3
                                               :default :timed-out))))
           (is (not (sb-thread:thread-alive-p thread))))
      (cl-inputs.loop:stop-input-loop loop))
    (is (equal '((:key #\a nil) (:key :left nil) (:key #\b nil))
               (reverse seen)))
    (is (= 1 (cl-inputs.device.faketerm:faketerm-device-close-count dev)))))

(test faketerm-output-screen-composition-and-clipping
  (let ((dev (cl-inputs.device.api:make-device :faketerm :width 6 :height 3)))
    (cl-inputs.terminal.api:draw-text-at dev 0 0 "abcdefXYZ")
    (cl-inputs.terminal.api:fill-rectangle dev 1 1 2 3 :char #\#)
    (cl-inputs.terminal.api:draw-char-at dev 2 5 #\Z)
    (is (equal '("abcdef" " ###" " ### Z")
               (cl-inputs.device.faketerm:faketerm-screen-lines dev)))
    (cl-inputs.terminal.api:scroll-lines dev 1)
    (is (equal '(" ###" " ### Z" "")
               (cl-inputs.device.faketerm:faketerm-screen-lines dev)))
    (cl-inputs.terminal.api:clear-screen dev)
    (is (equal '("" "" "")
               (cl-inputs.device.faketerm:faketerm-screen-lines dev)))))
