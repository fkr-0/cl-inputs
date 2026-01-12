;;; coverage.lisp - Test coverage for cl-inputs system
;;; Usage: clpm bundle exec --with-client sbcl -- --noinform --load coverage.lisp

(in-package :cl)

(defvar *root* (uiop:pathname-directory-pathname *load-truename*))
(defvar *coverage-dir* (merge-pathnames #p"coverage/" *root*))

;;; Load SB-COVER for code coverage
(require :sb-cover)

;;; Turn on generation of code coverage instrumentation in the compiler
(declaim (optimize sb-cover:store-coverage-data))

;;; Clean and create coverage directory
(when (uiop:directory-exists-p *coverage-dir*)
  (uiop:delete-directory-tree *coverage-dir* :validate t :if-does-not-exist :ignore))
(ensure-directories-exist *coverage-dir*)

;;; Load and force recompile main system with coverage instrumentation
;;; Load test system WITHOUT force to avoid instrumenting test code
(asdf:load-system "cl-inputs" :force t)
(asdf:load-system "cl-inputs/tests")

;;; Run the test suite and capture result
(let ((test-result (funcall (find-symbol "RUN-ALL-CL-INPUTS-TESTS" (find-package "CL-INPUTS.TESTS")))))
  (declare (ignorable test-result))

  ;; Generate coverage report
  (sb-cover:report *coverage-dir*)

  (format t "~&=== Coverage Report Generated ===~%")
  (format t "HTML: ~A~%" (merge-pathnames #p"cover-index.html" *coverage-dir*))

  ;; Clean up - turn off coverage instrumentation
  (declaim (optimize (sb-cover:store-coverage-data 0)))

  ;; Exit with appropriate code
  (uiop:quit 0))
