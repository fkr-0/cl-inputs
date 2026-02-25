(uiop:define-package :cl-inputs.tests.sink
  (:use :cl :fiveam)
  (:import-from :cl-inputs.tokens #:make-token #:input-token-kind)
  (:import-from :cl-inputs.sink
                #:accept-token #:on-key #:on-mouse #:on-resize
                #:on-paste #:on-focus #:fn-sink #:tee-sink)
  (:export #:sink-tests))

(in-package :cl-inputs.tests.sink)

(def-suite sink-tests
  :description "Tests for cl-inputs.sink module"
  :in :cl-inputs)

(in-suite sink-tests)

(test fn-sink-basic
  "Test function sink works"
  (let* ((captured nil)
          (sink (fn-sink (lambda (tok) (setf captured tok))))
          (token (make-token :key '(:code :a))))
    (funcall sink token)
    (is (eqp captured token))))

(test tee-sink-multiple
  "Test tee sink delivers to multiple sinks"
  (let* ((results '())
          (sink1 (fn-sink (lambda (tok) (push :s1 results))))
          (sink2 (fn-sink (lambda (tok) (push :s2 results))))
          (tee (tee-sink sink1 sink2))
          (token (make-token :mouse '(:type :click))))
    (funcall tee token)
    (is (= 2 (length results)))
    (is (member :s1 results))
    (is (member :s2 results))))

(test accept-token-default-no-op
  "Test default accept-token is a no-op"
  (let ((token (make-token :key '(:code :a))))
    (is (null (accept-token 'not-a-sink token)))))

(test on-key-default-no-op
  "Test default on-key is a no-op"
  (let ((token (make-token :key '(:code :a))))
    (is (null (on-key 'not-a-sink token)))))
