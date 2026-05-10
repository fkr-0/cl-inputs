(uiop:define-package :cl-inputs.tests.sink
  (:use :cl)
  (:import-from :fiveam #:def-suite #:in-suite #:test #:is #:is-true #:is-false)
  (:import-from :cl-inputs.tokens #:make-token #:input-token-kind #:input-token-data
                #:input-token-ts)
  (:import-from :cl-inputs.sink
                #:accept-token #:on-key #:on-mouse #:on-resize
                #:on-paste #:on-focus #:on-ctrl-c
                #:fn-sink #:tee-sink)
  (:import-from :cl-inputs.tests #:cl-inputs-test)
  (:export #:sink-tests))

(in-package :cl-inputs.tests.sink)

(def-suite sink-tests
  :description "Tests for cl-inputs.sink module"
  :in cl-inputs-test)

(in-suite sink-tests)

(test fn-sink-basic
  "Test function sink works"
  (let* ((captured nil)
          (sink (fn-sink (lambda (tok) (setf captured tok))))
          (token (make-token :key '(:code :a))))
    (funcall sink token)
    (is (not (null captured)))
    (is (eq :key (input-token-kind captured)))
    (is (eq :a (getf (input-token-data captured) :code)))))

(test fn-sink-multiple-tokens
  "Test function sink handles multiple tokens"
  (let* ((count 0)
          (sink (fn-sink (lambda (tok) (declare (ignore tok)) (incf count))))
          (token1 (make-token :key '(:code :a)))
          (token2 (make-token :key '(:code :b))))
    (funcall sink token1)
    (is (= 1 count))
    (funcall sink token2)
    (is (= 2 count))))

(test tee-sink-two-sinks
  "Test tee sink with two sinks"
  (let* ((results '())
          (sink1 (fn-sink (lambda (tok) (declare (ignore tok)) (push :s1 results))))
          (sink2 (fn-sink (lambda (tok) (declare (ignore tok)) (push :s2 results))))
          (tee (tee-sink sink1 sink2))
          (token (make-token :mouse '(:type :click))))
    (funcall tee token)
    (is (= 2 (length results)))
    (is (member :s1 results))
    (is (member :s2 results))))

(test tee-sink-three-sinks
  "Test tee sink with three sinks"
  (let* ((results '())
          (sink1 (fn-sink (lambda (tok) (declare (ignore tok)) (push :s1 results))))
          (sink2 (fn-sink (lambda (tok) (declare (ignore tok)) (push :s2 results))))
          (sink3 (fn-sink (lambda (tok) (declare (ignore tok)) (push :s3 results))))
          (tee (tee-sink sink1 sink2 sink3))
          (token (make-token :resize '(:width 80))))
    (funcall tee token)
    (is (= 3 (length results)))
    (is (= 1 (count :s1 results)))
    (is (= 1 (count :s2 results)))
    (is (= 1 (count :s3 results)))))

(test accept-token-default-no-op
  "Test default accept-token is a no-op"
  (let* ((sink "any-string")
          (token (make-token :key '(:code :x))))
    (is (null (accept-token sink token)))))

(test on-key-default-no-op
  "Test default on-key is a no-op"
  (let* ((sink "any-string")
          (token (make-token :key '(:code :a))))
    (is (null (on-key sink token)))))

(test on-mouse-default-no-op
  "Test default on-mouse is a no-op"
  (let* ((sink "any-string")
          (token (make-token :mouse '(:type :click))))
    (is (null (on-mouse sink token)))))

(test on-resize-default-no-op
  "Test default on-resize is a no-op"
  (let* ((sink "any-string")
          (token (make-token :resize '(:width 80 :height 24))))
    (is (null (on-resize sink token)))))

(test on-paste-default-no-op
  "Test default on-paste is a no-op"
  (let* ((sink "any-string")
          (token (make-token :paste '(:content "text"))))
    (is (null (on-paste sink token)))))

(test on-focus-default-no-op
  "Test default on-focus is a no-op"
  (let* ((sink "any-string")
          (token (make-token :focus '(:gained t))))
    (is (null (on-focus sink token)))))

(test tee-sink-with-accept-token
  "Test tee sink works with accept-token"
  (let* ((count 0)
          (counter (fn-sink (lambda (tok) (declare (ignore tok)) (incf count))))
          (tee (tee-sink counter))
          (token (make-token :key '(:code :x))))
    (funcall tee token)
    (is (= 1 count))))
