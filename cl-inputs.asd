(in-package :asdf)
(asdf:defsystem "cl-inputs"
  :description "Terminal input decoding (pure), device port, and sink port."
  :license "MIT" :version "0.1.0"
  :author "cbadger"
  :depends-on (#:alexandria #:uiop #:bordeaux-threads #:sb-posix
                #:log4cl)
  :components
  ((:file "src/input/util")
    (:file "src/input/tokens")
    (:file "src/input/keymap")
    (:file "src/input/escape")
    (:file "src/terminal/ansii")
    (:file "src/input/adapters" :depends-on ("src/input/tokens" "src/terminal/ansii"))

    (:file "src/input/decoder" :depends-on ("src/input/tokens" "src/input/keymap"))
    (:file "src/input/sink" :depends-on ("src/input/tokens"))
    (:file "src/input/device/device-api")
    (:file "src/terminal/api" :depends-on ("src/input/util" "src/input/device/device-api"))
    (:file "src/input/device/tty" :depends-on ("src/input/device/device-api" "src/terminal/api"))
    (:file "src/input/device/faketerm" :depends-on ("src/input/device/device-api" "src/terminal/api"))
    (:file "src/input/device/urxvt" :depends-on ("src/input/device/device-api" "src/terminal/api"))
    (:file "src/input/loop" :depends-on ("src/input/device/device-api" "src/input/decoder" "src/input/sink"))
    (:file "src/input/api" :depends-on ("src/input/loop"))
    (:file "src/input/package" :depends-on ("src/terminal/api")))

  :in-order-to ((asdf:test-op (asdf:test-op "cl-inputs/tests"))))
