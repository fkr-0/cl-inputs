(in-package :asdf)

(asdf:defsystem "cl-inputs"
  :description "Terminal input decoding, device ports, and token sinks."
  :author "ElmTUI contributors"
  :license "MIT"
  :version "0.1.0"
  :depends-on (#:alexandria
               #:uiop
               #:bordeaux-threads
               #:sb-posix
               #:log4cl
               #:cl-events)
  :components
  ((:file "src/input/util")
   (:file "src/input/tokens")
   (:file "src/input/keymap")
   (:file "src/input/escape")
   (:file "src/terminal/ansii")
   (:file "src/input/adapters"
    :depends-on ("src/input/tokens" "src/terminal/ansii"))
   (:file "src/input/decoder"
    :depends-on ("src/input/tokens" "src/input/keymap"))
   (:file "src/input/sink"
    :depends-on ("src/input/tokens"))
   (:file "src/input/device/device-api")
   (:file "src/terminal/api"
    :depends-on ("src/input/util" "src/input/device/device-api"))
   (:file "src/input/device/tty"
    :depends-on ("src/input/device/device-api" "src/terminal/api"))
   (:file "src/input/device/faketerm"
    :depends-on ("src/input/device/device-api" "src/terminal/api"))
   (:file "src/input/device/urxvt"
    :depends-on ("src/input/device/device-api" "src/terminal/api"))
   (:file "src/input/loop"
    :depends-on ("src/input/device/device-api"
                 "src/input/decoder"
                 "src/input/sink"))
   (:file "src/input/api"
    :depends-on ("src/input/loop"))
   (:file "src/input/package"
    :depends-on ("src/terminal/api")))
  :in-order-to ((test-op (test-op "cl-inputs/tests"))))

;;; ASDF discovers secondary systems reliably when they share the primary ASD.
(asdf:defsystem "cl-inputs/tests"
  :description "Test suite for cl-inputs."
  :author "ElmTUI contributors"
  :license "MIT"
  :version "0.1.0"
  :depends-on (#:cl-inputs #:fiveam)
  :serial t
  :components
  ((:module "tests"
    :serial t
    :components
    ((:file "main")
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
     (:file "ansii-tests")
     (:file "integration-tests"))))
  :perform
  (test-op (operation component)
    (declare (ignore operation component))
    (uiop:symbol-call :cl-inputs.tests :run-all-cl-inputs-tests)))
