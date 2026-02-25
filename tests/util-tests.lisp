(uiop:define-package :cl-inputs.tests.util
  (:use :cl :fiveam)
  (:import-from :cl-inputs.util
                #:string-to-utf-8-bytes #:as-utf-8-bytes #:write-output)
  (:export #:util-tests))

(in-package :cl-inputs.tests.util)

(def-suite util-tests
  :description "Tests for cl-inputs.util module"
  :in :cl-inputs)

(in-suite util-tests)

(test string-to-utf-8-bytes-ascii
  "Test converting ASCII string to UTF-8 bytes"
  (let* ((str "hello")
          (bytes (string-to-utf-8-bytes str)))
    (is (= 5 (length bytes)))
    (is (= 104 (aref bytes 0))) ;; h
    (is (= 101 (aref bytes 1))) ;; e
    ))

(test string-to-utf-8-bytes-empty
  "Test converting empty string"
  (let* ((str "")
          (bytes (string-to-utf-8-bytes str)))
    (is (= 0 (length bytes)))))

(test string-to-utf-8-bytes-unicode
  "Test converting Unicode string to UTF-8 bytes"
  (let* ((str (string #\lambda)) ;; λ needs 2 bytes in UTF-8
          (bytes (string-to-utf-8-bytes str)))
    (is (= 2 (length bytes)))
    (is (= 206 (aref bytes 0)))
    (is (= 187 (aref bytes 1)))))
