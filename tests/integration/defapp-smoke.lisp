(uiop:define-package :cl-inputs.tests.defapp-smoke
  (:use :cl :fiveam)
  (:import-from :elmtui.app #:defapplication)
  (:import-from :elmtui.app.api #:run-application)
  (:import-from :elmtui.tea-state.api #:make-update-result #:state-ref)
  (:import-from :cl-inputs.device.api #:make-device)
  (:import-from :cl-inputs.api #:make-ready-input-source)
  (:import-from :cl-inputs.loop #:next-token #:close-input-source)
  (:import-from :cl-inputs.util #:string-to-utf-8-bytes))

(in-package :cl-inputs.tests.defapp-smoke)

;; Minimal app: renders one char after size+cursor events and sets should-quit on key
(defun smoke-view (state)
  (declare (ignore state))
  '(:container :id :root :children ((:text :id :t :content "X"))))

(defun smoke-update (msg state)
  (declare (ignore state))
  (if (and (listp msg) (eq (first msg) :app-quit-requested))
      (make-update-result :patches '(((:should-quit) t)))
      (make-update-result)))

(defapplication cl-inputs-smoke
  :root-component-dsl '(:root-viewport :id :root :child-dsl-spec (:view nil))
  :view-fn #'smoke-view
  :update-fn #'smoke-update
  :root-viewport-id :root
  :initial-state-plist (list :should-quit nil))

(def-test-runner defapp-smoke-runner ()
  (let* ((device (make-device :faketerm :width 4 :height 2))
         (source (make-ready-input-source :device device)))
    ;; feed size + cursor + quit
    (queue:push (cl-inputs.device.faketerm::faketerm-device-in-queue device)
                (string-to-utf-8-bytes "")) ; placeholder
    (run-application (make-instance 'cl-inputs-smoke) :backend-type :tty :device device)
    (close-input-source source)))
