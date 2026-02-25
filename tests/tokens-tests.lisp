(uiop:define-package :cl-inputs.tests.tokens
  (:use :cl)
  (:import-from :fiveam #:def-suite #:in-suite #:test #:is)
  (:import-from :cl-inputs.tokens
                #:input-token #:make-token #:input-token-kind
                #:input-token-data #:input-token-ts
                #:+k-key+ #:+k-mouse+ #:+k-resize+ #:+k-paste+ #:+k-focus+)
  (:import-from :cl-inputs.tests #:cl-inputs-test)
  (:export #:tokens-tests))

(in-package :cl-inputs.tests.tokens)

(def-suite tokens-tests
  :description "Tests for cl-inputs.tokens module"
  :in cl-inputs-test)

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
  (is (eq :focus +k-focus+)))

(test make-token-all-kinds
  "Test creating tokens of each kind"
  (dolist (kind (list +k-key+ +k-mouse+ +k-resize+ +k-paste+ +k-focus+))
    (let ((tok (make-token kind '(:test t))))
      (is (eq kind (input-token-kind tok)))
      (is (eq t (getf (input-token-data tok) :test))))))
