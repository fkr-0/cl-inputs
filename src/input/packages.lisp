(uiop:define-package :cl-inputs.util
  (:use :cl :alexandria)
  (:export #:as-utf-8-bytes
           #:string-to-utf-8-bytes))

(uiop:define-package :cl-inputs.tokens
  (:use :cl :alexandria)
  (:export #:input-token #:make-token #:input-token-kind #:input-token-data #:input-token-ts
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
  (:use :cl :alexandria )
  (:import-from
   #:cl-inputs.util #:as-utf-8-bytes #:string-to-utf-8-bytes)
  (:import-from #:sb-ext #:run-program  #:process-pid #:process-pty #:process-kill)
  (:import-from #:sb-sys #:make-fd-stream #:fd-stream-fd)
  (:use #:sb-unix)

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
   #:register-backend))

(uiop:define-package :cl-inputs.sink
  (:use :cl :alexandria :cl-inputs.tokens)
  (:export
   ;; Sink port (generics; defaults are NO-OP)
   #:accept-token #:on-key #:on-mouse #:on-resize #:on-paste #:on-focus #:on-ctrl-c
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
   #:read-tokens #:with-raw-input #:with-interruptible-input-reader
   #:input-loop))
