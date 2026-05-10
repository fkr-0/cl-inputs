(defpackage :cl-inputs.tests
  (:use :cl :fiveam :cl-inputs.api :cl-inputs.util :cl-inputs.loop)
  (:import-from :bordeaux-threads #:recursive-lock-p)
  (:import-from :cl-inputs.sink
                #:fn-sink #:tee-sink
                #:accept-token #:on-key #:on-mouse #:on-resize
                #:on-paste #:on-focus #:on-ctrl-c)
  (:import-from :cl-inputs.terminal.ansii
                #:introducer-key #:is-csi-final-byte?
                #:get-sequence #:render-seq
                #:parse-sgr-parameters
                #:ansi-fg-color-seq #:ansi-bg-color-seq #:ansi-attr-seq
                #:parse-csi-sequence)
  (:import-from :cl-inputs.terminal.api
                #:%emit-ansi #:%style->sgr-string #:+esc+
                #:clear-screen #:clear-area #:draw-text-at #:draw-char-at
                #:fill-rectangle #:scroll-lines #:set-cursor-position
                #:get-cursor-position #:hide-cursor #:show-cursor
                #:flush-output #:apply-style #:reset-style)
  (:import-from :cl-inputs.device.api
                #:make-device #:device-kind #:open-device #:close-device
                #:enable-raw-mode #:disable-raw-mode
                #:device-read-bytes #:device-write-bytes
                #:device-input-stream #:device-output-stream #:device-fd
                #:device-capabilities #:device-set-modes
                #:device-error #:raw-mode-error
                #:lockable #:lock-of #:acquire-lock #:release-lock)
  (:export #:run-all-cl-inputs-tests
    #:cl-inputs-test))

(in-package :cl-inputs.tests)

(defmacro with-faketerm ((var &key (width 8) (height 4)) &body body)
  `(let ((,var (cl-inputs.device.api:make-device :faketerm :width ,width :height ,height)))
     (unwind-protect
       (progn ,@body)
       (ignore-errors (cl-inputs.device.api:close-device ,var)))))

(defmacro faketerm-assert-screen (device &rest rows)
  `(is (equal ',rows (cl-inputs.device.faketerm:faketerm-screen-lines ,device))))

(defun ansi-bytes (suffix)
  "Build a byte vector for ESC + SUFFIX."
  (string-to-utf-8-bytes
    (concatenate 'string (string (code-char 27)) suffix)))

(def-suite cl-inputs-test
  :description "Tests for the cl-inputs library.")

(in-suite cl-inputs-test)

(test smoke-test
  (is-true (fboundp 'cl-inputs:start-input-loop)
    "start-input-loop should be a function.")
  (is-true (fboundp 'cl-inputs.loop:make-input-source)
    "make-input-source should be a function."))

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
    (let* ((bytes (ansi-bytes "[A")) ; Up
            (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
      (is (= 1 (length tokens)))
      (is (eq :up (getf (cl-inputs.tokens:input-token-data (first tokens)) :code))))
    (let* ((bytes (ansi-bytes "[B")) ; Down
            (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
      (is (= 1 (length tokens)))
      (is (eq :down (getf (cl-inputs.tokens:input-token-data (first tokens)) :code))))))

(test decode-mouse-event
  (let* ((decoder (cl-inputs.decoder:make-decoder))
          ;; SGR mouse press: ESC [ < 0 ; 10 ; 20 M
          ;; cb=0 = plain button-1 press in the common SGR mouse encoding.
          ;; Terminal coordinates are 1-based; many decoders normalize to 0-based.
          (bytes (ansi-bytes "[<0;10;20M"))
          (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
    (is (= 1 (length tokens)) "Should decode one mouse token.")
    (let ((token (first tokens))
           (token-data (cl-inputs.tokens:input-token-data (first tokens))))
      (is (eq :mouse (cl-inputs.tokens:input-token-kind token)))
      (is (eq :mouse-down (getf token-data :type)))
      ;; keep these expectations only if your decoder normalizes from terminal
      ;; 1-based positions to internal 0-based positions.
      (is (= 9 (getf token-data :x)))
      (is (= 19 (getf token-data :y))))))

(test faketerm-backend-read
  (let* ((dev (cl-inputs.device.api:make-device :faketerm
                :script (list (string-to-utf-8-bytes "a"))))
          (src (make-input-source :device dev))
          (token (next-token src)))
    (is (eql #\a (getf (cl-inputs.tokens:input-token-data token) :code)))
    (close-input-source src)))

(test faketerm-inject-and-read
  (let* ((dev (cl-inputs.device.api:make-device :faketerm))
          (src (make-input-source :device dev)))
    (cl-inputs.device.faketerm::faketerm-inject! dev (string-to-utf-8-bytes "b"))
    (let ((token (next-token src)))
      (is (eql #\b (getf (cl-inputs.tokens:input-token-data token) :code))))
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
          (part-1 (ansi-bytes "[<0;10;"))
          (tokens-1 (nth-value 0 (cl-inputs.decoder:decode-chunk decoder part-1)))
          (new-dec (nth-value 1 (cl-inputs.decoder:decode-chunk decoder part-1))))
    ;; Incomplete sequence should not emit anything yet.
    (is (null tokens-1) "Should not emit tokens for incomplete sequences.")

    ;; Finish the previously buffered sequence and verify behavior instead of
    ;; reaching into decoder internals.
    (let* ((part-2 (string-to-utf-8-bytes "20M"))
            (tokens-2 (nth-value 0 (cl-inputs.decoder:decode-chunk new-dec part-2))))
      (is (= 1 (length tokens-2)) "Completed sequence should now emit one token.")
      (let ((token-data (cl-inputs.tokens:input-token-data (first tokens-2))))
        (is (eq :mouse-down (getf token-data :type)))
        (is (= 9 (getf token-data :x)))
        (is (= 19 (getf token-data :y)))))))

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
                (buffer (make-array 16 :element-type '(unsigned-byte 8)
                          :initial-element 0))
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
          (is (= 0 (cl-inputs.device.tty::%tty-read-into-buffer
                     read-fd buffer 0 1 nil))))
        (close-fd read-fd)
        (close-fd write-fd)))))

(test decode-function-keys
  "Test decoding function keys F5-F12"
  (let ((decoder (cl-inputs.decoder:make-decoder)))
    ;; F5: ESC [ 1 5 ~
    (let* ((bytes (ansi-bytes "[15~"))
           (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
      (is (= 1 (length tokens)))
      (is (eq :f5 (getf (cl-inputs.tokens:input-token-data (first tokens)) :code))))
    ;; F10: ESC [ 2 1 ~
    (let* ((bytes (ansi-bytes "[21~"))
           (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
      (is (= 1 (length tokens)))
      (is (eq :f10 (getf (cl-inputs.tokens:input-token-data (first tokens)) :code))))
    ;; F11: ESC [ 2 3 ~
    (let* ((bytes (ansi-bytes "[23~"))
           (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
      (is (= 1 (length tokens)))
      (is (eq :f11 (getf (cl-inputs.tokens:input-token-data (first tokens)) :code))))))

(test decode-mouse-drag-event
  "Test decoding SGR mouse drag event"
  (let* ((decoder (cl-inputs.decoder:make-decoder))
         ;; SGR mouse drag: ESC [ < 0 ; 15 ; 25 M (drag with button 1)
         (bytes (ansi-bytes "[<0;15;25M"))
         (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
    (is (= 1 (length tokens)) "Should decode one mouse token.")
    (let ((token-data (cl-inputs.tokens:input-token-data (first tokens))))
      (is (eq :mouse-down (getf token-data :type)))
      (is (= 14 (getf token-data :x)))     ; 15 - 1
      (is (= 24 (getf token-data :y))))))  ; 25 - 1

(test decode-mouse-release-event
  "Test decoding SGR mouse release event"
  (let* ((decoder (cl-inputs.decoder:make-decoder))
         ;; SGR mouse release: ESC [ < 0 ; 30 ; 40 m (lowercase m for release)
         (bytes (ansi-bytes "[<0;30;40m"))
         (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
    (is (= 1 (length tokens)) "Should decode one mouse token.")
    (let ((token-data (cl-inputs.tokens:input-token-data (first tokens))))
      (is (eq :mouse-up (getf token-data :type)))
      (is (= 29 (getf token-data :x)))     ; 30 - 1
      (is (= 39 (getf token-data :y))))))  ; 40 - 1

(test decode-delete-key
  "Test decoding Delete key"
  (let* ((decoder (cl-inputs.decoder:make-decoder))
         (bytes (ansi-bytes "[3~"))
         (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
    (is (= 1 (length tokens)))
    (is (eq :delete (getf (cl-inputs.tokens:input-token-data (first tokens)) :code)))))

(test decode-home-end-keys
  "Test decoding Home and End keys"
  (let ((decoder (cl-inputs.decoder:make-decoder)))
    ;; Home: ESC [ 1 ~ or ESC [ H
    (let* ((bytes (ansi-bytes "[1~"))
           (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
      (is (= 1 (length tokens)))
      (is (eq :home (getf (cl-inputs.tokens:input-token-data (first tokens)) :code))))
    ;; End: ESC [ 4 ~ or ESC [ F
    (let* ((bytes (ansi-bytes "[4~"))
           (tokens (nth-value 0 (cl-inputs.decoder:decode-chunk decoder bytes))))
      (is (= 1 (length tokens)))
      (is (eq :end (getf (cl-inputs.tokens:input-token-data (first tokens)) :code))))))

(test adapter-key-event
  "Test token->normalized-event for key events"
  (let* ((token (cl-inputs.tokens:make-token :key '(:code :a :mods (:shift))))
         (event (cl-inputs.adapters:token->normalized-event token)))
    (is (not (null event)))
    (is (eq :key-event (getf event :type)))
    (is (eq :a (getf event :key))))
  ;; Test with character key
  (let* ((token (cl-inputs.tokens:make-token :key '(:code #\x)))
         (event (cl-inputs.adapters:token->normalized-event token)))
    (is (not (null event)))
    (is (eq :key-event (getf event :type)))
    (is (eql #\x (getf event :char)))))

(test adapter-mouse-event
  "Test token->normalized-event for mouse events"
  (let* ((token (cl-inputs.tokens:make-token :mouse '(:type :click :button 0 :x 5 :y 10 :mods nil)))
         (event (cl-inputs.adapters:token->normalized-event token)))
    (is (not (null event)))
    (is (eq :mouse-event (getf event :type)))
    (is (= 5 (getf event :x)))
    (is (= 10 (getf event :y)))))

(test adapter-resize-event
  "Test token->normalized-event for resize events"
  (let* ((token (cl-inputs.tokens:make-token :resize '(:width 80 :height 24)))
         (event (cl-inputs.adapters:token->normalized-event token)))
    (is (not (null event)))
    (is (eq :terminal-resized (getf event :type)))
    (is (= 80 (getf event :width)))
    (is (= 24 (getf event :height)))))

(test adapter-unknown-event
  "Test token->normalized-event for unknown event types returns NIL"
  (let* ((token (cl-inputs.tokens:make-token :focus '(:gained t)))
         (event (cl-inputs.adapters:token->normalized-event token)))
    (is (null event))))

(test keymap-canonicalize
  "Test keymap canonicalize-key function"
  (is (eq :A (cl-inputs.keymap:canonicalize-key #\a)))
  (is (eq :Z (cl-inputs.keymap:canonicalize-key #\z)))
  ;; Test with control modifier - only actual control chars (code 1-26) get C-X format
  ;; Control-A is character code 1, which becomes "A" when 64+1=65
  (is (eq :C-A (cl-inputs.keymap:canonicalize-key (code-char 1) :ctrl t)))
  (is (eq :C-Z (cl-inputs.keymap:canonicalize-key (code-char 26) :ctrl t))))

;; ==================== Sink Tests ====================
(test sink-fn-sink-basic
  "Test function sink captures tokens"
  (let* ((captured nil)
         (sink (cl-inputs.sink:fn-sink (lambda (tok) (setf captured tok))))
         (token (cl-inputs.tokens:make-token :key '(:code :x))))
    (funcall sink token)
    (is (not (null captured)))
    (is (eq :key (cl-inputs.tokens:input-token-kind captured)))))

(test sink-fn-sink-counter
  "Test function sink counts tokens"
  (let* ((count 0)
         (sink (cl-inputs.sink:fn-sink (lambda (tok) (declare (ignore tok)) (incf count))))
         (token1 (cl-inputs.tokens:make-token :key '(:code :a)))
         (token2 (cl-inputs.tokens:make-token :key '(:code :b))))
    (funcall sink token1)
    (is (= 1 count))
    (funcall sink token2)
    (is (= 2 count))))

(test sink-tee-sink-basic
  "Test tee sink distributes to multiple sinks"
  (let* ((results '())
         (sink1 (cl-inputs.sink:fn-sink (lambda (tok) (declare (ignore tok)) (push :s1 results))))
         (sink2 (cl-inputs.sink:fn-sink (lambda (tok) (declare (ignore tok)) (push :s2 results))))
         (tee (cl-inputs.sink:tee-sink sink1 sink2))
         (token (cl-inputs.tokens:make-token :mouse '(:type :click))))
    (funcall tee token)
    (is (= 2 (length results)))
    (is (member :s1 results))
    (is (member :s2 results))))

(test sink-default-methods-no-op
  "Test default sink methods return NIL"
  (let* ((sink "any-object")
         (key-token (cl-inputs.tokens:make-token :key '(:code :a)))
         (mouse-token (cl-inputs.tokens:make-token :mouse '(:type :click)))
         (resize-token (cl-inputs.tokens:make-token :resize '(:width 80)))
         (paste-token (cl-inputs.tokens:make-token :paste '(:content "x")))
         (focus-token (cl-inputs.tokens:make-token :focus '(:gained t))))
    (is (null (cl-inputs.sink:accept-token sink key-token)))
    (is (null (cl-inputs.sink:on-key sink key-token)))
    (is (null (cl-inputs.sink:on-mouse sink mouse-token)))
    (is (null (cl-inputs.sink:on-resize sink resize-token)))
    (is (null (cl-inputs.sink:on-paste sink paste-token)))
    (is (null (cl-inputs.sink:on-focus sink focus-token)))))

;; ==================== ANSI Tests ====================
(test ansii-introducer-key
  "Test introducer-key function"
  ;; CSI introducer is '[' (char-code 91)
  (is (eq :csi (cl-inputs.terminal.ansii:introducer-key 91)))
  ;; SS3 introducer is 'O' (char-code 79)
  (is (eq :ss3 (cl-inputs.terminal.ansii:introducer-key 79)))
  ;; Unknown introducer
  (is (null (cl-inputs.terminal.ansii:introducer-key 255))))

(test ansii-is-csi-final-byte
  "Test is-csi-final-byte? function"
  ;; CSI final bytes are in range 64-126
  (is-true (cl-inputs.terminal.ansii:is-csi-final-byte? 65))  ; 'A'
  (is-true (cl-inputs.terminal.ansii:is-csi-final-byte? 126)) ; '~'
  (is-false (cl-inputs.terminal.ansii:is-csi-final-byte? 63)) ; '?'
  (is-false (cl-inputs.terminal.ansii:is-csi-final-byte? 127)))

(test ansii-get-sequence
  "Test get-sequence function"
  ;; Test fetching known sequences
  (is-true (cl-inputs.terminal.ansii:get-sequence :reset))
  (is-true (cl-inputs.terminal.ansii:get-sequence :bold))
  (is-true (cl-inputs.terminal.ansii:get-sequence :fg-red))
  (is-true (cl-inputs.terminal.ansii:get-sequence :bg-blue))
  ;; Unknown sequence
  (is (null (cl-inputs.terminal.ansii:get-sequence :unknown-seq))))

(test ansii-render-seq
  "Test render-seq function"
  ;; Render simple sequences (no arguments)
  (let* ((reset-seq (cl-inputs.terminal.ansii:get-sequence :reset))
         (rendered (cl-inputs.terminal.ansii:render-seq reset-seq)))
    (is (stringp rendered))
    (is (= 4 (length rendered))))  ; ESC [ 0 m
  ;; Render sequence with arguments
  (let* ((cursor-seq (cl-inputs.terminal.ansii:get-sequence :cursor-up))
         (rendered (cl-inputs.terminal.ansii:render-seq cursor-seq 5)))
    (is (stringp rendered))))

(test ansii-parse-sgr-parameters
  "Test parse-sgr-parameters function"
  ;; Reset
  (let ((result (cl-inputs.terminal.ansii:parse-sgr-parameters '(0))))
    (is (equal '((:reset t)) result)))
  ;; Bold
  (let ((result (cl-inputs.terminal.ansii:parse-sgr-parameters '(1))))
    (is (equal '((:bold t)) result)))
  ;; Foreground red
  (let ((result (cl-inputs.terminal.ansii:parse-sgr-parameters '(31))))
    (is (equal '((:fg-color :red)) result)))
  ;; Background blue
  (let ((result (cl-inputs.terminal.ansii:parse-sgr-parameters '(44))))
    (is (equal '((:bg-color :blue)) result)))
  ;; Multiple attributes
  (let ((result (cl-inputs.terminal.ansii:parse-sgr-parameters '(1 31 44))))
    (is (= 3 (length result)))))

(test ansii-ansi-fg-color-seq
  "Test ansi-fg-color-seq function"
  ;; Keyword colors
  (is-true (cl-inputs.terminal.ansii:ansi-fg-color-seq :red))
  (is-true (cl-inputs.terminal.ansii:ansi-fg-color-seq :blue))
  (is-true (cl-inputs.terminal.ansii:ansi-fg-color-seq :default))
  ;; Integer color (256-color)
  (is-true (cl-inputs.terminal.ansii:ansi-fg-color-seq 100))
  ;; RGB list
  (is-true (cl-inputs.terminal.ansii:ansi-fg-color-seq '(255 128 0))))

(test ansii-ansi-bg-color-seq
  "Test ansi-bg-color-seq function"
  ;; Keyword colors
  (is-true (cl-inputs.terminal.ansii:ansi-bg-color-seq :green))
  (is-true (cl-inputs.terminal.ansii:ansi-bg-color-seq :yellow))
  (is-true (cl-inputs.terminal.ansii:ansi-bg-color-seq :default))
  ;; Integer color (256-color)
  (is-true (cl-inputs.terminal.ansii:ansi-bg-color-seq 150))
  ;; RGB list
  (is-true (cl-inputs.terminal.ansii:ansi-bg-color-seq '(128 64 192))))

(test ansii-ansi-attr-seq
  "Test ansi-attr-seq function"
  ;; Bold on
  (is-true (cl-inputs.terminal.ansii:ansi-attr-seq :bold t))
  ;; Bold off
  (is-true (cl-inputs.terminal.ansii:ansi-attr-seq :bold nil))
  ;; Underline on
  (is-true (cl-inputs.terminal.ansii:ansi-attr-seq :underline t))
  ;; Underline off
  (is-true (cl-inputs.terminal.ansii:ansi-attr-seq :underline nil)))

(test ansii-parse-csi-sequence
  "Test parse-csi-sequence function"
  ;; Cursor up: ESC [ A
  (let ((result (cl-inputs.terminal.ansii:parse-csi-sequence '(65))))  ; 'A'
    (is (eq :cursor-up (getf result :type))))
  ;; Cursor down with param: ESC [ 5 B
  (let ((result (cl-inputs.terminal.ansii:parse-csi-sequence '(53 66))))  ; '5' 'B'
    (is (eq :cursor-down (getf result :type)))
    (is (equal '(5) (getf result :params))))
  ;; SGR bold: ESC [ 1 m
  (let ((result (cl-inputs.terminal.ansii:parse-csi-sequence '(49 109))))  ; '1' 'm'
    (is (eq :sgr (getf result :type)))
    (is (equal '((:bold t)) (getf result :changes)))))

;; ==================== API Tests ====================
(test api-set-terminal-modes
  "Test set-terminal-modes function"
  (with-faketerm (term)
    ;; Enable mouse and focus tracking
    (is-true (cl-inputs.api:set-terminal-modes term :mouse t :focus t))
    ;; Disable mouse
    (is-true (cl-inputs.api:set-terminal-modes term :mouse nil))
    ;; Enable paste mode
    (is-true (cl-inputs.api:set-terminal-modes term :paste t))))

(test api-make-ready-input-source
  "Test make-ready-input-source function"
  (let* ((dev (cl-inputs.device.api:make-device :faketerm))
         (source (cl-inputs.api:make-ready-input-source :device dev)))
    (is-true source)
    (cl-inputs.loop:close-input-source source)))

(test api-read-tokens-timeout
  "Test read-tokens with timeout"
  (with-faketerm (term :width 10 :height 5)
    ;; Inject some data
    (cl-inputs.device.faketerm::faketerm-inject! term (string-to-utf-8-bytes "AB"))
    ;; Read tokens with short timeout
    (let ((tokens (cl-inputs.api:read-tokens term :timeout 0.1)))
      (is (listp tokens))
      ;; Should read at least one character
      (is (> (length tokens) 0)))))

(test api-read-tokens-empty
  "Test read-tokens with no input"
  (with-faketerm (term)
    ;; Read tokens with short timeout, no data injected
    (let ((tokens (cl-inputs.api:read-tokens term :timeout 0)))
      (is (listp tokens))
      (is (= 0 (length tokens))))))

;; ==================== Terminal API Tests ====================
(test terminal-api-esc-constant
  "Test +esc+ constant is the ESC character"
  (is (= 1 (length cl-inputs.terminal.api:+esc+)))
  (is (= 27 (char-code (char cl-inputs.terminal.api:+esc+ 0)))))

(test terminal-api-style-attribute-code
  "Test %style-attribute-code function (internal, using qualified name)"
  (is (= 1 (funcall 'cl-inputs.terminal.api:%style-attribute-code :bold)))
  (is (= 2 (funcall 'cl-inputs.terminal.api:%style-attribute-code :dim)))
  (is (= 3 (funcall 'cl-inputs.terminal.api:%style-attribute-code :italic)))
  (is (= 4 (funcall 'cl-inputs.terminal.api:%style-attribute-code :underline)))
  (is (= 5 (funcall 'cl-inputs.terminal.api:%style-attribute-code :blink)))
  (is (= 7 (funcall 'cl-inputs.terminal.api:%style-attribute-code :reverse)))))

(test terminal-api-color-code-fg
  "Test %color-code for foreground colors (internal function)")
  (is (= 30 (funcall 'cl-inputs.terminal.api:%color-code :black :fg)))
  (is (= 31 (funcall 'cl-inputs.terminal.api:%color-code :red :fg)))
  (is (= 32 (funcall 'cl-inputs.terminal.api:%color-code :green :fg)))
  (is (= 37 (funcall 'cl-inputs.terminal.api:%color-code :white :fg)))
  (is (= 39 (funcall 'cl-inputs.terminal.api:%color-code :default :fg))))

(test terminal-api-color-code-bg
  "Test %color-code for background colors (internal function)"
  (is (= 40 (funcall 'cl-inputs.terminal.api:%color-code :black :bg)))
  (is (= 41 (funcall 'cl-inputs.terminal.api:%color-code :red :bg)))
  (is (= 44 (funcall 'cl-inputs.terminal.api:%color-code :blue :bg)))
  (is (= 47 (funcall 'cl-inputs.terminal.api:%color-code :white :bg)))
  (is (= 49 (funcall 'cl-inputs.terminal.api:%color-code :default :bg))))

(test terminal-api-style->sgr-string
  "Test %style->sgr-string function"
  ;; Bold only
  (let ((sgr (cl-inputs.terminal.api:%style->sgr-string '(:attrs (:bold)))))
    (is (stringp sgr))
    (is (equal "1" sgr)))
  ;; Red foreground
  (let ((sgr (cl-inputs.terminal.api:%style->sgr-string '(:fg :red))))
    (is (stringp sgr))
    (is (equal "31" sgr)))
  ;; Multiple attributes
  (let ((sgr (cl-inputs.terminal.api:%style->sgr-string '(:fg :blue :bg :white :attrs (:bold :underline)))))
    (is (stringp sgr))
    ;; Should contain the codes in some order
    (is (search "34" sgr))
    (is (search "47" sgr))
    (is (search "1" sgr))
    (is (search "4" sgr)))
  ;; Empty style
  (is (null (cl-inputs.terminal.api:%style->sgr-string nil)))
  (is (null (cl-inputs.terminal.api:%style->sgr-string '()))))

(test terminal-api-default-methods-return-nil
  "Test default terminal API methods return NIL"
  (let ((dev "any-object"))
    (is (null (cl-inputs.terminal.api:clear-screen dev)))
    (is (null (cl-inputs.terminal.api:clear-area dev 0 0 10 10)))
    (is (null (cl-inputs.terminal.api:draw-text-at dev 0 0 "test")))
    (is (null (cl-inputs.terminal.api:draw-char-at dev 0 0 #\X)))
    (is (null (cl-inputs.terminal.api:fill-rectangle dev 0 0 10 10)))
    (is (null (cl-inputs.terminal.api:scroll-lines dev 1)))
    (is (null (cl-inputs.terminal.api:set-cursor-position dev 0 0)))
    (multiple-value-bind (row col) (cl-inputs.terminal.api:get-cursor-position dev)
      (is (null row))
      (is (null col)))
    (is (null (cl-inputs.terminal.api:hide-cursor dev)))
    (is (null (cl-inputs.terminal.api:show-cursor dev)))
    (is (null (cl-inputs.terminal.api:flush-output dev)))
    (is (null (cl-inputs.terminal.api:apply-style dev '(:fg :red))))
    (is (null (cl-inputs.terminal.api:reset-style dev)))))

(test terminal-api-with-styled-output-macro
  "Test with-styled-output macro"
  (let ((emitted '())
        (mock-dev (let ((x (list :mock)))
                    (defmethod cl-inputs.terminal.api:device-write-bytes ((dev (eql :mock)) buffer start end)
                      (declare (ignore buffer start end))
                      (push :wrote emitted))
                    x)))
    ;; Test with style
    (cl-inputs.terminal.api:with-styled-output (mock-dev '(:fg :red))
      (push :body-executed emitted))
    (is (member :wrote emitted))
    (is (member :body-executed emitted))
    ;; Test without style
    (setf emitted '())
    (cl-inputs.terminal.api:with-styled-output (mock-dev nil)
      (push :body-executed emitted))
    (is (not (member :wrote emitted)))  ; No style emit
    (is (member :body-executed emitted))))

;; ==================== Device API Tests ====================
(test device-api-default-methods
  "Test default device API methods"
  (let ((dev "any-object"))
    (is (eq dev (cl-inputs.device.api:open-device dev)))
    (is (eq t (cl-inputs.device.api:close-device dev)))
    (is (eq t (cl-inputs.device.api:enable-raw-mode dev)))
    (is (eq t (cl-inputs.device.api:disable-raw-mode dev)))
    (is (eq :eof (cl-inputs.device.api:device-read-bytes dev #(0) 0 1)))
    (is (= 0 (cl-inputs.device.api:device-write-bytes dev #(0) 0 1)))
    (is (null (cl-inputs.device.api:device-input-stream dev)))
    (is (null (cl-inputs.device.api:device-output-stream dev)))
    (is (null (cl-inputs.device.api:device-fd dev)))
    (is (null (cl-inputs.device.api:device-capabilities dev)))
    (is (eq t (cl-inputs.device.api:device-set-modes dev '(:mouse t))))))

(test device-api-condition-types
  "Test device-error and raw-mode-error condition types"
  ;; device-error
  (let ((err (make-instance 'cl-inputs.device.api:device-error
                           :device :test-device
                           :message "test error")))
    (is (eq :test-device (cl-inputs.device.api:device-error/device err)))
    (is (equal "test error" (cl-inputs.device.api:device-error/message err))))
  ;; raw-mode-error is a subtype of device-error
  (let ((err (make-instance 'cl-inputs.device.api:raw-mode-error
                           :device :test-device
                           :message "raw mode error")))
    (is-true (typep err 'cl-inputs.device.api:device-error))
    (is-true (typep err 'cl-inputs.device.api:raw-mode-error))))

(test device-api-lockable-class
  "Test lockable class and methods"
  (let ((lock (make-instance 'cl-inputs.device.api:lockable)))
    ;; Check that lock is a recursive lock
    (is-true (bt:recursive-lock-p (cl-inputs.device.api:lock-of lock)))
    ;; Initial owner should be nil
    (is (null (cl-inputs.device.api:lock-owner lock)))
    (is (= 0 (cl-inputs.device.api:lock-owner-count lock)))))

(test device-api-acquire-release-lock
  "Test acquire-lock and release-lock methods"
  (let ((lock (make-instance 'cl-inputs.device.api:lockable)))
    ;; Acquire lock
    (let ((result (cl-inputs.device.api:acquire-lock lock)))
      (is (eq lock result))
      (is (eq (bt:current-thread) (cl-inputs.device.api:lock-owner lock)))
      (is (= 1 (cl-inputs.device.api:lock-owner-count lock))))
    ;; Acquire again (recursive)
    (cl-inputs.device.api:acquire-lock lock)
    (is (= 2 (cl-inputs.device.api:lock-owner-count lock)))
    ;; Release once
    (cl-inputs.device.api:release-lock lock)
    (is (= 1 (cl-inputs.device.api:lock-owner-count lock)))
    ;; Release again
    (cl-inputs.device.api:release-lock lock)
    (is (= 0 (cl-inputs.device.api:lock-owner-count lock)))
    (is (null (cl-inputs.device.api:lock-owner lock)))))

(test device-api-device-kind-faketerm
  "Test device-kind returns correct keyword for faketerm"
  (with-faketerm (dev)
    (is (eq :faketerm (cl-inputs.device.api:device-kind dev)))))

(test device-api-device-capabilities-faketerm
  "Test device-capabilities for faketerm"
  (with-faketerm (dev)
    (let ((caps (cl-inputs.device.api:device-capabilities dev)))
      (is-true (listp caps))
      ;; Check for expected capabilities
      (is-true (getf caps :mouse))
      (is-true (getf caps :truecolor)))))

(defun run-all-cl-inputs-tests ()
  "Run all cl-inputs tests."
  (5am:run! 'cl-inputs-test))

;; Integration test placeholder for a simple defapplication using faketerm
;; (Currently a stub; enable once pipeline supports headless run cleanly)
;; (fiveam:def-suite* :cl-inputs/defapp :in :cl-inputs)
;; (fiveam:test run-defapp-smoke
;;   (is-true t))
