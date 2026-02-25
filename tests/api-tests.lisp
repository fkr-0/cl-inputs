(uiop:define-package :cl-inputs.tests.api
  (:use :cl :fiveam)
  (:import-from :cl-inputs.api
                #:make-input #:input-start #:input-stop #:input-process)
  (:export #:api-tests))

(in-package :cl-inputs.tests.api)

(def-suite api-tests
  :description "Tests for cl-inputs.api module"
  :in :cl-inputs)

(in-suite api-tests)

(test make-input-default
  "Test creating default input handler"
  (let ((inp (make-input)))
    (is (listp inp))
    (is (getf inp :device))
    (is (getf inp :sink))))

(test make-input-with-options
  "Test creating input with custom options"
  (let ((inp (make-input :backend :faketerm :width 40 :height 12)))
    (is (listp inp))
    (is (getf inp :device))))
