(uiop:define-package :cl-inputs.tests.tokens
  (:use :cl)
  (:import-from :fiveam #:def-suite #:in-suite #:test #:is #:is-true #:is-false)
  (:import-from :cl-inputs.tokens
                #:input-token #:make-token #:input-token-kind #:input-token-data
                #:input-token-ts #:+k-key+ #:+k-mouse+ #:+k-resize+ #:+k-paste+ #:+k-focus+
                #:+k-terminal-response+ #:+k-protocol+)
  (:export #:tokens-tests))

(in-package :cl-inputs.tests.tokens)

(def-suite tokens-tests
  :description "Tests for cl-inputs.tokens module"
  :in :cl-inputs)

(in-suite tokens-tests)

(test make-token-basic
  "Test basic token creation"
  (let ((tok (make-token :key '(:code :a))))
    (is (eq :key (input-token-kind tok)))
    (is (eq :a (getf (input-token-data tok) :code)))
    (is (integerp (input-token-ts tok)))))

(test make-token-with-timestamp
  "Test token creation with explicit timestamp"
  (let* ((ts 1234567890)
          (tok (make-token :mouse '(:type :click) ts)))
    (is (eq :mouse (input-token-kind tok)))
    (is (eq :click (getf (input-token-data tok) :type)))
    (is (= ts (input-token-ts tok)))))

(test token-kind-constants
  "Test token kind constants are properly defined"
  (is (eq :key +k-key+))
  (is (eq :mouse +k-mouse+))
  (is (eq :resize +k-resize+))
  (is (eq :paste +k-paste+))
  (is (eq :focus +k-focus+))
  (is (eq :terminal-response +k-terminal-response+))
  (is (eq :protocol +k-protocol+)))

(test make-token-all-kinds
  "Test creating tokens of each kind"
  (dolist (kind (list +k-key+ +k-mouse+ +k-resize+ +k-paste+ +k-focus+
                      +k-terminal-response+ +k-protocol+))
    (let ((tok (make-token kind '(:test t))))
      (is (eq kind (input-token-kind tok)))
      (is (eq t (getf (input-token-data tok) :test))))))

(test make-keyboard-token-with-modifiers
  "Test creating keyboard token with shift/ctrl/alt modifiers"
  (let ((tok (make-token :key '(:code :a :shift t :ctrl t))))
    (is (eq :key (input-token-kind tok)))
    (is (eq :a (getf (input-token-data tok) :code)))
    (is-true (getf (input-token-data tok) :shift))
    (is-true (getf (input-token-data tok) :ctrl))))

(test make-mouse-token-with-position
  "Test creating mouse token with coordinates"
  (let ((tok (make-token :mouse '(:type :motion :x 10 :y 20))))
    (is (eq :mouse (input-token-kind tok)))
    (is (eq :motion (getf (input-token-data tok) :type)))
    (is (= 10 (getf (input-token-data tok) :x)))
    (is (= 20 (getf (input-token-data tok) :y)))))

(test make-resize-token
  "Test creating resize token"
  (let ((tok (make-token :resize '(:width 80 :height 24))))
    (is (eq :resize (input-token-kind tok)))
    (is (= 80 (getf (input-token-data tok) :width)))
    (is (= 24 (getf (input-token-data tok) :height)))))

(test make-paste-token-with-content
  "Test creating paste token with string content"
  (let ((tok (make-token :paste '(:content "pasted text"))))
    (is (eq :paste (input-token-kind tok)))
    (is (equal "pasted text" (getf (input-token-data tok) :content)))))

(test make-focus-token
  "Test creating focus gained/lost token"
  (let ((tok-gained (make-token :focus '(:gained t)))
        (tok-lost (make-token :focus '(:gained nil))))
    (is (eq :focus (input-token-kind tok-gained)))
    (is-true (getf (input-token-data tok-gained) :gained))
    (is (eq :focus (input-token-kind tok-lost)))
    (is-false (getf (input-token-data tok-lost) :gained))))
