(uiop:define-package :cl-inputs.tests.ansii
  (:use :cl)
  (:import-from :fiveam #:def-suite #:in-suite #:test #:is #:is-true #:is-false)
  (:import-from :cl-inputs.terminal.ansii
                #:introducer #:introducer-name #:introducer-code #:*introducers*
                #:*ansi-keys* #:lookup-sequence #:get-sequence #:render-seq
                #:response-type
                #:ansi-fg-color-seq #:ansi-bg-color-seq #:ansi-attr-seq
                #:parse-csi-sequence #:parse-sgr-parameters)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes)
  (:export #:ansii-tests))

(in-package :cl-inputs.tests.ansii)

(def-suite ansii-tests
  :description "Tests for cl-inputs.terminal.ansii module"
  :in :cl-inputs)

(in-suite ansii-tests)

(test introducer-basic
  "Test basic introducer access"
  (is-true *introducers* "Introducer list should exist")
  (is (> (length *introducers*) 0) "Should have introducers defined"))

(test get-sequence-sgr
  "Test getting SGR sequences"
  (let ((seq (get-sequence :reset)))
    (is-true seq "Should get reset sequence"))
  (let ((seq (get-sequence :bold)))
    (is-true seq "Should get bold sequence"))
  (let ((seq (get-sequence :fg-red)))
    (is-true seq "Should get foreground red sequence")))

(test render-seq-basic
  "Test rendering basic sequences"
  (let ((seq (get-sequence :bold)))
    (is-true seq)
    (let ((rendered (render-seq seq)))
      (is (stringp rendered))
      (is (> (length rendered) 0)))))

(test render-seq-fg-color
  "Test rendering foreground color sequences"
  (let ((red-seq (get-sequence :fg-red))
        (blue-seq (get-sequence :fg-blue)))
    (is-true red-seq)
    (is-true blue-seq)
    (let ((red-rendered (render-seq red-seq))
          (blue-rendered (render-seq blue-seq)))
      (is (stringp red-rendered))
      (is (stringp blue-rendered)))))

(test render-seq-bg-color
  "Test rendering background color sequences"
  (let ((seq (get-sequence :bg-yellow)))
    (is-true seq)
    (let ((rendered (render-seq seq)))
      (is (stringp rendered)))))

(test render-seq-cursor
  "Test rendering cursor control sequences"
  (let ((up-seq (get-sequence :cursor-up)))
    (is-true up-seq)
    (let ((rendered (render-seq up-seq 5)))
      (is (stringp rendered))))
  (let ((home-seq (get-sequence :cursor-save-dec)))
    (is-true home-seq)))

(test query-sequence-declares-response-type-without-stream-parser
  (let ((query (get-sequence :cursor-report)))
    (is (eq :cursor-position (response-type query))))
  (multiple-value-bind (symbol status)
      (find-symbol "READ-RESPONSE" :cl-inputs.terminal.ansii)
    (declare (ignore symbol))
    (is (null status))))

(test render-seq-erase
  "Test rendering erase sequences"
  (let ((seq (get-sequence :erase-screen)))
    (is-true seq))
  (let ((seq (get-sequence :erase-line)))
    (is-true seq)))

(test ansi-fg-color-seq
  "Test ansi-fg-color-seq helper"
  (let ((red (ansi-fg-color-seq :red))
        (blue (ansi-fg-color-seq :blue))
        (default (ansi-fg-color-seq :default)))
    (is (stringp red))
    (is (stringp blue))
    (is (stringp default))))

(test ansi-bg-color-seq
  "Test ansi-bg-color-seq helper"
  (let ((red (ansi-bg-color-seq :red))
        (green (ansi-bg-color-seq :green))
        (default (ansi-bg-color-seq :default)))
    (is (stringp red))
    (is (stringp green))
    (is (stringp default))))

(test ansi-attr-seq
  "Test ansi-attr-seq helper"
  (let ((bold (ansi-attr-seq :bold t))
        (underline (ansi-attr-seq :underline t))
        (bold-off (ansi-attr-seq :bold nil)))
    (is (stringp bold))
    (is (stringp underline))
    (is (stringp bold-off))))

(test parse-csi-sequence-cursor
  "Test parsing CSI cursor sequences"
  ;; ESC [ A = cursor up
  (let* ((bytes (list 65))  ;; bytes after ESC [
         (parsed (parse-csi-sequence bytes)))
    (is (listp parsed))
    (is (eq :cursor-up (getf parsed :type))))
  ;; ESC [ 5 A = cursor up 5
  (let* ((bytes (list 53 65))  ;; bytes after ESC [
         (parsed (parse-csi-sequence bytes)))
    (is (listp parsed))
    (is (eq :cursor-up (getf parsed :type)))))

(test parse-csi-sequence-erase
  "Test parsing CSI erase sequences"
  ;; ESC [ J = erase display
  (let* ((bytes (list 74))  ;; bytes after ESC [
         (parsed (parse-csi-sequence bytes)))
    (is (listp parsed))
    (is (eq :erase-in-display (getf parsed :type))))
  ;; ESC [ 2 J = erase entire screen
  (let* ((bytes (list 50 74))  ;; bytes after ESC [
         (parsed (parse-csi-sequence bytes)))
    (is (listp parsed))))

(test parse-sgr-parameters
  "Test parsing SGR (Select Graphic Rendition) parameters"
  ;; 0 = reset
  (let* ((params (list 0))
        (parsed (parse-sgr-parameters params)))
    (is (listp parsed))
    (is-true (getf (first parsed) :reset)))
  ;; 1 = bold
  (let* ((params (list 1))
        (parsed (parse-sgr-parameters params)))
    (is (listp parsed))
    (is-true (getf (first parsed) :bold)))
  ;; 31 = red foreground
  (let* ((params (list 31))
        (parsed (parse-sgr-parameters params)))
    (is (listp parsed))
    (is (eq :red (getf (first parsed) :fg-color))))
  ;; 44 = blue background
  (let* ((params (list 44))
        (parsed (parse-sgr-parameters params)))
    (is (listp parsed))
    (is (eq :blue (getf (first parsed) :bg-color))))
  ;; Multiple: 1;31;44 = bold, red fg, blue bg
  (let* ((params (list 1 31 44))
        (parsed (parse-sgr-parameters params)))
    (is (= 3 (length parsed)))
    (is-true (getf (first parsed) :bold))
    (is (eq :red (getf (second parsed) :fg-color)))
    (is (eq :blue (getf (third parsed) :bg-color)))))
