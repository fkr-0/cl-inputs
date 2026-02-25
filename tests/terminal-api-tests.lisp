(uiop:define-package :cl-inputs.tests.terminal-api
  (:use :cl :fiveam)
  (:import-from :cl-inputs.device.api #:make-device)
  (:import-from :cl-inputs.terminal.api
                #:clear-screen #:clear-area #:draw-text-at #:draw-char-at
                #:fill-rectangle #:scroll-lines #:set-cursor-position
                #:get-cursor-position #:hide-cursor #:show-cursor
                #:apply-style #:reset-style)
  (:export #:terminal-api-tests))

(in-package :cl-inputs.tests.terminal-api)

(def-suite terminal-api-tests
  :description "Tests for cl-inputs.terminal.api module"
  :in :cl-inputs)

(in-suite terminal-api-tests)

(test clear-screen-faketerm
  "Test clearing screen on faketerm"
  (let ((dev (make-device :faketerm :width 10 :height 5)))
    (clear-screen dev)
    (is (equal '("" "" "" "" "") (cl-inputs.device.faketerm:faketerm-screen-lines dev)))))

(test draw-text-at-faketerm
  "Test drawing text at position"
  (let ((dev (make-device :faketerm :width 10 :height 5)))
    (draw-text-at dev 0 0 "hello")
    (let ((lines (cl-inputs.device.faketerm:faketerm-screen-lines dev)))
      (is (equal "hello" (first lines))))))

(test draw-char-at-faketerm
  "Test drawing a single character"
  (let ((dev (make-device :faketerm :width 10 :height 5)))
    (draw-char-at dev 2 3 #\X)
    (let ((lines (cl-inputs.device.faketerm:faketerm-screen-lines dev)))
      (is (equal "   X" (nth 2 lines))))))

(test fill-rectangle-faketerm
  "Test filling a rectangle"
  (let ((dev (make-device :faketerm :width 10 :height 5)))
    (fill-rectangle dev 0 0 3 3 :char #\#)
    (let ((lines (cl-inputs.device.faketerm:faketerm-screen-lines dev)))
      (is (equal "###" (first lines))))))

(test set-cursor-position-faketerm
  "Test setting cursor position"
  (let ((dev (make-device :faketerm :width 10 :height 5)))
    (set-cursor-position dev 2 3)
    (multiple-value-bind (row col) (get-cursor-position dev)
      (is (= 2 row))
      (is (= 3 col)))))

(test hide-show-cursor-faketerm
  "Test hiding and showing cursor"
  (let ((dev (make-device :faketerm)))
    (hide-cursor dev)
    (is (null (cl-inputs.device.faketerm::faketerm-device-cursor-visible-p dev)))
    (show-cursor dev)
    (is (true (cl-inputs.device.faketerm::faketerm-device-cursor-visible-p dev)))))
