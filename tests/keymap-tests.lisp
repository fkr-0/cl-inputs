(uiop:define-package :cl-inputs.tests.keymap
  (:use :cl)
  (:import-from :fiveam #:def-suite #:in-suite #:test #:is #:is-true #:is-false)
  (:import-from :cl-inputs.keymap
                #:*default-keymap* #:lookup-seq #:canonicalize-key)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:export #:keymap-tests))

(in-package :cl-inputs.tests.keymap)

(def-suite keymap-tests
  :description "Tests for cl-inputs.keymap module"
  :in :cl-inputs)

(in-suite keymap-tests)

(defun escape-bytes (suffix)
  (string-to-utf-8-bytes
   (concatenate 'string (string #\Esc) suffix)))

(test lookup-seq-arrow-keys
  "Test looking up arrow key sequences"
  ;; Up arrow: ESC [ A
  (let* ((bytes (escape-bytes "[A"))
          (result (lookup-seq bytes)))
    (is (eq :up result)))
  ;; Down arrow: ESC [ B
  (let* ((bytes (escape-bytes "[B"))
          (result (lookup-seq bytes)))
    (is (eq :down result)))
  ;; Right arrow: ESC [ C
  (let* ((bytes (escape-bytes "[C"))
          (result (lookup-seq bytes)))
    (is (eq :right result)))
  ;; Left arrow: ESC [ D
  (let* ((bytes (escape-bytes "[D"))
          (result (lookup-seq bytes)))
    (is (eq :left result))))

(test lookup-seq-function-keys
  "Test looking up function keys"
  ;; F1: ESC O P
  (let* ((bytes (escape-bytes "OP"))
          (result (lookup-seq bytes)))
    (is (eq :f1 result)))
  ;; F2: ESC O Q
  (let* ((bytes (escape-bytes "OQ"))
          (result (lookup-seq bytes)))
    (is (eq :f2 result))))

(test lookup-seq-edit-keys
  "Test looking up editing keys"
  ;; Home: ESC [ H
  (let* ((bytes (escape-bytes "[H"))
          (result (lookup-seq bytes)))
    (is (eq :home result)))
  ;; End: ESC [ F
  (let* ((bytes (escape-bytes "[F"))
          (result (lookup-seq bytes)))
    (is (eq :end result)))
  ;; Delete: ESC [ 3 ~
  (let* ((bytes (escape-bytes "[3~"))
          (result (lookup-seq bytes)))
    (is (eq :delete result)))
  ;; Insert: ESC [ 2 ~
  (let* ((bytes (escape-bytes "[2~"))
          (result (lookup-seq bytes)))
    (is (eq :insert result))))

(test lookup-seq-page-keys
  "Test looking up page navigation keys"
  ;; Page Up: ESC [ 5 ~
  (let* ((bytes (escape-bytes "[5~"))
          (result (lookup-seq bytes)))
    (is (eq :page-up result)))
  ;; Page Down: ESC [ 6 ~
  (let* ((bytes (escape-bytes "[6~"))
          (result (lookup-seq bytes)))
    (is (eq :page-down result))))

(test lookup-seq-special-chars
  "Test looking up special characters"
  ;; Tab - use code-char 9 for tab
  (let* ((bytes (make-array 1 :element-type '(unsigned-byte 8) :initial-contents (list 9)))
          (result (lookup-seq bytes)))
    (is (eq :tab result)))
  ;; Enter/Return - code 13
  (let* ((bytes (make-array 1 :element-type '(unsigned-byte 8) :initial-contents (list 13)))
          (result (lookup-seq bytes)))
    (is (eq :enter result)))
  ;; Backspace - code 127
  (let* ((bytes (make-array 1 :element-type '(unsigned-byte 8) :initial-contents (list 127)))
          (result (lookup-seq bytes)))
    (is (eq :backspace result)))
  ;; A lone Escape is intentionally not a keymap entry: the streaming decoder
  ;; must buffer it long enough to distinguish ESC from a CSI or Alt prefix.
  (let* ((bytes (make-array 1 :element-type '(unsigned-byte 8) :initial-contents (list 27)))
          (result (lookup-seq bytes)))
    (is (null result))))

(test lookup-seq-unknown
  "Test that unknown sequences return NIL"
  (let* ((bytes (escape-bytes "z"))
          (result (lookup-seq bytes)))
    (is (null result)))
  ;; Invalid sequence
  (let* ((bytes (make-array 5 :element-type '(unsigned-byte 8) 
                              :initial-contents (list 27 91 255 255 255)))
          (result (lookup-seq bytes)))
    (is (null result))))

(test canonicalize-key-normal
  "Test canonicalizing normal characters"
  (is (eq :a (canonicalize-key #\a)))
  (is (eq :z (canonicalize-key #\z)))
  (is (eq :0 (canonicalize-key #\0)))
  (is (eq :9 (canonicalize-key #\9)))
  (is (eq :space (canonicalize-key #\Space)))
  (is (eq :colon (canonicalize-key #\:))))

(test canonicalize-key-with-modifiers
  "Test canonicalizing keys with modifiers"
  (is (eq :c-a (canonicalize-key #\a :ctrl t)))
  (is (eq :c-z (canonicalize-key #\z :ctrl t)))
  (is (eq :s-a (canonicalize-key #\a :shift t)))
  (is (eq :m-a (canonicalize-key #\a :alt t))))

(test canonicalize-key-combination
  "Test canonicalizing keys with multiple modifiers"
  (is (eq :c-s-a (canonicalize-key #\a :ctrl t :shift t)))
  (is (eq :c-m-a (canonicalize-key #\a :ctrl t :alt t)))
  (is (eq :c-m-s-a (canonicalize-key #\a :shift t :ctrl t :alt t))))
