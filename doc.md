
Below is a concrete, idiomatic design and API that hits your goals while staying TEA-friendly and fully decoupled.

---

# Recommendation (TL;DR)

1. **Keep `cl-input` pure + push/pull neutral**

   * **Pure decoder**: `(decode-chunk decoder bytes) → (values tokens new-decoder)`.
   * **Stateless tokens** (structs) with `:kind` `:data` `:ts`.
   * **No event/message types**—only input tokens.

2. **Expose two ports** (no third-party deps):

   * **Device Port** generics: open/close/read/write/raw-mode.
   * **Sink Port** generics: a single `accept-token` (+ optional `on-key`/`on-mouse` granularity).
     Default methods are no-ops; you can also pass a plain function as sink.

3. **Offer both Push *and* Pull modes**:

   * **Push**: `start-input-loop :sink <fn-or-sink>` reads, decodes, and pushes tokens to your sink(s).
   * **Pull**: `make-input-source` returns a source object with `next-token` (blocking or timed).

4. **Adapters live elsewhere**:

   * `cl-input-adapters.events` depends on `cl-input` + `cl-events` and implements a sink that publishes to the event bus.
   * `cl-input-adapters.channel` emits to your own channel/queue.
   * None of these contaminate `cl-input`.

This is a common, established pattern (hexagonal architecture + functional core + adapter sinks). It gives you maximal freedom and testability.

---

# `cl-input` — ASDF + packages

```lisp
;;; cl-inputs.asd
(asdf:defsystem "cl-input"
  :description "Terminal input decoding (pure), device port, and sink port."
  :license "MIT" :version "0.1.0"
  :depends-on (#:alexandria #:uiop #:trivial-utf-8)
  :components
  ((:file "src/input/packages")
   (:file "src/input/tokens")     ; token structs, helpers
   (:file "src/input/keymap")     ; escape→semantic mapping
   (:file "src/input/decoder")    ; pure state machine
   (:file "src/input/device")     ; device port (termios impl optional)
   (:file "src/input/sink")       ; sink port (accept-token & friends)
   (:file "src/input/loop")       ; push & pull runners
   (:file "src/input/api")))
```

```lisp
;;; src/input/packages.lisp
(uiop:define-package :cl-inputs.tokens
  (:use :cl :alexandria)
  (:export #:input-token #:make-token #:input-token-kind #:token-data #:token-ts
           ;; common :kind values
           +k-key+ +k-mouse+ +k-resize+ +k-paste+ +k-focus+))

(uiop:define-package :cl-inputs.keymap
  (:use :cl :alexandria)
  (:export #:*default-keymap* #:lookup-seq #:canonicalize-key))

(uiop:define-package :cl-inputs.decoder
  (:use :cl :alexandria :cl-inputs.tokens :cl-inputs.keymap)
  (:export
   ;; immutable decoder state (can be a plist/struct)
   #:make-decoder #:decoder-state
   ;; functional decoding step:
   #:decode-chunk))

(uiop:define-package :cl-inputs.device
  (:use :cl :alexandria)
  (:export
   ;; Device port (generics; default stub prints warnings)
   #:open-device #:close-device
   #:enable-raw-mode #:disable-raw-mode
   #:device-read-bytes #:device-write-bytes
   ;; Optional default TTY impl constructor:
   #:make-tty-device))

(uiop:define-package :cl-inputs.sink
  (:use :cl :alexandria :cl-inputs.tokens)
  (:export
   ;; Sink port (generics; defaults are NO-OP)
   #:accept-token #:on-key #:on-mouse #:on-resize #:on-paste #:on-focus
   ;; Helpers for composing sinks:
   #:tee-sink #:fn-sink))

(uiop:define-package :cl-inputs.api
  (:use :cl :alexandria :cl-inputs.tokens :cl-inputs.decoder :cl-inputs.device :cl-inputs.sink)
  (:export
   ;; Push mode
   #:start-input-loop #:stop-input-loop
   ;; Pull mode
   #:make-input-source #:next-token #:close-input-source
   ;; Quick one-shot read helpers
   #:read-tokens #:with-raw-input))
```

---

## Tokens (pure data)

```lisp
(in-package :cl-inputs.tokens)

(defparameter +k-key+    :key)
(defparameter +k-mouse+  :mouse)
(defparameter +k-resize+ :resize)
(defparameter +k-paste+  :paste)
(defparameter +k-focus+  :focus)

(defstruct input-token
  kind   ;; one of the +k-*+ keywords
  data   ;; plist describing the token (e.g., :code :enter :mods (:ctrl))
  ts)    ;; timestamp (universal-time or monotonic)

(defun make-token (kind data &optional ts)
  (make-input-token :kind kind :data data :ts (or ts (get-universal-time))))
```

---

## Keymap (pure lookup)

```lisp
(in-package :cl-inputs.keymap)

(defparameter *default-keymap*
  ;; minimal examples; extend with your full table
  `((,(list #\Esc #\[ #\A) :up)
    (,(list #\Esc #\[ #\B) :down)
    (,(list #\Esc #\[ #\C) :right)
    (,(list #\Esc #\[ #\D) :left)
    (,(list #\Return)      :enter)
    (,(list #\Tab)         :tab)
    (,(list #\Backspace)   :backspace)))

(defun lookup-seq (octets &optional (table *default-keymap*))
  (let ((match (find octets table
                     :test (lambda (seq entry)
                             (equal seq (first entry))))))
    (and match (second match))))

(defun canonicalize-key (char &key ctrl alt shift)
  ;; turn raw char + modifiers into a canonical key symbol/plist
  (cond
    ((and ctrl (<= (char-code char) 31)) :ctrl-<control-code>)
    (t (string-downcase (string char)))))
```

---

## Decoder (pure state machine)

```lisp
(in-package :cl-inputs.decoder)

;; You can keep the state as a plist to honor your “no mutable class slots” ethos.
(defun make-decoder (&key (buf #()) (paste-mode :off))
  (list :buf buf :paste paste-mode))

(defun decoder-state (dec) dec)

(defun %emit-key (code ts)
  (cl-inputs.tokens:make-token cl-inputs.tokens:+k-key+ `(:code ,code) ts))

(defun decode-chunk (decoder octet-vector &key (timestamp (get-universal-time)))
  "Pure step: consume OCTET-VECTOR, return (values tokens new-decoder).
   Keep incomplete escape sequences in decoder’s buffer."
  (let* ((buf (or (getf decoder :buf) #()))
         (bytes (concatenate '(vector (unsigned-byte 8)) buf octet-vector))
         (pos 0)
         (out '()))
    (labels ((take (n) (prog1 (subseq bytes pos (min (length bytes) (+ pos n)))
                          (incf pos n)))
             (remaining () (- (length bytes) pos))
             (peek (n) (subseq bytes pos (min (length bytes) (+ pos n)))))
      (loop while (< pos (length bytes)) do
        ;; extremely simplified: try fixed sequences first
        (let* ((window (peek 6)) ; enough to match common CSI seqs
               (match (cl-inputs.keymap:lookup-seq (coerce window 'list))))
          (cond
            (match
             ;; matched a full escape seq → emit semantic key
             (let ((len (length (first (find (coerce window 'list)
                                             cl-inputs.keymap:*default-keymap*
                                             :test (lambda (seq entry)
                                                     (equal seq (first entry))))))))
               (take len)
               (push (%emit-key match timestamp) out)))
            (t
             ;; fall back to single byte char
             (let ((b (aref bytes pos)))
               (incf pos)
               (cond
                 ((= b 27)
                  ;; partial ESC? stash back (naive; improve with timeouts)
                  (decf pos) (return))
                 (t
                  (push (%emit-key (code-char b) timestamp) out))))))))
      (values (nreverse out)
              (list :buf (subseq bytes pos) :paste (getf decoder :paste))))))
```

*(You’ll likely extend this with CSI parsing, mouse tracking, paste bracketed mode, focus in/out, etc. The form is the key: **pure** state in/state out.)*

---

## Device Port (defgenerics, default stubs)

```lisp
(in-package :cl-inputs.device)

(defgeneric open-device (&key stream)
  (:documentation "Return a device handle (whatever your impl wants)."))

(defgeneric close-device (dev))
(defgeneric enable-raw-mode (dev))
(defgeneric disable-raw-mode (dev))

(defgeneric device-read-bytes (dev buffer start end)
  (:documentation "Fill BUFFER[start..end). Return number of bytes or :eof."))

(defgeneric device-write-bytes (dev buffer start end)
  (:documentation "Optional; return bytes written."))

;;; Default fallbacks (do nothing) so the protocol is optional to implement
(defmethod open-device (&key stream) (or stream *standard-input*))
(defmethod close-device (dev) (declare (ignore dev)) t)
(defmethod enable-raw-mode (dev) (declare (ignore dev)) t)
(defmethod disable-raw-mode (dev) (declare (ignore dev)) t)
(defmethod device-read-bytes (dev buffer start end)
  ;; Portable but blocking character read; replace with a termios impl in your app.
  (declare (ignore buffer start end))
  (declare (ignore dev))
  :eof)
(defmethod device-write-bytes (dev buffer start end)
  (declare (ignore dev buffer start end)) 0)

;;; Optional constructor for your real termios impl
(defun make-tty-device (&key (path "/dev/tty")) (declare (ignore path)) '(:tty)))
```

---

## Sink Port (defgenerics, function sinks, tee sinks)

```lisp
(in-package :cl-inputs.sink)

(defgeneric accept-token (sink token)
  (:documentation "Main delivery method. Default: NO-OP."))

(defgeneric on-key (sink token))
(defgeneric on-mouse (sink token))
(defgeneric on-resize (sink token))
(defgeneric on-paste (sink token))
(defgeneric on-focus (sink token))

;; Defaults: do nothing
(defmethod accept-token ((sink t) (tok cl-inputs.tokens:input-token)) (declare (ignore sink tok)) nil)
(defmethod on-key   ((sink t) (tok cl-inputs.tokens:input-token)) (declare (ignore sink tok)) nil)
(defmethod on-mouse ((sink t) (tok cl-inputs.tokens:input-token)) (declare (ignore sink tok)) nil)
(defmethod on-resize((sink t) (tok cl-inputs.tokens:input-token)) (declare (ignore sink tok)) nil)
(defmethod on-paste ((sink t) (tok cl-inputs.tokens:input-token)) (declare (ignore sink tok)) nil)
(defmethod on-focus ((sink t) (tok cl-inputs.tokens:input-token)) (declare (ignore sink tok)) nil)

;; Convenience: if user passes a plain function, treat it as accept-token
(defun fn-sink (fn)
  (lambda (token) (funcall fn token)))

(defun tee-sink (&rest sinks)
  (lambda (token)
    (dolist (s sinks)
      (cond
        ((functionp s) (funcall s token))
        (t (accept-token s token)))))))
```

---

## Loop (push & pull)

```lisp
(in-package :cl-inputs.api)

(defstruct input-loop dev thread stop? decoder sink)

(defun %deliver (sink token)
  (cond
    ((functionp sink) (funcall sink token))
    (t
     (accept-token sink token)
     (ecase (cl-inputs.tokens:input-token-kind token)
       (:key    (on-key sink token))
       (:mouse  (on-mouse sink token))
       (:resize (on-resize sink token))
       (:paste  (on-paste sink token))
       (:focus  (on-focus sink token))))))

(defun start-input-loop (&key (device (cl-inputs.device:open-device))
                              (sink (fn-sink (lambda (_tok) (declare (ignore _tok)) nil)))
                              (decoder (cl-inputs.decoder:make-decoder)))
  "Reads from DEVICE, decodes via DECODER, pushes to SINK. Returns an INPUT-LOOP handle."
  (cl-inputs.device:enable-raw-mode device)
  (let ((loop (make-input-loop :dev device :sink sink :decoder decoder)))
    (setf (input-loop-thread loop)
          (bt:make-thread
           (lambda ()
             (let ((buf (make-array 64 :element-type '(unsigned-byte 8))))
               (unwind-protect
                    (loop until (input-loop-stop? loop) do
                      (let ((n (cl-inputs.device:device-read-bytes device buf 0 (length buf))))
                        (when (or (eql n :eof) (null n)) (return))
                        (multiple-value-bind (tokens dec2)
                            (cl-inputs.decoder:decode-chunk (input-loop-decoder loop)
                                                           (subseq buf 0 n))
                          (setf (input-loop-decoder loop) dec2)
                          (dolist (t tokens) (%deliver (input-loop-sink loop) t)))))
                 (cl-inputs.device:disable-raw-mode device)))))
           :name "cl-input-loop"))
    loop))

(defun stop-input-loop (loop)
  (setf (input-loop-stop? loop) t)
  (cl-inputs.device:close-device (input-loop-dev loop))
  t)

;;; Pull mode: a source object that yields tokens on demand
(defstruct input-source dev decoder buf)

(defun make-input-source (&key (device (cl-inputs.device:open-device))
                               (decoder (cl-inputs.decoder:make-decoder)))
  (cl-inputs.device:enable-raw-mode device)
  (make-input-source :dev device :decoder decoder :buf (make-array 64 :element-type '(unsigned-byte 8))))

(defun next-token (src &key (timeout nil))
  "Blocking read (or timed if DEVICE supports it). Returns a token or NIL on EOF."
  (declare (ignore timeout)) ; extend in your device impl
  (let* ((n (cl-inputs.device:device-read-bytes (input-source-dev src) (input-source-buf src) 0 64)))
    (cond
      ((or (eql n :eof) (null n)) nil)
      (t
       (multiple-value-bind (tokens dec2)
           (cl-inputs.decoder:decode-chunk (input-source-decoder src)
                                          (subseq (input-source-buf src) 0 n))
         (setf (input-source-decoder src) dec2)
         (first tokens))))))

(defun close-input-source (src)
  (cl-inputs.device:disable-raw-mode (input-source-dev src))
  (cl-inputs.device:close-device (input-source-dev src))
  t)

;;; Convenience helper
(defmacro with-raw-input ((dev) &body body)
  `(let ((,dev (cl-inputs.device:open-device)))
     (unwind-protect
          (progn (cl-inputs.device:enable-raw-mode ,dev) ,@body)
       (cl-inputs.device:disable-raw-mode ,dev)
       (cl-inputs.device:close-device ,dev))))
```

---

# Why this is superior (and widely used)

* **Dependency inversion**: `cl-input` depends on *no one*. Others depend on it.
* **Hexagonal/ports**: device + sink ports are small, explicit, testable.
* **Functional core**: the decoder is pure; it’s trivial to fuzz, snapshot, and golden-test.
* **Two integration styles**: push (observers/sinks) and pull (iterators/sources).
* **Optional adapters**: you keep “events”, “channels”, “renderers” in *separate* systems:

  * `cl-input-adapters.events` (depends on `cl-input` + `cl-events`)

    ```lisp
    (defclass events-sink () ((bus :initarg :bus :reader bus)))
    (defmethod accept-token ((s events-sink) tkn)
      ;; publish whatever structure you want on your bus…
      (publish-something (bus s) (token->your-message tkn)))
    ```
  * `cl-input-adapters.channels` (depends on your channel lib)

    ```lisp
    (defclass chan-sink () ((ch :initarg :ch :reader ch)))
    (defmethod accept-token ((s chan-sink) tkn) (chan-put (ch s) tkn))
    ```

No matter what the app’s message/event shape is, **`cl-input` doesn’t care**. It outputs **tokens**; your adapters care.

---

# If you prefer “only generics, no callbacks”

You can still keep it protocol-only:

* Require apps to provide a **sink object** implementing `accept-token` (and friends).
* Ship a default `null-sink` that discards tokens, and a `debug-sink` that prints.
* Keep `start-input-loop` accepting only **sink objects** (no function).
* If someone wants a function, they wrap it in `fn-sink`, which is just an object with a method.

The design above already supports both styles (function or generic), so you can pick one and keep the other as sugar.

---

# What about output (ANSI/terminal writes)?

Exactly the same pattern, but **in a different library** (e.g., `cl-term`):

* Device port generics you already have.
* A small **“writer”** API `(render-frame dev bytes)` with adapters for *your* renderer.
* Optional **capabilities** query (supports 256 colors? truecolor? mouse tracking?) as a device generic.

This keeps input and output independent, but they can share the same device instance if you want.

---

# Closing notes

* This aligns with your “no mutable class slots” preference: the decoder state is a *value* that comes out and goes back in.
* TEA friendliness: your app loop (in `cl-events` or elsewhere) simply chooses a sink that maps tokens → messages or directly invokes `update`.
* Testing is a breeze: feed byte arrays into `decode-chunk`, assert emitted tokens.

1. the backend “port” (defgenerics),
2. a tiny **registry** so you can select backends by keyword,
3. a **capabilities** contract so the decoder can negotiate (mouse, paste, focus),
4. three concrete backends: **:tty**, **:faketerm**, **:urxvt** (via PTY),
5. how these fit your push/pull sinks from the previous answer.

---

# 1) Backend Port (stable protocol)

```lisp
;;;; cl-inputs.device — the only thing the core depends on

(defgeneric make-device (backend &key &allow-other-keys)
  (:documentation
   "Construct a device instance for BACKEND (a keyword or descriptor).
    No global singletons; return a self-contained handle."))

(defgeneric device-kind (dev) (:documentation "Return a keyword like :tty, :faketerm, :urxvt."))

(defgeneric open-device (dev))
(defgeneric close-device (dev))

(defgeneric enable-raw-mode (dev))
(defgeneric disable-raw-mode (dev))

(defgeneric device-read-bytes (dev buffer start end)
  (:documentation "Blocking or timed read. Return N bytes or :eof."))

(defgeneric device-write-bytes (dev buffer start end)
  (:documentation "Optional for echo/tests. Return N written."))

(defgeneric device-capabilities (dev)
  (:documentation
   "Return a plist describing negotiated/known features, e.g.:
    (:truecolor t
     :mouse :sgr             ; :x10 | :urxvt | :sgr
     :focus-events t
     :bracketed-paste t
     :winch t                ; supports reporting resize
     :term (\"xterm-256color\"))"))

(defgeneric device-set-modes (dev modes)
  (:documentation
   "Enable terminal modes (mouse tracking, bracketed paste, focus in/out).
    MODES is a plist, e.g. (:mouse :sgr :paste t :focus t)."))
```

### Why this is good

* **Single seam**: all backends implement *only* these methods.
* **No dependency direction**: `cl-input` can do push or pull using any backend instance.
* **Negotiation**: `device-capabilities` + `device-set-modes` is enough to flip on bracketed paste/focus/mouse for terminals that support it, while leaving FakeTerm as no-op.

---

# 2) Backend selection registry (ergonomics, not coupling)

```lisp
(defvar *backend-registry* (make-hash-table :test 'equal))

(defun register-backend (key ctor)
  "CTOR is a function (&rest initargs) -> DEV."
  (setf (gethash key *backend-registry*) ctor) key)

(defun make-device* (key &rest initargs)
  (let ((ctor (gethash key *backend-registry*)))
    (unless ctor (error "No backend registered for ~S" key))
    (apply ctor initargs)))

;; Optional sugar so users can do:
;; (start-input-loop :device (make-device* :tty :path "/dev/tty"))
```

You keep this **in cl-input**, but individual backends live in separate files/systems and call `register-backend`.

---

# 3) Capability-led decoding

Your **decoder** stays pure. Before starting the loop, you:

1. call `(device-capabilities dev)`
2. call `(device-set-modes dev '(:paste t :focus t :mouse :sgr))` (or a subset)
3. hold that capability plist in the decoder state (it may affect the escape parser)

This lets FakeTerm say `(:mouse nil :paste nil :focus nil)`; URxvt might say `(:mouse :urxvt :paste t :focus t)`; /dev/tty depends on `$TERM` and your `device-set-modes` success.

---

# 4) Three concrete backends

## A) `/dev/tty` backend (direct TTY)

```lisp
;;;; src/input/backends/tty.lisp

(defstruct tty-device path in out raw-enabled?)

(defun %open-stream (path direction)
  (ecase direction
    (:in  (open path :direction :input  :element-type '(unsigned-byte 8) :if-does-not-exist :error))
    (:out (open path :direction :output :element-type '(unsigned-byte 8) :if-does-not-exist :error))))

(defun %termios-raw-mode (dev enable-p)
  ;; Stub: implement via CFFI (cf. cfmakeraw) or call out to `stty` if acceptable.
  (declare (ignore dev enable-p))
  t)

(defun %tty-capabilities ()
  ;; Minimal default; detect more via $TERM or DA/XT* queries if you wish.
  (list :truecolor t :mouse :sgr :paste t :focus t :winch t :term (uiop:getenv "TERM")))

;; registry ctor
(register-backend :tty
  (lambda (&key (path "/dev/tty"))
    (make-tty-device :path path)))

(defmethod device-kind ((dev tty-device)) :tty)

(defmethod open-device ((dev tty-device))
  (let ((in (%open-stream (tty-device-path dev) :in))
        (out (%open-stream (tty-device-path dev) :out)))
    (setf (tty-device-in dev) in
          (tty-device-out dev) out)
    dev))

(defmethod close-device ((dev tty-device))
  (ignore-errors (close (tty-device-in dev)))
  (ignore-errors (close (tty-device-out dev)))
  t)

(defmethod enable-raw-mode ((dev tty-device))
  (setf (tty-device-raw-enabled? dev) (%termios-raw-mode dev t)))

(defmethod disable-raw-mode ((dev tty-device))
  (%termios-raw-mode dev nil))

(defmethod device-read-bytes ((dev tty-device) buffer start end)
  (read-sequence buffer (tty-device-in dev) :start start :end end))

(defmethod device-write-bytes ((dev tty-device) buffer start end)
  (write-sequence buffer (tty-device-out dev) :start start :end end))

(defmethod device-capabilities ((dev tty-device)) (%tty-capabilities))

(defmethod device-set-modes ((dev tty-device) modes)
  ;; Emit CSI to enable modes (mouse, paste, focus). No-op if your renderer sets them.
  (declare (ignore dev modes)) t)
```

> If you already have a termios layer, just wire those calls where the stubs are.

---

## B) FakeTerm backend (deterministic tests)

**Use cases:** golden tests for decoding/layout; capture output; inject scripted inputs.

Design: it’s a **loopback** device with two queues (or files) — one for incoming **bytes to read** and one for **bytes written** by the app. You can also read scripted sequences from a file to simulate a user.

```lisp
;;;; src/input/backends/faketerm.lisp

(defstruct faketerm-device in-queue out-queue caps)

(register-backend :faketerm
  (lambda (&key (script nil) (caps '(:truecolor t :mouse nil :paste nil :focus nil)))
    ;; SCRIPT may be a list of octet vectors or a file path to preload bytes.
    (let ((in (make-queue)) (out (make-queue)))
      (when (and script (pathnamep script))
        (with-open-file (s script :element-type '(unsigned-byte 8))
          (loop with buf = (make-array 4096 :element-type '(unsigned-byte 8))
                for n = (read-sequence buf s) while (> n 0)
                do (queue-push in (subseq buf 0 n)))))
      (make-faketerm-device :in-queue in :out-queue out :caps caps))))

(defun make-queue () (list)) ;; replace with your thread-safe queue if needed
(defun queue-push (q x) (nconc q (list x)))
(defun queue-pop  (q) (if (endp q) nil (prog1 (car q) (setf (cdr q) (cdr q)))))

(defmethod device-kind ((dev faketerm-device)) :faketerm)
(defmethod open-device ((dev faketerm-device)) dev)
(defmethod close-device ((dev faketerm-device)) t)
(defmethod enable-raw-mode ((dev faketerm-device)) t)
(defmethod disable-raw-mode ((dev faketerm-device)) t)

(defmethod device-read-bytes ((dev faketerm-device) buffer start end)
  (let ((chunk (queue-pop (faketerm-device-in-queue dev))))
    (if (null chunk) :eof
        (progn (replace buffer chunk :start1 start)
               (length chunk)))))

(defmethod device-write-bytes ((dev faketerm-device) buffer start end)
  (queue-push (faketerm-device-out-queue dev) (subseq buffer start end))
  (- end start))

(defmethod device-capabilities ((dev faketerm-device)) (copy-list (faketerm-device-caps dev)))
(defmethod device-set-modes ((dev faketerm-device) _modes) (declare (ignore _modes)) t)

;;; Test helpers:
(defun faketerm-inject! (dev octets) (queue-push (faketerm-device-in-queue dev) octets))
(defun faketerm-captured (dev) (copy-list (faketerm-device-out-queue dev)))
```

* For **layout/render** golden tests, pair this with your renderer’s output writer so you can diff frames.
* For **decoder tests**, inject `faketerm-inject!` chunks and assert emitted tokens.

---

## C) URxvt backend (PTY-spawned emulator)

**Goal:** spawn an emulator attached to a PTY and drive it like a “virtual /dev/tty”.

Implementation choices:

* Use `trivial-pty` or your own CFFI against `posix_openpt/grantpt/unlockpt/ptsname`.
* Launch `urxvt` (or other emulator) against the slave PTY. Keep the master FD on your side.
* Implement read/write against the master FD.

Below is a schematic; swap the PTY bits with your preferred library:

```lisp
;;;; src/input/backends/urxvt.lisp

(defstruct urxvt-device proc master-fd caps)

(register-backend :urxvt
  (lambda (&key (cmd "urxvt") (args '()))
    ;; 1) allocate pty {master, slave}
    (multiple-value-bind (master-fd slave-path)
        (allocate-pty) ;; <- your impl (trivial-pty or CFFI)
      ;; 2) spawn urxvt with its stdio bound to the *slave*
      (let* ((proc (uiop:launch-program
                    (append (list cmd) args)
                    :input  slave-path
                    :output slave-path
                    :error-output slave-path
                    :detached t)))
        (make-urxvt-device :proc proc
                           :master-fd master-fd
                           :caps '(:truecolor t :mouse :urxvt :paste t :focus t :winch t))))))

(defmethod device-kind ((dev urxvt-device)) :urxvt)
(defmethod open-device ((dev urxvt-device)) dev)
(defmethod close-device ((dev urxvt-device))
  (ignore-errors (uiop:terminate-process (urxvt-device-proc dev)))
  (ignore-errors (close-fd (urxvt-device-master-fd dev)))
  t)

(defmethod enable-raw-mode ((dev urxvt-device)) t)
(defmethod disable-raw-mode ((dev urxvt-device)) t)

(defmethod device-read-bytes ((dev urxvt-device) buffer start end)
  (posix-read (urxvt-device-master-fd dev) buffer start end))  ;; your fd read

(defmethod device-write-bytes ((dev urxvt-device) buffer start end)
  (posix-write (urxvt-device-master-fd dev) buffer start end)) ;; your fd write

(defmethod device-capabilities ((dev urxvt-device)) (copy-list (urxvt-device-caps dev)))
(defmethod device-set-modes ((dev urxvt-device) modes)
  ;; Send CSI to set mouse/focus/paste. Most emulators mirror xterm sequences.
  (declare (ignore modes)) t)
```

*(If you later want **headless** URxvt for CI, keep the PTY; no X needed if you don’t require a visible window, or use an xfvb head.)*

---

# 5) Using backends with the input loop (push & pull)

**Push mode** (tokens → sink):

```lisp
(let* ((dev (make-device* :tty :path "/dev/tty"))
       (loop (cl-inputs:start-input-loop
              :device (open-device dev)
              :sink   (cl-inputs.sink:fn-sink
                        (lambda (tok) (my-handoff tok)))
              :decoder (cl-inputs.decoder:make-decoder))))
  ;; later …
  (cl-inputs.api:stop-input-loop loop))
```

**Swap backends at runtime**:

```lisp
(defparameter *backend* :faketerm)
(let ((dev (apply #'make-device* *backend* '(:script #(#x1b #\[ #\x41))))) ;; ESC [ A == Up
  (cl-inputs.api:read-tokens dev)) ;; your helper that reads once, returns tokens
```

**Pull mode** (blocking token reads):

```lisp
(let* ((dev (make-device* :urxvt))
       (src (cl-inputs.api:make-input-source :device (open-device dev))))
  (loop for tok = (cl-inputs.api:next-token src) while tok do (consume tok)))
```

---

## Bonus: features that scale nicely with this split

* **Resize tokens**: either produce them from the decoder when a SIGWINCH-aware backend reports size change (`device-capabilities :winch t`), or poll `device-window-size` (you can add such a generic) on a heartbeat.
* **Mouse modes**: enable via `(device-set-modes dev '(:mouse :sgr))` and teach the decoder to parse SGR/X10/URxvt variants based on `device-capabilities`.
* **Paste/focus**: bracketed paste (`\e[?2004h`) and focus in/out (`\e[?1004h`) are toggled the same way; decoder emits `:paste` and `:focus` tokens.
* **Trace & golden tests**: FakeTerm captures everything; you can snapshot `device-write-bytes` and assert it matches your expected ANSI frames.

---

## Why this fits your ethos

* **No dependency** from `cl-input` to `cl-events` (or anything else).
* **No mutable component classes**: backends are opaque handles; the decoder state is pure data.
* **TEA-friendly**: sinks remain the sole “out port.”
* **Extensible**: adding `:wezterm`, `:kitty`, `:linux-vt`, `:ssh-remote` is a new file that registers a constructor and implements the same port.

If you want, I can package these three backends as `cl-input-backends/tty`, `cl-input-backends/faketerm`, and `cl-input-backends/urxvt` with the registry already wired, plus a minimal PTY layer (either CFFI or `trivial-pty`) and a couple of FiveAM tests that snapshot decoder outputs.
