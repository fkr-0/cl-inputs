(uiop:define-package :cl-inputs.tests.api
  (:use :cl :fiveam)
  (:import-from :cl-inputs.api #:make-ready-input-source #:read-tokens)
  (:import-from :cl-inputs.loop #:next-token #:close-input-source)
  (:import-from :cl-inputs.device.api #:make-device)
  (:import-from :cl-inputs.device.faketerm
                #:faketerm-device-raw-depth #:faketerm-device-close-count)
  (:import-from :cl-inputs.tokens #:input-token-data)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:export #:api-tests))

(in-package :cl-inputs.tests.api)

(def-suite api-tests :description "Tests for the public cl-inputs API" :in :cl-inputs)
(in-suite api-tests)

(test make-ready-input-source-faketerm
  (let* ((device (make-device :faketerm
                              :script (list (string-to-utf-8-bytes "x"))))
         (source (make-ready-input-source :device device)))
    (unwind-protect
         (progn
           (is (= 1 (faketerm-device-raw-depth device)))
           (is (char= #\x (getf (input-token-data (next-token source)) :code))))
      (is-true (close-input-source source)))
    (is (= 1 (faketerm-device-close-count device)))))

(test read-tokens-faketerm
  (let* ((device (make-device :faketerm
                              :script (list (string-to-utf-8-bytes "ab"))))
         (tokens (read-tokens device :timeout 0)))
    (is (= 2 (length tokens)))
    (is (char= #\a (getf (input-token-data (first tokens)) :code)))
    (is (char= #\b (getf (input-token-data (second tokens)) :code)))))

;;; The public normalization adapter is core code. These cases exercise each
;;; supported token shape and verify that mutable modifier lists are isolated.
(test adapter-key-token-numeric-code-and-modifier-isolation
  (let* ((mods (list :ctrl :alt))
         (token (cl-inputs.tokens:make-token
                 :key (list :code 65 :mods mods :type :key-up)))
         (event (cl-inputs.adapters:token->normalized-event token)))
    (is (eq :key-event (getf event :type)))
    (is (eq :key-up (getf event :event-type)))
    (is (eq :key-65 (getf event :key)))
    (is (eql #\A (getf event :char)))
    (is (= 65 (getf event :code)))
    (is (equal mods (getf event :modifiers)))
    (is (not (eq mods (getf event :modifiers))))
    (setf (first (getf event :modifiers)) :changed)
    (is (equal '(:ctrl :alt) mods))))

(test adapter-key-character-keyword-and-incomplete-code
  (let ((character-event
          (cl-inputs.adapters:token->normalized-event
           (cl-inputs.tokens:make-token :key '(:code #\x))))
        (keyword-event
          (cl-inputs.adapters:token->normalized-event
           (cl-inputs.tokens:make-token :key '(:code :enter :char #\Return))))
        (missing-event
          (cl-inputs.adapters:token->normalized-event
           (cl-inputs.tokens:make-token :key '(:code nil))))
        (invalid-event
          (cl-inputs.adapters:token->normalized-event
           (cl-inputs.tokens:make-token :key '(:code 1.5)))))
    (is (eq :key-down (getf character-event :event-type)))
    (is (eq :X (getf character-event :key)))
    (is (eql #\x (getf character-event :char)))
    (is (= (char-code #\x) (getf character-event :code)))
    (is (eq :enter (getf keyword-event :key)))
    (is (= 13 (getf keyword-event :code)))
    (is (eq :unknown (getf missing-event :key)))
    (is (null (getf missing-event :char)))
    (is (null (getf missing-event :code)))
    (is (eq :unknown (getf invalid-event :key)))
    (is (null (getf invalid-event :char)))
    (is (null (getf invalid-event :code)))))


(test public-set-terminal-modes-success-and-unsupported-device
  (let ((dev (make-device :faketerm)))
    (is-true (cl-inputs.api:set-terminal-modes
              dev :mouse :sgr :focus t :paste t))
    (is-true (cl-inputs.api:set-terminal-modes dev)))
  (fiveam:signals cl-inputs.device.api:device-error
    (cl-inputs.api:set-terminal-modes :not-a-device :paste t)))

(test public-with-raw-input-restores-owned-state-after-exit
  (let ((dev (make-device :faketerm)))
    (is (eq :ok
            (cl-inputs.api:with-raw-input (dev)
              (is (= 1 (faketerm-device-raw-depth dev)))
              :ok)))
    (is (zerop (faketerm-device-raw-depth dev)))
    (is (= 1 (faketerm-device-close-count dev)))))

(test public-with-input-source-unwinds-and-closes-exactly-once
  (let ((dev (make-device :faketerm)))
    (fiveam:signals simple-error
      (cl-inputs.api:with-input-source (source :device dev)
        (is (= 1 (faketerm-device-raw-depth dev)))
        (is (not (null source)))
        (error "intentional test unwind")))
    (is (zerop (faketerm-device-raw-depth dev)))
    (is (= 1 (faketerm-device-close-count dev)))))

(test adapter-mouse-and-resize-protocol
  (let* ((mods (list :shift))
         (mouse (cl-inputs.adapters:token->normalized-event
                 (cl-inputs.tokens:make-token
                  :mouse (list :type :move :button :left :x 8 :y 13 :mods mods))))
         (resize (cl-inputs.adapters:token->normalized-event
                  (cl-inputs.tokens:make-token
                   :resize '(:width 100 :height 32)))))
    (is (eq :mouse-event (getf mouse :type)))
    (is (eq :move (getf mouse :event-type)))
    (is (eq :left (getf mouse :button)))
    (is (= 8 (getf mouse :x)))
    (is (= 13 (getf mouse :y)))
    (is (equal '(:shift) (getf mouse :modifiers)))
    (is (not (eq mods (getf mouse :modifiers))))
    (setf (first (getf mouse :modifiers)) :modified)
    (is (equal '(:shift) mods))
    (is (equal '(:type :terminal-resized :width 100 :height 32) resize)))
  (dolist (data '((:width 12) (:height 12) ()))
    (is (null (cl-inputs.adapters:token->normalized-event
               (cl-inputs.tokens:make-token :resize data)))))
  (dolist (kind '(:paste :focus :terminal-response :protocol :other))
    (is (null (cl-inputs.adapters:token->normalized-event
               (cl-inputs.tokens:make-token kind '(:ignored t)))))))
