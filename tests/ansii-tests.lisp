(uiop:define-package :cl-inputs.tests.ansii
  (:use :cl)
  (:import-from :fiveam #:def-suite #:in-suite #:test #:is #:is-true #:is-false #:signals)
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

(test ansi-render-placeholder-and-argument-shapes
  "Explicit placeholder rendering is stable for supplied and NIL arguments."
  (let ((fixture (cl-inputs.terminal.ansii:make-ansi-sequence
                  :identifier :test-cursor
                  :seq '("ESC" "[" nil ";" nil "H"))))
    (is (string= (format nil "~C[4;7H" #\Esc)
                 (render-seq fixture 4 7)))
    (is (string= (format nil "~C[;7H" #\Esc)
                 (render-seq fixture nil 7)))
    (is (= 2 (cl-inputs.terminal.ansii:number-of-arguments fixture)))
    (is (eq fixture (lookup-sequence fixture)))))

(test ansi-style-color-encoding-variants
  "Named, indexed, RGB and reset colors produce actual terminal escapes."
  (is (string= (format nil "~C[39m" #\Esc) (ansi-fg-color-seq nil)))
  (is (string= (format nil "~C[49m" #\Esc) (ansi-bg-color-seq nil)))
  (is (string= (format nil "~C[38;5;196m" #\Esc)
               (ansi-fg-color-seq 196)))
  (is (string= (format nil "~C[48;5;27m" #\Esc)
               (ansi-bg-color-seq 27)))
  (is (string= (format nil "~C[38;2;1;2;3m" #\Esc)
               (ansi-fg-color-seq '(1 2 3))))
  (is (string= (format nil "~C[48;2;8;9;10m" #\Esc)
               (ansi-bg-color-seq '(8 9 10))))
  (is (string= (format nil "~C[24m" #\Esc)
               (ansi-attr-seq :underline nil))))

(test ansi-csi-boundary-and-report-cases
  "Only final bytes terminate CSI; truncated CSI must signal a parse error."
  (is (cl-inputs.terminal.ansii:is-csi-final-byte? 64))
  (is (cl-inputs.terminal.ansii:is-csi-final-byte? 126))
  (is (not (cl-inputs.terminal.ansii:is-csi-final-byte? 63)))
  (is (not (cl-inputs.terminal.ansii:is-csi-final-byte? 127)))
  (signals error (parse-csi-sequence (list 49 59 50)))
  (is (eq :report-cursor-position
          (getf (parse-csi-sequence (list 54 110)) :type)))
  (is (eq :report-device-status
          (getf (parse-csi-sequence (list 53 110)) :type)))
  (is (eq :device-status-report
          (getf (parse-csi-sequence (list 55 110)) :type)))
  (is (eq :unknown-csi
          (getf (parse-csi-sequence (list 49 122)) :type))))

(test ansi-extended-sgr-parse
  "Extended SGR values preserve channels; incomplete colors do not fabricate values."
  (let ((changes (parse-sgr-parameters '(38 5 196 48 2 12 34 56))))
    (is (equal '(:fg-color (:type :xterm :value 196))
               (first changes)))
    (is (equal '(:bg-color (:type :rgb :r 12 :g 34 :b 56))
               (second changes))))
  (is (notany (lambda (change) (getf change :fg-color))
              (parse-sgr-parameters '(38 2 2 3))))
  (is (null (parse-sgr-parameters '(48 5))))
  (is (equal '((:bold nil) (:faint nil))
             (parse-sgr-parameters '(22))))
  (is (equal '(1 2 3)
             (cl-inputs.terminal.ansii:parse-parameters
              (list #\1 #\; #\2 #\: #\3)))))
