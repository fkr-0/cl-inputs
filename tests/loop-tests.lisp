(uiop:define-package :cl-inputs.tests.loop
  (:use :cl :fiveam)
  (:import-from :cl-inputs.loop #:make-input-source #:next-token #:close-input-source)
  (:import-from :cl-inputs.device.api #:make-device)
  (:import-from :cl-inputs.tokens #:input-token-data)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:export #:loop-tests))

(in-package :cl-inputs.tests.loop)

(def-suite loop-tests :description "Tests for pull-mode input sources" :in :cl-inputs)
(in-suite loop-tests)

(test input-source-drains-decoded-token-buffer
  (let* ((device (make-device :faketerm
                              :script (list (string-to-utf-8-bytes "xy"))))
         (source (make-input-source :device device)))
    (unwind-protect
         (progn
           (is (char= #\x (getf (input-token-data (next-token source)) :code)))
           (is (char= #\y (getf (input-token-data (next-token source)) :code)))
           (is (null (next-token source :timeout 0))))
      (is-true (close-input-source source)))))
