;;; Reproducible core-only SBCL/ASDF coverage runner.
;;; CLPM_HOME=.cache/clpm clpm bundle exec --with-client sbcl -- --noinform
;;;   --non-interactive --load coverage.lisp
(require :asdf)
(require :sb-cover)
(in-package :cl-user)

;; SB-COVER:LCOV-REPORT first shipped with SBCL 2.6.0. No silent HTML
;; approximation: CI must use a compiler with real source-line coverage.
(unless (and (find-symbol "LCOV-REPORT" :sb-cover)
             (fboundp (find-symbol "LCOV-REPORT" :sb-cover)))
  (error "SBCL ~A lacks SB-COVER:LCOV-REPORT; install SBCL >= 2.6.0"
         (lisp-implementation-version)))

(defparameter *cl-inputs-root*
  (uiop:pathname-directory-pathname *load-truename*))
(defparameter *cl-inputs-coverage-directory*
  (merge-pathnames "coverage/" *cl-inputs-root*))

;; Remove stale measurements, including failed/partial previous invocations.
(when (uiop:directory-exists-p *cl-inputs-coverage-directory*)
  (uiop:delete-directory-tree *cl-inputs-coverage-directory*
                              :validate t :if-does-not-exist :ignore))
(ensure-directories-exist
 (merge-pathnames "placeholder" *cl-inputs-coverage-directory*))

(sb-cover:clear-coverage)
(declaim (optimize (sb-cover:store-coverage-data 3)))
(asdf:load-system "cl-inputs" :force t)
(declaim (optimize (sb-cover:store-coverage-data 0)))

;; Test files and transitive dependencies must not enter the owned-code
;; denominator; the Python gate also uses an explicit source inventory.
(asdf:load-system "cl-inputs/tests")
(uiop:symbol-call :cl-inputs.tests :run-all-cl-inputs-tests)

(sb-cover:report
 *cl-inputs-coverage-directory*
 :if-matches
 (lambda (filename)
   (let ((src (namestring (merge-pathnames "src/" *cl-inputs-root*))))
     (and (<= (length src) (length filename))
          (string= src filename :end2 (length src))))))

(funcall (symbol-function (find-symbol "LCOV-REPORT" :sb-cover))
         (merge-pathnames "coverage.info" *cl-inputs-coverage-directory*))
(format t "~&Generated SB-COVER HTML + LCOV in ~A~%"
        *cl-inputs-coverage-directory*)
(uiop:quit 0)
