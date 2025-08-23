(in-package :asdf)
(asdf:defsystem "cl-inputs"
  :description "Terminal input decoding (pure), device port, and sink port."
  :license "MIT" :version "0.1.0"
  :author "Kilo Code"
  :depends-on (#:alexandria #:uiop #:trivial-utf-8 #:bordeaux-threads)
  :components
  ((:file "src/input/packages")
   (:file "src/input/tokens" :depends-on ("src/input/packages"))
   (:file "src/input/keymap" :depends-on ("src/input/packages"))
   (:file "src/input/decoder" :depends-on ("src/input/tokens" "src/input/keymap"))
   (:file "src/input/device" :depends-on ("src/input/packages"))
   (:file "src/input/sink" :depends-on ("src/input/tokens"))
   (:file "src/input/loop" :depends-on ("src/input/device" "src/input/decoder" "src/input/sink"))
   (:file "src/input/api" :depends-on ("src/input/loop"))
   (:file "src/input/backends/tty" :depends-on ("src/input/device"))
   (:file "src/input/backends/faketerm" :depends-on ("src/input/device"))
   (:file "src/input/backends/urxvt" :depends-on ("src/input/device")))
  :in-order-to ((asdf:test-op (asdf:test-op "cl-input/tests"))))

(asdf:defsystem "cl-inputs/tests"
  :description "Test suite for cl-input."
  :author "Kilo Code"
  :license "MIT"
  :depends-on ("cl-inputs" "fiveam")
  :components ((:module "tests"
                :components
                ((:file "main")))))
