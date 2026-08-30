(uiop:define-package :cl-inputs.events
  (:use :cl)
  (:import-from :cl-inputs.tokens
                #:input-token-kind
                #:input-token-ts)
  (:export #:token->event #:event-bus-sink))

(in-package :cl-inputs.events)

;; CL-EVENTS intentionally exposes its bus through an event protocol. Its basic
;; EVENT struct is data-only, so the optional adapter supplies the protocol
;; methods needed to publish those event values. Core CL-INPUTS never loads this
;; file or these methods.
(defmethod cl-events.protocols:event-topic ((event cl-events.types:event))
  (cl-events.types:event-type event))

(defmethod cl-events.protocols:event-payload ((event cl-events.types:event))
  (cl-events.types:event-data event))

(defmethod cl-events.protocols:event-timestamp ((event cl-events.types:event))
  (cl-events.types:event-when event))

(defun token->event (token)
  "Convert an input TOKEN into a CL-EVENTS event value.

The token kind is the event topic/type and the token itself is the payload."
  (cl-events.types:make-event
   :type (input-token-kind token)
   :data token
   :when (input-token-ts token)))

(defun event-bus-sink (bus &key (topic :input/token))
  "Return a sink function that publishes input tokens to BUS under TOPIC."
  (lambda (token)
    (cl-events.bus:publish-event
     bus
     (cl-events.types:make-event
      :type topic
      :data (token->event token)
      :when (input-token-ts token)))))
