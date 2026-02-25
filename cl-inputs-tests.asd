(in-package :asdf-user)

(asdf:defsystem "cl-inputs/tests"
  :description "Test suite for cl-inputs."
  :author "Kilo Code"
  :version "0.1.0"
  :depends-on (#:cl-inputs #:fiveam)
  :license "MIT"
  :serial t
  :components ((:module "tests"
                 :serial t
                 :components ((:file "main")
                               (:file "tokens-tests")
                               (:file "keymap-tests")
                               (:file "escape-tests")
                               (:file "decoder-tests")
                               (:file "sink-tests")
                               (:file "util-tests")
                               (:file "device-api-tests")
                               (:file "faketerm-tests")
                               (:file "tty-tests")
                               (:file "terminal-api-tests")
                               (:file "loop-tests")
                               (:file "api-tests")
                               (:file "integration-tests"))))
  :perform (test-op (op c) (symbol-call :cl-inputs.tests #:run-all-cl-inputs-tests)))
