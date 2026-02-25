(uiop:define-package :cl-inputs.tests.keymap
  (:use :cl :fiveam)
  (:import-from :cl-inputs.keymap
                #:*default-keymap* #:lookup-seq #:canonicalize-key)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:export #:keymap-tests))

(in-package :cl-inputs.tests.keymap)

(def-suite keymap-tests
  :description "Tests for cl-inputs.keymap module"
  :in :cl-inputs)

(in-suite keymap-tests)

(test lookup-seq-arrow-up
  "Test looking up arrow up sequence"
  (let* ((bytes (string-to-utf-8-bytes "^[A"))
          (result (lookup-seq bytes)))
    (is (eq :up result))))

(test lookup-seq-arrow-down
  "Test looking up arrow down sequence"
  (let* ((bytes (string-to-utf-8-bytes "^[B"))
          (result (lookup-seq bytes)))
    (is (eq :down result))))

(test lookup-seq-enter
  "Test looking up Enter key"
  (let* ((bytes (string-to-utf-8-bytes (string #\Return)))
          (result (lookup-seq bytes)))
    (is (eq :enter result))))

(test lookup-seq-unknown
  "Test that unknown sequences return NIL"
  (let* ((bytes (string-to-utf-8-bytes "^[z"))
          (result (lookup-seq bytes)))
    (is (null result))))

(test canonicalize-key-normal
  "Test canonicalizing a normal character"
  (is (eq :a (canonicalize-key #)))
  (is (eq :z (canonicalize-key #\z))))

(test canonicalize-key-control
  "Test canonicalizing a control character"
  (is (eq :c-a (canonicalize-key # :ctrl t)))
  (is (eq :c-z (canonicalize-key #\z :ctrl t))))
