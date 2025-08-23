(uiop:define-package :cl-inputs.tokens
  (:use :cl :alexandria)
  (:export #:input-token #:make-token #:token-kind #:input-token-data #:token-ts
           ;; common :kind values
           #:+k-key+ #:+k-mouse+ #:+k-resize+ #:+k-paste+ #:+k-focus+))

(uiop:define-package :cl-inputs.keymap
  (:use :cl :alexandria)
  (:export #:*default-keymap* #:lookup-seq #:canonicalize-key))

(uiop:define-package :cl-inputs.decoder
  (:use :cl :alexandria :cl-inputs.tokens :cl-inputs.keymap)
  (:export
   ;; immutable decoder state (can be a plist/struct)
   #:make-decoder #:decoder-state
   ;; functional decoding step:
   #:decode-chunk))

(uiop:define-package :cl-inputs.device
  (:use :cl :alexandria)
  (:import-from #:sb-posix #:o-rdwr
                #:tcgetattr #:tcsetattr #:termios #:termios-lflag #:termios-cc
                #:icanon #:echo #:vmin #:vtime #:tcsanow #:tcsaflush)
  (:export
   ;; Device port (generics; default stub prints warnings)
   #:make-device
   #:device-kind
   #:open-device #:close-device
   #:enable-raw-mode #:disable-raw-mode
   #:device-read-bytes #:device-write-bytes
   #:device-capabilities
   #:device-set-modes
   ;; Optional default TTY impl constructor:
   #:make-tty-device
   #:*backend-registry*
   #:register-backend
   #:make-device*))

(uiop:define-package :cl-inputs.sink
  (:use :cl :alexandria :cl-inputs.tokens)
  (:export
   ;; Sink port (generics; defaults are NO-OP)
   #:accept-token #:on-key #:on-mouse #:on-resize #:on-paste #:on-focus
   ;; Helpers for composing sinks:
   #:tee-sink #:fn-sink))

(uiop:define-package :cl-inputs.api
  (:use :cl :alexandria :cl-inputs.tokens :cl-inputs.decoder :cl-inputs.device :cl-inputs.sink)
  (:export
   ;; Push mode
   #:start-input-loop #:stop-input-loop
   ;; Pull mode
   #:make-input-source #:next-token #:close-input-source
   ;; Quick one-shot read helpers
   #:read-tokens #:with-raw-input
   #:input-loop))
