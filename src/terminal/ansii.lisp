;;;===============================================================
;;; File: src/platform/backend/common/utils.lisp
;;; Common Utilities for Terminal Backends
;;;
;;; This file contains shared constants, data structures, and
;;; helper functions used by various terminal backends, such as
;;; ANSI escape code definitions, input parsing logic, etc.
;;;===============================================================

(uiop:define-package :cl-inputs.terminal.ansii
  (:use :cl)
  (:import-from :cl-inputs.tokens
    #:input-token-kind #:input-token-data)
  (:export
    ;; ANSI Introducers
    #:introducer
    #:make-introducer
    #:introducer-desc
    #:introducer-name
    #:introducer-code
    #:introducer-esc
    #:introducer-esc-char
    #:introducer-esc-str
    #:introducer-esc-hex
    #:introducer-esc-dec
    #:introducer-esc-oct
    #:*introducers*
    #:introducer-key

    ;; ANSI Keys
    #:*ansi-keys* ; For mapping escape sequences to key symbols
    #:read-escape-bytes ; Parses a sequence of bytes after an ESC

    ;; ANSI Sequences (from constants.lisp)
    #:ansi-sequence
    #:make-ansi-sequence
    #:seq ; accessor
    #:description ; accessor
    #:identifier ; accessor
    #:prerender ; accessor
    #:response-parser ; accessor
    #:reset-sequence ; accessor
    #:default-args ; accessor
    #:number-of-arguments
    #:lookup-sequence
    #:render-seq
    #:read-response ; Generic response reader
    #:parse-cursor-report-response
    #:parse-device-status-report-response
    #:+ansi-escape-sequences+
    #:+ansi-escape-sequences-lookup+
    #:+ansi-escape-sequences-reset-lookup+
    #:get-sequence
    #:get-reset-sequence

    ;; Style Parsing (from terminal-style.lisp)
    #:is-csi-final-byte?
    #:collect-csi-params
    #:parse-csi-sequence
    #:parse-sgr-parameters
    #:parse-parameters
    #:split-seq-if

    ;; ANSI Style Sequence Generation Helpers
    #:ansi-fg-color-seq
    #:ansi-bg-color-seq
    #:ansi-attr-seq))

(in-package :cl-inputs.terminal.ansii)

(eval-when (:compile-toplevel :load-toplevel :execute)
;;;---------------------------------------------------------------
;;; ANSI Introducers (from lowterm/ansi.lisp)
;;;---------------------------------------------------------------
  (defstruct introducer
    (desc nil :type (or null string))
    (name nil :type (or null symbol))
    (code nil :type (or null integer))
    (esc nil :type (or null integer))
    (esc-char nil :type (or null character))
    (esc-str nil :type (or null string))
    (esc-hex nil :type (or null string))
    (esc-dec nil :type (or null string))
    (esc-oct nil :type (or null string)))

  (defparameter *introducers*
    '(("Padding Character" :PAD "@" (027 064)) ; Note: Original had list of char codes, simplified to string for esc-char
       ("High Octet Preset" :HOP "A" (027 065))
       ("Break Permitted Here" :BPH "B" (027 066))
       ("No Break Here" :NBH "C" (027 067))
       ("Index" :IND "D" (027 068))
       ("Next Line" :NEL "E" (027 069))
       ("Start of Selected Area" :SSA "F" (027 070))
       ("End of Selected Area" :ESA "G" (027 071))
       ("Character Tabulation Set" :HTS "H" (027 072))
       ("Character Tabulation with Justification" :HTJ "I" (027 073))
       ("Line Tabulation Set" :VTS "J" (027 074))
       ("Partial Line Forward" :PLD "K" (027 075))
       ("Partial Line Backward" :PLU "L" (027 076))
       ("Reverse Line Feed" :RI "M" (027 077))
       ("Single Shift 2" :SS2 "N" (027 078))
       ("Single Shift 3" :SS3 "O" (027 079))
       ("Device Control String" :DCS "P" (027 080))
       ("Private Use One" :PU1 "Q" (027 081))
       ("Private Use Two" :PU2 "R" (027 082))
       ("Set Transmit State" :STS "S" (027 083))
       ("Cancel Character" :CCH "T" (027 084))
       ("Message Waiting" :MW "U" (027 085))
       ("Start Protected Area" :SPA "V" (027 086))
       ("End Protected Area" :EPA "W" (027 087))
       ("Start Of String" :SOS "X" (027 088))
       ("Single Graphic Character Introducer" :SGCI "Y" (027 089))
       ("Single Character Introducer" :SCI "Z" (027 090))
       ("ROI" :ROI "%" (027 03)) ; Assuming ROI is a typo for something else or a custom one
       ("Control Sequence Intro" :CSI "[" (027 091))
       ("String Terminator" :ST "\\" (027 092))
       ("Operating System Command" :OSC "]" (027 093))
       ("Privacy Message" :PM "^" (027 094))
       ("Application Program Command" :APC "_" (027 095)))
    "A list of ANSI escape sequence introducers. Each entry is a list of:
  (Description Name Esc-Char-Suffix Esc-Char-Code-List).
  The Esc-Char-Code-List is (ESC-Code Actual-Char-Code).")

  (defun introducer-key (byte)
    "Given a byte that follows an ESC (0x1B) character, returns the keyword
   identifier for the introducer type (e.g., :CSI, :SS3, :OSC)."
    (loop for entry in *introducers*
      when (and (fourth entry) (= byte (second (fourth entry))))
      return (second entry)
      finally (return nil))) ; Return nil if no match

;;;---------------------------------------------------------------
;;; ANSI Key Definitions (from lowterm/ansi.lisp)
;;;---------------------------------------------------------------
  ;; This maps common ANSI escape sequences (typically for special keys)
  ;; to more user-friendly keywords.
  ;; The format is: :KEYWORD (INTRODUCER-TYPE CHAR-OR-CODE [MORE-CHARS-OR-CODES...])
  ;; Or for sequences with multiple representations:
  ;; :KEYWORD ( (INTRODUCER-TYPE ...) (INTRODUCER-TYPE ...) )
  (defparameter *ansi-keys*
    '((:INSERT (:CSI #\2 #\~))      ; ESC [ 2 ~
       (:DELETE (:CSI #\3 #\~))      ; ESC [ 3 ~
       (:PAGE-UP (:CSI #\5 #\~))     ; ESC [ 5 ~
       (:PAGE-DOWN (:CSI #\6 #\~))   ; ESC [ 6 ~
       (:HOME (:CSI #\H) (:SS3 #\H)) ; ESC [ H or ESC O H
       (:END (:CSI #\F) (:SS3 #\F))   ; ESC [ F or ESC O F
       (:UP (:CSI #\A) (:SS3 #\A))    ; ESC [ A or ESC O A
       (:DOWN (:CSI #\B) (:SS3 #\B))  ; ESC [ B or ESC O B
       (:RIGHT (:CSI #\C) (:SS3 #\C)) ; ESC [ C or ESC O C
       (:LEFT (:CSI #\D) (:SS3 #\D))  ; ESC [ D or ESC O D
       (:F1 (:SS3 #\P))              ; ESC O P
       (:F2 (:SS3 #\Q))              ; ESC O Q
       (:F3 (:SS3 #\R))              ; ESC O R
       (:F4 (:SS3 #\S))              ; ESC O S
       (:F5 (:CSI #\1 #\5 #\~))      ; ESC [ 1 5 ~
       (:F6 (:CSI #\1 #\7 #\~))      ; ESC [ 1 7 ~
       (:F7 (:CSI #\1 #\8 #\~))      ; ESC [ 1 8 ~
       (:F8 (:CSI #\1 #\9 #\~))      ; ESC [ 1 9 ~
       (:F9 (:CSI #\2 #\0 #\~))      ; ESC [ 2 0 ~
       (:F10 (:CSI #\2 #\1 #\~))     ; ESC [ 2 1 ~
       (:F11 (:CSI #\2 #\3 #\~))     ; ESC [ 2 3 ~ (Note: original had 23~, assuming typo for 23)
       (:F12 (:CSI #\2 #\4 #\~))     ; ESC [ 2 4 ~
       (:MENU (:CSI #\2 #\9 #\~)))   ; ESC [ 2 9 ~  (Often context menu key)
    "Alist mapping key symbols to their ANSI escape sequence definitions.
   Each definition is a list starting with the introducer type (e.g., :CSI, :SS3)
   followed by the characters/codes that make up the rest of the sequence.
   Some keys might have multiple possible sequences (e.g., :HOME).")

  (defun read-escape-bytes (stream introducer-type)
    "Reads bytes from STREAM following an ESC and an introducer (like '[', 'O').
   Tries to match the sequence against *ANSI-KEYS*.
   STREAM: The input stream to read from.
   INTRODUCER-TYPE: The keyword for the introducer (e.g., :CSI, :SS3).
   Returns (VALUES KEY-SYMBOL REMAINING-BYTES) or (VALUES NIL ALL-READ-BYTES) if no match.
   REMAINING-BYTES are bytes read that didn't form a known key sequence.
   ALL-READ-BYTES are all bytes read if no specific key was matched."
    (let* ((collected-chars '()) ; Renamed from read-sequence
            (char-count 0)
            (_ (loop for char = (read-char stream nil nil)
                 while char
                 do (push char collected-chars)
                 (incf char-count)
                 until (or (not (graphic-char-p char)) ; Stop on non-graphic or control chars
                         (>= char-count 6)))) ; Max length for typical key sequences
                                        ; msg is not used in this simple test
            (collected-chars (nreverse collected-chars)) ; Reverse to get original order
            (matched-key nil))
      (declare (ignore _))

      (unless collected-chars (return-from read-escape-bytes (values nil nil)))

      ;; Try to find a match in *ansi-keys*
      (loop for (key . defs) in *ansi-keys*
        do (let ((normalized-defs (if (keywordp (first defs)) (list defs) defs)))
             (loop for def in normalized-defs
               when (eq (first def) introducer-type)
               do (let* ((key-seq-chars (rest def))
                          (key-seq-len (length key-seq-chars)))
                    (when (and (>= (length collected-chars) key-seq-len) ; Use renamed variable
                            (every #'char= key-seq-chars (subseq collected-chars 0 key-seq-len))) ; Use renamed variable
                      (setf matched-key key)
                      (return-from read-escape-bytes
                        (values matched-key (subseq collected-chars key-seq-len)))))))) ; Use renamed variable
      (values nil collected-chars))) ; Use renamed variable

;;;---------------------------------------------------------------
;;; ANSI Sequence Definitions (from lowterm/constants.lisp)
;;;---------------------------------------------------------------

  ;; Functions and struct needed by DEFSEQ macrolet at compile time
  (eval-when (:compile-toplevel :load-toplevel :execute)
    (defclass ansi-sequence ()
      ((seq :initarg :seq :reader seq
         :documentation "Sequence to be sent. As a list of strings. For execution those are joined on function arguments.")
        (description :initarg :desc :reader description
          :documentation "Description of the sequence.")
        (identifier :initarg :id :reader identifier
          :documentation "Keyword, Identifier of the sequence.")
        (prerender :initarg :prerender :initform nil :accessor prerender
          :documentation "Function to prerender the sequence.")
        (response-parser :initarg :response-parser :reader response-parser
          :documentation "Function to parse the response of the sequence.")
        (reset-sequence :initarg :reset-sequence :reader reset-sequence)
        (default-args :initarg :default-args :reader default-args
          :documentation "Default arguments for the sequence."))
      (:documentation "Ansi Escape Sequence to be sent to the terminal."))

    (defun make-ansi-sequence (&key seq description identifier response-parser reset-sequence)
      (make-instance 'ansi-sequence
        :seq seq
        :desc description
        :id identifier
        :response-parser response-parser
        :reset-sequence reset-sequence))

    (defun read-response (fd delimiters &optional (fn #'identity))
      "Parses a terminal response stream.
    FD is the stream to parse. DELIMITERS is a list of characters to split the response at.
    FN is an optional function that will be mapped over the resulting list of strings.
    Returns a list of the parsed values."
      (read-char fd nil) ; throw away esc
      (read-char fd nil) ; throw away [ (or other introducer part)
      (let ((current-segment (make-string-output-stream))
             results)
        (loop for char = (read-char fd nil nil)
          while (and char delimiters)
          do (if (char= char (car delimiters))
               (progn
                 (push (funcall fn (get-output-stream-string current-segment)) results)
                 (setf delimiters (cdr delimiters)))
               (write-char char current-segment))
          finally (unless (zerop (length (get-output-stream-string current-segment))) ; Add last segment if any
                    (push (funcall fn (get-output-stream-string current-segment)) results)))
        (nreverse results)))

    (defun parse-cursor-report-response (fd)
      "Parse a cursor report response (e.g., ESC [ <row> ; <col> R)."
      (let ((delim '(#\; #\R)))
        (mapcar (lambda (x) (parse-integer x :junk-allowed t))
          (read-response fd delim))))

    (defun parse-device-status-report-response (fd)
      "Parse a device status report response (e.g., ESC [ <status> n)."
      (let ((delim '(#\n)))
        (mapcar (lambda (x) (parse-integer x :junk-allowed t))
          (read-response fd delim)))))

  (defmethod render-seq ((seq ansi-sequence) &rest args)
    "Render the ANSI control sequence with args."
    (let ((control-parts (slot-value seq 'seq))
           (identifier (slot-value seq 'identifier)))
      ;; (log:debug "RENDER-SEQ: Called for seq ID: ~S, control-string template: ~S, args: ~S"
      ;;            identifier control-parts args)

      (let* ((string-builder (list (string (code-char 27))))) ; Start with ESC
        (let ((arg-index 0))
          (dolist (part control-parts)
            (cond
              ((and (stringp part) (string= part "ESC"))
                ;; The initial ESC character is already added.
                ;; This part of the sequence definition is effectively a marker.
                )
              ((stringp part)
                (push part string-builder))
              ((null part) ; Placeholder for an argument
                (if (< arg-index (length args))
                  (let ((arg-value (nth arg-index args)))
                    ;; Ensure arguments are converted to strings.
                    ;; NIL arguments become empty strings in the sequence.
                    (push (if arg-value (princ-to-string arg-value) "") string-builder)
                    (incf arg-index))
                  (progn
                    (log:warn "RENDER-SEQ: Not enough arguments for sequence ~S. Expected placeholder at index ~D, but no more arguments provided. Inserting empty string."
                      identifier arg-index)
                    (push "" string-builder)))) ; Insert empty string if not enough args
              (t
                ;; (log:error "RENDER-SEQ: Unknown part ~S in sequence definition for ~S. Skipping part." part identifier)
                ;; Optionally, insert an error marker or an empty string
                (push "" string-builder)))))

        (let ((final-string (apply #'concatenate 'string (nreverse string-builder))))
          ;; (log:debug "RENDER-SEQ: For seq ID: ~S, returning string: ~S (char-codes: ~S)"
          ;;            identifier (sanitize-string-for-logging
          ;;                        final-string)
          ;;            (when (> (length final-string) 0) (map 'list #'char-code final-string)))
          final-string))))
  ;; (defmethod render-seq ((seq ansi-sequence) &rest args)
  ;;   "Render the ANSI control sequence with args."
  ;;   (let ((control-parts (slot-value seq 'seq)))
  ;;     (log:debug "RENDER-SEQ: Called for seq ID: ~S, control-string: ~S, args: ~S"
  ;;                (slot-value seq 'identifier) control-parts args)

  ;;     ;; Build a string with ESC prefix and properly formatted parts
  ;;     (let ((result
  ;;             (with-output-to-string (s)
  ;;               ;; Always write the ESC character first (regardless of what's in the sequence)
  ;;               (write-char (code-char 27) s)

  ;;               ;; Process each part
  ;;               (let ((arg-index 0))
  ;;                 (dolist (part control-parts)
  ;;                   (cond
  ;;                     ;; Skip "ESC" strings since we already added the ESC character
  ;;                     ((and (stringp part) (string= part "ESC")))

  ;;                     ;; Regular string part - write it directly
  ;;                     ((stringp part)
  ;;                      (write-string part s))

  ;;                     ;; NIL means insert an argument
  ;;                     ((null part)
  ;;                      (when (< arg-index (length args))
  ;;                        (format s "~A" (nth arg-index args))
  ;;                        (incf arg-index)))

  ;;                     ;; Anything else is an error
  ;;                     (t (error "Unknown part in sequence: ~S" part))))))))

  ;;       ;; Show what we're returning for debugging
  ;;       (log:debug "RENDER-SEQ: For seq ID: ~S, returning string: ~S"
  ;;                  (slot-value seq 'identifier) result)

  ;;       ;; Return the formatted string with ESC prefix
  ;;       result)))

  (defmethod initialize-instance :after ((obj ansi-sequence) &key)
    "Initialize the ANSI sequence object properly."
    (with-slots (identifier seq prerender) obj
      ;; We don't need to precompute prerender anymore since render-seq handles it directly
      ;; (log:debug "ANSI-SEQ INIT [~A]: Initialized with raw parts: ~S"
      ;;   identifier seq)
      ))

  ;; Helper function for debugging ANSI sequences
  (defun print-char-codes (string)
    "Print the character codes of STRING for debugging."
    (loop for char across string
      collect (char-code char)))



  (defmethod number-of-arguments ((seq ansi-sequence))
    (count-if-not #'stringp (seq seq)))
  ;; Find the render-seq function and update it to ensure proper formatting of escape codes
  (append nil '(ansi-sequence) (list 'render-seq))

  (defmethod print-object ((seq ansi-sequence) stream)
    (print-unreadable-object (seq stream :type t :identity t)
      (format stream "<~A>" (identifier seq))))

  (eval-when (:compile-toplevel :load-toplevel :execute)
    (defvar +ansi-escape-sequences+ (make-hash-table :test #'equal))
    (defvar +ansi-escape-sequences-lookup+ (make-hash-table :test 'equal))
    (defvar +ansi-escape-sequences-reset-lookup+ (make-hash-table :test 'eq))

    (macrolet ((defseq (id desc seq &key response reset)
                 `(let ((ident ,id)
                         ;; Use funcall here because make-ansi-sequence is defined inside eval-when
                         (sequence-obj (funcall #'make-ansi-sequence :seq ',seq
                                         :description ,desc
                                         :identifier ,id
                                         :response-parser ,response
                                         :reset-sequence ,reset)))
                    (setf (gethash ident +ansi-escape-sequences+) sequence-obj)
                    (setf (gethash (apply #'concatenate 'string (loop for part in ',seq collect (if (stringp part) part "~A")))
                            +ansi-escape-sequences-lookup+) ident)
                    (when ,reset
                      (setf (gethash ident +ansi-escape-sequences-reset-lookup+) ,reset)))))
      ;; SGR (Select Graphic Rendition)
      (defseq :reset "Reset all modes" ("ESC" "[0m"))
      (defseq :bold "Set bold mode" ("ESC" "[1m") :reset :reset)
      (defseq :faint "Set dim/faint mode" ("ESC" "[2m") :reset :faint-off)
      (defseq :italic "Set italic mode" ("ESC" "[3m") :reset :italic-off)
      (defseq :underline "Set underline mode" ("ESC" "[4m") :reset :underline-off)
      (defseq :blink "Set blinking mode" ("ESC" "[5m") :reset :blink-off)
      (defseq :inverse "Set inverse/reverse mode" ("ESC" "[7m") :reset :inverse-off)
      (defseq :invisible "Set hidden/invisible mode" ("ESC" "[8m") :reset :invisible-off)
      (defseq :strike "Set strikethrough mode" ("ESC" "[9m") :reset :strike-off)

      (defseq :bold-off "Turn off bold" ("ESC" "[21m")) ; Some terminals use 22m for bold/faint off
      (defseq :faint-off "Turn off faint" ("ESC" "[22m"))
      (defseq :italic-off "Turn off italic" ("ESC" "[23m"))
      (defseq :underline-off "Turn off underline" ("ESC" "[24m"))
      (defseq :blink-off "Turn off blink" ("ESC" "[25m"))
      (defseq :inverse-off "Turn off inverse" ("ESC" "[27m"))
      (defseq :invisible-off "Turn off invisible" ("ESC" "[28m"))
      (defseq :strike-off "Turn off strikethrough" ("ESC" "[29m"))

      ;; Foreground Colors (Basic)
      (defseq :fg-black "Foreground Black" ("ESC" "[30m") :reset :fg-default)
      (defseq :fg-red "Foreground Red" ("ESC" "[31m") :reset :fg-default)
      (defseq :fg-green "Foreground Green" ("ESC" "[32m") :reset :fg-default)
      (defseq :fg-yellow "Foreground Yellow" ("ESC" "[33m") :reset :fg-default)
      (defseq :fg-blue "Foreground Blue" ("ESC" "[34m") :reset :fg-default)
      (defseq :fg-magenta "Foreground Magenta" ("ESC" "[35m") :reset :fg-default)
      (defseq :fg-cyan "Foreground Cyan" ("ESC" "[36m") :reset :fg-default)
      (defseq :fg-white "Foreground White" ("ESC" "[37m") :reset :fg-default)
      (defseq :fg-default "Default Foreground Color" ("ESC" "[39m"))

      ;; Background Colors (Basic)
      (defseq :bg-black "Background Black" ("ESC" "[40m") :reset :bg-default)
      (defseq :bg-red "Background Red" ("ESC" "[41m") :reset :bg-default)
      (defseq :bg-green "Background Green" ("ESC" "[42m") :reset :bg-default)
      (defseq :bg-yellow "Background Yellow" ("ESC" "[43m") :reset :bg-default)
      (defseq :bg-blue "Background Blue" ("ESC" "[44m") :reset :bg-default)
      (defseq :bg-magenta "Background Magenta" ("ESC" "[45m") :reset :bg-default)
      (defseq :bg-cyan "Background Cyan" ("ESC" "[46m") :reset :bg-default)
      (defseq :bg-white "Background White" ("ESC" "[47m") :reset :bg-default)
      (defseq :bg-default "Default Background Color" ("ESC" "[49m"))

      ;; Foreground Colors (Bright)
      (defseq :fg-bright-black "Foreground Bright Black" ("ESC" "[90m") :reset :fg-default)
      (defseq :fg-bright-red "Foreground Bright Red" ("ESC" "[91m") :reset :fg-default)
      ;; ... (add other bright colors similarly)

      ;; Background Colors (Bright)
      (defseq :bg-bright-black "Background Bright Black" ("ESC" "[100m") :reset :bg-default)
      ;; ... (add other bright bg colors similarly)

      ;; 256 Colors
      (defseq :fg-color-256 "Foreground 256-color" ("ESC" "[38;5;" nil "m") :reset :fg-default) ; nil is placeholder for arg
      (defseq :bg-color-256 "Background 256-color" ("ESC" "[48;5;" nil "m") :reset :bg-default)

      ;; True Color (24-bit)
      (defseq :fg-color-24bit "Foreground TrueColor" ("ESC" "[38;2;" nil ";" nil ";" nil "m") :reset :fg-default)
      (defseq :bg-color-24bit "Background TrueColor" ("ESC" "[48;2;" nil ";" nil ";" nil "m") :reset :bg-default)

      ;; Cursor Control
      (defseq :cursor-save-dec "Save cursor position (DEC)" ("ESC" "[s"))
      (defseq :cursor-restore-dec "Restore cursor position (DEC)" ("ESC" "[u"))
      (defseq :cursor-save-sco "Save cursor position (SCO)" ("ESC" "7")) ; DECSC
      (defseq :cursor-restore-sco "Restore cursor position (SCO)" ("ESC" "8")) ; DECRC
      (defseq :cursor-up "Move cursor up" ("ESC" "[" nil "A"))
      (defseq :cursor-down "Move cursor down" ("ESC" "[" nil "B"))
      (defseq :cursor-forward "Move cursor forward" ("ESC" "[" nil "C"))
      (defseq :cursor-back "Move cursor back" ("ESC" "[" nil "D"))
      (defseq :cursor-next-line "Move cursor to next line" ("ESC" "[" nil "E"))
      (defseq :cursor-prev-line "Move cursor to previous line" ("ESC" "[" nil "F"))
      (defseq :cursor-horizontal-absolute "Move cursor to column" ("ESC" "[" nil "G"))
      (defseq :cursor-set-position "Set cursor position row;col" ("ESC" "[" nil ";" nil "H")) ; Also f
      (defseq :cursor-report "Report cursor position" ("ESC" "[6n") :response #'parse-cursor-report-response)
      (defseq :cursor-hide "Hide cursor" ("ESC" "[?25l"))
      (defseq :cursor-show "Show cursor" ("ESC" "[?25h"))

      ;; Erase Functions
      (defseq :erase-screen-down "Erase from cursor to end of screen" ("ESC" "[0J"))
      (defseq :erase-screen-up "Erase from cursor to beginning of screen" ("ESC" "[1J"))
      (defseq :erase-screen "Erase entire screen" ("ESC" "[2J"))
      (defseq :erase-saved-lines "Erase saved lines (XTerm)" ("ESC" "[3J"))
      (defseq :erase-line-end "Erase from cursor to end of line" ("ESC" "[0K"))
      (defseq :erase-line-start "Erase from cursor to start of line" ("ESC" "[1K"))
      (defseq :erase-line "Erase entire line" ("ESC" "[2K"))

      ;; Screen Modes
      (defseq :enable-autowrap "Enable auto line wrapping (DECSET)" ("ESC" "[?7h"))
      (defseq :disable-autowrap "Disable auto line wrapping (DECRST)" ("ESC" "[?7l"))
      (defseq :alt-screen-buffer "Enable alternative screen buffer" ("ESC" "[?1049h"))
      (defseq :normal-screen-buffer "Disable alternative screen buffer" ("ESC" "[?1049l"))
      (defseq :enable-mouse-tracking "Enable X10 mouse tracking (press)" ("ESC" "[?9h"))
      (defseq :disable-mouse-tracking "Disable X10 mouse tracking" ("ESC" "[?9l"))
      (defseq :enable-mouse-btn-event "Enable BTN_EVENT mouse tracking (press+release)" ("ESC" "[?1002h"))
      (defseq :disable-mouse-btn-event "Disable BTN_EVENT mouse tracking" ("ESC" "[?1002l"))
      (defseq :enable-mouse-any-event "Enable ANY_EVENT mouse tracking (press+release+motion)" ("ESC" "[?1003h"))
      (defseq :disable-mouse-any-event "Disable ANY_EVENT mouse tracking" ("ESC" "[?1003l"))
      (defseq :enable-mouse-focus-event "Enable focus in/out events" ("ESC" "[?1004h"))
      (defseq :disable-mouse-focus-event "Disable focus in/out events" ("ESC" "[?1004l"))
      (defseq :enable-mouse-sgr-ext-mode "Enable SGR extended mouse mode" ("ESC" "[?1006h"))
      (defseq :disable-mouse-sgr-ext-mode "Disable SGR extended mouse mode" ("ESC" "[?1006l"))

      ;; Window Title (OSC)
      (defseq :set-window-title "Set window title" ("ESC" "]0;" nil "\x07")) ; \x07 is BEL
      ))

  (defun get-sequence (identifier)
    "Return the escape sequence object for IDENTIFIER."
    (gethash identifier +ansi-escape-sequences+))

  (defun get-reset-sequence (identifier)
    "Return the reset escape sequence id for IDENTIFIER."
    (gethash identifier +ansi-escape-sequences-reset-lookup+))

  (defun lookup-sequence (identifier)
    "Lookup the sequence for IDENTIFIER (can be keyword or string rep)."
    (etypecase identifier
      (keyword (gethash identifier +ansi-escape-sequences+))
      (ansi-sequence identifier)
      (string (gethash (gethash identifier +ansi-escape-sequences-lookup+)
                +ansi-escape-sequences+))))


;;;---------------------------------------------------------------
;;; Style Parsing Utilities (from lowterm/terminal-style.lisp)
;;;---------------------------------------------------------------

  (defun is-csi-final-byte? (char-code)
    "Checks if the character code is a CSI final byte (ASCII 64-126)."
    (and (>= char-code 64) (<= char-code 126)))

  (defun split-seq-if (predicate string)
    "Split STRING into a list of substrings based on characters that match PREDICATE."
    (let ((start 0) result)
      (loop for i from 0 below (length string)
        do (when (funcall predicate (char string i))
             (push (subseq string start i) result)
             (setf start (1+ i))))
      (push (subseq string start) result)
      (nreverse (remove-if (lambda (x) (string= "" x)) result)))) ; Remove empty strings

  (defun parse-parameters (param-chars)
    "Parses a list of parameter characters (digits and ';', ':') into a list of integers."
    (let ((param-str (coerce param-chars 'string)))
      (mapcar (lambda (s) (if (string= "" s) 0 (parse-integer s :junk-allowed t))) ; Default to 0 for empty params
        (split-seq-if (lambda (c) (or (char= c #\;) (char= c #\:))) param-str))))


  (defun collect-csi-params (char-code-list)
    "Parses a list of character codes (after ESC [) into CSI parameters, intermediates, and the final byte.
   Returns (VALUES PARAM-LIST INTERMEDIATE-CHARS FINAL-BYTE-CHAR-CODE)."
    (let ((params-chars '())           ; List to hold parameter characters
           (intermediate-chars '())     ; List to hold intermediate characters
           final-byte-code
           (collecting-params-p t))   ; Flag to indicate if we are collecting params or intermediates

      (loop for code in char-code-list
        do (cond
             ((is-csi-final-byte? code)
               (setf final-byte-code code)
               (return)) ; End of CSI sequence
             ((and (>= code #x30) (<= code #x3F)) ; Parameter bytes 0-9:;<=>?
               (if collecting-params-p
                 (push (code-char code) params-chars)
                 (progn ; Parameter byte after intermediate byte
                   (warn "Parameter byte ~A found after intermediate byte in CSI sequence." code)
                   (push (code-char code) intermediate-chars)))) ; Or handle as error
             ((and (>= code #x20) (<= code #x2F)) ; Intermediate bytes SP-'/'
               (setf collecting-params-p nil) ; Switch to collecting intermediates
               (push (code-char code) intermediate-chars))
             (t ;; Should not happen in a valid CSI
               (warn "Invalid byte ~A in CSI sequence." code)
               (return))))
      (unless final-byte-code
        (error "CSI sequence did not end with a final byte."))

      (values (parse-parameters (nreverse params-chars))
        (nreverse intermediate-chars)
        final-byte-code)))


  (defun parse-sgr-parameters (sgr-params-list)
    "Parses a list of SGR numeric parameters and returns a list of style changes.
   Example: (0) -> '((:reset t))
            (1) -> '((:bold t))
            (31) -> '((:fg-color :red))
            (38 5 200) -> '((:fg-color (:type :xterm :value 200)))
            (38 2 100 150 200) -> '((:fg-color (:type :rgb :r 100 :g 150 :b 200)))"
    (let ((changes '())
           (i 0))
      (labels ((pop-param () (prog1 (nth i sgr-params-list) (incf i)))
                ;; (peek-param () (nth i sgr-params-list))
                (params-left () (- (length sgr-params-list) i)))
        ;; (declare (ignorable peek-param))
        (loop while (< i (length sgr-params-list))
          do (let ((p (pop-param)))
               (cond
                 ((= p 0) (push '(:reset t) changes))
                 ((= p 1) (push '(:bold t) changes))
                 ((= p 2) (push '(:faint t) changes))
                 ((= p 3) (push '(:italic t) changes))
                 ((= p 4) (push '(:underline t) changes))
                 ((= p 5) (push '(:blink t) changes))
                 ((= p 7) (push '(:inverse t) changes))
                 ((= p 8) (push '(:invisible t) changes))
                 ((= p 9) (push '(:strike t) changes))
                 ((= p 21) (push '(:bold nil) changes)) ; double underline, or bold off
                 ((= p 22) (push '(:bold nil) changes) (push '(:faint nil) changes))
                 ((= p 23) (push '(:italic nil) changes))
                 ((= p 24) (push '(:underline nil) changes))
                 ((= p 25) (push '(:blink nil) changes))
                 ((= p 27) (push '(:inverse nil) changes))
                 ((= p 28) (push '(:invisible nil) changes))
                 ((= p 29) (push '(:strike nil) changes))
                 ((and (>= p 30) (<= p 37)) (push (list :fg-color (nth (- p 30) '(:black :red :green :yellow :blue :magenta :cyan :white))) changes))
                 ((= p 39) (push '(:fg-color :default) changes))
                 ((and (>= p 40) (<= p 47)) (push (list :bg-color (nth (- p 40) '(:black :red :green :yellow :blue :magenta :cyan :white))) changes))
                 ((= p 49) (push '(:bg-color :default) changes))
                 ((and (>= p 90) (<= p 97)) (push (list :fg-color (nth (- p 90) '(:bright-black :bright-red :bright-green :bright-yellow :bright-blue :bright-magenta :bright-cyan :bright-white))) changes))
                 ((and (>= p 100) (<= p 107)) (push (list :bg-color (nth (- p 100) '(:bright-black :bright-red :bright-green :bright-yellow :bright-blue :bright-magenta :bright-cyan :bright-white))) changes))
                 ((= p 38) ; Extended color
                   (when (>= (params-left) 1)
                     (let ((type (pop-param)))
                       (cond
                         ((= type 5) ; 256-color mode
                           (when (>= (params-left) 1)
                             (push (list :fg-color `(:type :xterm :value ,(pop-param))) changes)))
                         ((= type 2) ; Truecolor mode
                           (when (>= (params-left) 3)
                             (push (list :fg-color `(:type :rgb :r ,(pop-param) :g ,(pop-param) :b ,(pop-param))) changes)))))))
                 ((= p 48) ; Extended background color
                   (when (>= (params-left) 1)
                     (let ((type (pop-param)))
                       (cond
                         ((= type 5)
                           (when (>= (params-left) 1)
                             (push (list :bg-color `(:type :xterm :value ,(pop-param))) changes)))
                         ((= type 2)
                           (when (>= (params-left) 3)
                             (push (list :bg-color `(:type :rgb :r ,(pop-param) :g ,(pop-param) :b ,(pop-param))) changes)))))))
                 (t (warn "Unknown SGR parameter: ~A" p))))))
      (nreverse changes)))

  (defun parse-csi-sequence (char-code-list)
    "Parses a CSI sequence (list of char codes after ESC [) and returns a structured representation.
   Returns a list like (:type :cursor-up :params (1)) or (:type :sgr :changes ((:bold t) (:fg-color :red)))."
    (multiple-value-bind (params intermediates final-byte-code)
      (collect-csi-params char-code-list)
      (declare (ignore intermediates)) ; Intermediates not commonly used for basic TUI
      (let ((final-char (code-char final-byte-code)))
        (case final-char
          (#\A `(:type :cursor-up :params ,params))
          (#\B `(:type :cursor-down :params ,params))
          (#\C `(:type :cursor-forward :params ,params))
          (#\D `(:type :cursor-back :params ,params))
          (#\E `(:type :cursor-next-line :params ,params))
          (#\F `(:type :cursor-prev-line :params ,params))
          (#\G `(:type :cursor-horizontal-absolute :params ,params))
          (#\H `(:type :cursor-set-position :params ,params)) ; also 'f'
          (#\J `(:type :erase-in-display :params ,params))
          (#\K `(:type :erase-in-line :params ,params))
          (#\m `(:type :sgr :changes ,(parse-sgr-parameters params)))
          (#\n (cond ((equal params '(6)) `(:type :report-cursor-position)) ; DSR CPR
                 ((equal params '(5)) `(:type :report-device-status))   ; DSR status
                 (t `(:type :device-status-report :params ,params :final ,final-char))))
          ;; Add more cases for other CSI sequences as needed
          (otherwise `(:type :unknown-csi :params ,params :final ,final-char))))))

  ;; Helper to convert platform API color/style to SGR sequences
  (defun ansi-fg-color-seq (color-spec)
    (let ((seq-obj nil)
           (args nil))
      (cond
        ((null color-spec)
          (setf seq-obj (get-sequence :fg-default)))
        ((keywordp color-spec)
          (setf seq-obj (get-sequence (find-symbol (string-upcase (format nil "FG-~A" color-spec)) :keyword))))
        ((integerp color-spec)
          (setf seq-obj (get-sequence :fg-color-256))
          (setf args (list color-spec)))
        ((listp color-spec) ; Assuming (R G B) for truecolor, will not be hit if color-spec is nil
          (setf seq-obj (get-sequence :fg-color-24bit))
          (setf args color-spec))
        (t (setf seq-obj (get-sequence :fg-default))))

      (if seq-obj
        (let ((rendered-string (apply #'render-seq seq-obj args)))
          (unless (stringp rendered-string)
            (log:error "ANSI-FG-COLOR-SEQ: render-seq for ~S (spec ~S, args ~S) returned non-string: ~S (type ~A)"
              seq-obj color-spec args rendered-string (type-of rendered-string))
            (return-from ansi-fg-color-seq nil)) ; Return NIL if render-seq failed
          rendered-string)
        (progn
          (log:debug "ANSI-FG-COLOR-SEQ: No seq-obj found for spec ~S" color-spec)
          nil))))

  (defun ansi-bg-color-seq (color-spec)
    (let ((seq-obj nil)
           (args nil))
      (cond
        ((null color-spec)
          (setf seq-obj (get-sequence :bg-default)))
        ((keywordp color-spec)
          (setf seq-obj (get-sequence (find-symbol (string-upcase (format nil "BG-~A" color-spec)) :keyword))))
        ((integerp color-spec)
          (setf seq-obj (get-sequence :bg-color-256))
          (setf args (list color-spec)))
        ((listp color-spec) ; Assuming (R G B) for truecolor, will not be hit if color-spec is nil
          (setf seq-obj (get-sequence :bg-color-24bit))
          (setf args color-spec))
        (t (setf seq-obj (get-sequence :bg-default))))

      (if seq-obj
        (let ((rendered-string (apply #'render-seq seq-obj args)))
          (unless (stringp rendered-string)
            (log:error "ANSI-BG-COLOR-SEQ: render-seq for ~S (spec ~S, args ~S) returned non-string: ~S (type ~A)"
              seq-obj color-spec args rendered-string (type-of rendered-string))
            (return-from ansi-bg-color-seq nil)) ; Return NIL if render-seq failed
          rendered-string)
        (progn
          (log:debug "ANSI-BG-COLOR-SEQ: No seq-obj found for spec ~S" color-spec)
          nil))))

  (defun ansi-attr-seq (attr-keyword activep)
    (let ((seq-obj (get-sequence (find-symbol (format nil "~A~A" attr-keyword (if activep "" "-OFF")) :keyword))))
      (when seq-obj (render-seq seq-obj))))

  (defun sanitize-string-for-logging (input-string)
    "Replaces non-printable characters in a string with their readable representations
    (e.g., , <0x07>) for safe logging."
    (check-type input-string string)
    (with-output-to-string (s)
      (loop for char across input-string
        do (let ((code (char-code char)))
             (cond
               ((= code 27) (write-string "" s))
               ((= code 7)  (write-string "" s))
               ((= code 8)  (write-string "" s))
               ((= code 9)  (write-char #\Tab s)) ; Tab is usually fine in logs
               ((= code 10) (write-char #\Newline s)) ; Newline is usually fine
               ((= code 13) (write-string "" s))
               ((and (>= code 32) (<= code 126)) ; Printable ASCII
                 (write-char char s))
               ;; For characters outside printable ASCII, or other control codes:
               (t (format s "<0x~2,'0X>" code)))))))

  (defun normalize-key-symbol (code)
    "Turn CODE from a cl-inputs key token into a keyword.

Missing key codes are normalized to :UNKNOWN instead of preserving NIL as a
symbol. Downstream event constructors require key identifiers to be keywords
(or characters in older paths), so returning NIL turns a recoverable partial
input token into a type error."
    (cond
      ((null code) :unknown)
      ((keywordp code) code)
      ((characterp code) (intern (string-upcase (string code)) :keyword))
      ((symbolp code) code)
      ((integerp code)
        (intern (format nil "KEY-~D" code) :keyword))
      (t :unknown)))

  (defun %token-char (code)
    (cond
      ((characterp code) code)
      ((and (integerp code) (<= 0 code #xffff))
        (ignore-errors (code-char code)))
      (t nil))))
