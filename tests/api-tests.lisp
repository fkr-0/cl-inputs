(uiop:define-package :cl-inputs.tests.api
  (:use :cl :fiveam)
  (:import-from :cl-inputs.api #:make-ready-input-source #:read-tokens)
  (:import-from :cl-inputs.loop #:next-token #:close-input-source)
  (:import-from :cl-inputs.device.api #:make-device)
  (:import-from :cl-inputs.tokens #:input-token-data)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:export #:api-tests))

(in-package :cl-inputs.tests.api)

(def-suite api-tests :description "Tests for the public cl-inputs API" :in :cl-inputs)
(in-suite api-tests)

(test make-ready-input-source-faketerm
  (let* ((device (make-device :faketerm
                              :script (list (string-to-utf-8-bytes "x"))))
         (source (make-ready-input-source :device device)))
    (unwind-protect
         (is (char= #\x (getf (input-token-data (next-token source)) :code)))
      (is-true (close-input-source source)))))

(test read-tokens-faketerm
  (let* ((device (make-device :faketerm
                              :script (list (string-to-utf-8-bytes "ab"))))
         (tokens (read-tokens device :timeout 0)))
    (is (= 2 (length tokens)))
    (is (char= #\a (getf (input-token-data (first tokens)) :code)))
    (is (char= #\b (getf (input-token-data (second tokens)) :code)))))
