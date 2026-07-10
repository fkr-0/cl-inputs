(defpackage :cl-inputs.tests (:use :cl :fiveam) (:export #:run-all-cl-inputs-tests))

(in-package :cl-inputs.tests)

(def-suite :cl-inputs :description "Tests for the cl-inputs library.")

(in-suite :cl-inputs)

(defun run-all-cl-inputs-tests ()
  "Run the complete modular cl-inputs test suite and fail ASDF on errors."
  (let ((results (fiveam:run :cl-inputs)))
    (fiveam:explain! results)
    (unless (fiveam:results-status results)
      (error "The cl-inputs test suite failed."))
    results))
