# cl-inputs

`cl-inputs` is a reusable terminal-input library for Common Lisp. It owns byte decoding, semantic input tokens, terminal device ports, fake terminals, sinks, and synchronous/asynchronous input loops. ElmTUI consumes these APIs but is not part of the library.

## Release status

The current standalone candidate version is **0.2.0** for `cl-inputs`,
`cl-inputs/events`, `cl-inputs/tests`, and `cl-inputs/events-tests`. This repository was extracted from
the clean ElmTUI `cl-inputs/` subtree with its relevant Git lineage preserved.
It has not been published to Quicklisp, Ultralisp, or CLPM.

The inherited Git history also contains an older `v0.2.0` tag pointing at the
historical ElmTUI release commit, not at this standalone release candidate. It
must not be interpreted or moved as part of ordinary standalone qualification;
release/tag lineage needs a separately authorized decision before publication.

The qualified implementation boundary is SBCL on POSIX/Linux. The primary
system uses SB-POSIX and terminal-device code, so no non-SBCL or non-POSIX
portability claim is made. The `cl-inputs` package is the convenience facade;
focused `cl-inputs.*` packages expose decoder, token, keymap, sink, loop,
protocol/routing, device, and terminal APIs. `cl-inputs.events` belongs only to the optional
`cl-inputs/events` adapter system.

## Core boundary

The primary `cl-inputs` system is input-domain code. It does not require ElmTUI or `cl-events`. Event-bus integration is exposed only through the secondary `cl-inputs/events` system; loading core `cl-inputs` does not load or probe that adapter.

### Public API and system boundary

| ASDF system | Runtime/test packages | Dependency boundary | Intended surface |
| --- | --- | --- | --- |
| `cl-inputs` | `cl-inputs` facade plus `cl-inputs.api`, `.tokens`, `.keymap`, `.escape`, `.protocol`, `.decoder`, `.sink`, `.routing`, `.device.*`, `.terminal.*`, `.adapters`, `.util` | Core only; no `cl-events` and no ElmTUI path dependency | Public runtime API and focused extension seams |
| `cl-inputs/events` | `cl-inputs.events` | Explicitly depends on `cl-inputs` + `cl-events` | Optional event-bus adapter only |
| `cl-inputs/tests` | `cl-inputs.tests.*` | `cl-inputs` + FiveAM; no `cl-events` | Core regression/qualification only |
| `cl-inputs/events-tests` | `cl-inputs.tests.events-adapter` | `cl-inputs/events` + FiveAM | Optional-adapter regression only |

The `cl-inputs` facade reexports the main source, token, decoder, routing,
device-port, sink, keymap, and terminal-control API. Low-level raw protocol
recognition remains available through `cl-inputs.protocol`, but is not reexported
by the facade. Backend-specific constructors and deterministic test helpers live
in their focused packages rather than expanding the facade.

For device extension, use `cl-inputs.device.api` generics. Unsupported generic
operations signal the public `device-error` condition. `make-device` selects the
`:tty`, `:faketerm`, and `:urxvt` backends; `cl-inputs.device.tty`
also exports `make-tty-device`. Terminal drawing/control generics live in
`cl-inputs.terminal.api`; `get-terminal-size` returns WIDTH and HEIGHT as two
values when known. Faketerm is deterministic-test qualified, TTY qualification
permits only the explicit no-controlling-TTY skip, and URxvt remains compile/load
qualified rather than a live terminal portability claim.

### 0.2.0 compatibility decisions

- `cl-inputs.sink:event-bus-sink`, `cl-inputs.sink:token->event`, and their
  former facade reexports are intentionally removed. Load `cl-inputs/events`
  explicitly and use `cl-inputs.events:event-bus-sink` or
  `cl-inputs.events:token->event`. This is the required migration that keeps
  the core system free of dynamic `cl-events` loading.
- The external symbol `cl-inputs.device.api:device-enable-raw-char-mode` is
  removed because no function, generic, macro, or variable ever implemented
  it. Use `enable-raw-char-mode`; this corrects a phantom 0.1.x export.
- Owned input sources now centralize open/raw/nonblocking/close lifecycle.
  `make-ready-input-source` delegates to that ownership model. Callers that
  deliberately retain device ownership should construct `make-input-source`
  with `:owns-device-p nil` and manage the device lifecycle themselves.

## Features

- incremental ANSI/escape-sequence decoder;
- semantic key, mouse, resize, paste, focus, terminal-response, and protocol-diagnostic tokens;
- explicit user-input vs terminal-response routing with bounded reply correlation;
- key-sequence mapping and canonicalization;
- TTY, fake-terminal, and URxvt-oriented device implementations;
- push sinks and pull input sources;
- bounded waits and deterministic fake-device tests;
- terminal capability/mode helpers and typed cursor/status/device-attribute replies;
- optional `cl-events` bus adapter.

## Loading

```lisp
(asdf:load-system "cl-inputs")
```

For optional `cl-events` integration:

```lisp
(asdf:load-system "cl-inputs/events")
```

The optional adapter declares `cl-events` as an ASDF dependency. Consumers must
make a compatible `cl-events` system ASDF-discoverable before loading it. When
that dependency is available, `(asdf:test-system "cl-inputs/events")` runs the
separate optional adapter regression suite. The library-local CLPM bundle
intentionally does not install `cl-events` or refer to a `../cl-events` sibling
checkout; the normal core suite therefore qualifies primary `cl-inputs` without
hidden checkout state.

No standalone ASDF system consults the historical ElmTUI checkout. Optional
adapter qualification is valid only when a compatible `cl-events` system is
independently ASDF-discoverable.

## Terminal-response routing

`next-token` exposes only established user-input kinds. Syntactically valid
terminal replies such as cursor-position, device-status, and device-attribute
responses are routed to the source's response router instead of appearing as
keys. Unknown or malformed protocol sequences are retained on a separate bounded
diagnostic path.

For a supported read-only query, register-before-write ordering is handled by
`send-terminal-query`; `wait-terminal-response` can then pump the same source
without consuming unrelated user input:

```lisp
(let ((source (cl-inputs.loop:make-input-source :device device)))
  (unwind-protect
       (let* ((correlation
                (cl-inputs.loop:send-terminal-query
                 source :cursor-position :timeout 0.5d0))
              (response
                (cl-inputs.loop:wait-terminal-response
                 source correlation :timeout 0.5d0)))
         ;; RESPONSE is a :terminal-response token when matched.
         ;; Any keys observed while waiting remain queued for NEXT-TOKEN.
         response)
    (cl-inputs.loop:close-input-source source)))
```

Correlations have absolute monotonic deadlines and a bounded pending set. A
reply observed at or after its deadline cannot satisfy that correlation; it is
retained as unmatched protocol traffic instead. Custom protocol extensions can
use `expect-terminal-response` before emitting their own query bytes. Correlations
of the same response type match in registration FIFO order. Explicitly cancelled
correlations are terminal and skipped by matching. A short or failed query write
cancels its just-registered correlation. Closing, cancelling, reaching EOF, or a
terminal source error while `wait-terminal-response` is pumping the source also
cancels an otherwise-pending correlation; a caller-only wait timeout does not,
because the correlation retains its own absolute deadline.

TTY rendering/device helpers never read query responses directly. ANSI query
metadata names the expected response type; byte consumption and correlation stay
inside the input source so terminal replies cannot race normal user input.

## CLPM

From this directory:

```sh
CLPM_HOME=.cache/clpm clpm bundle install
CLPM_HOME=.cache/clpm clpm bundle exec --with-client sbcl -- \
  --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval '(asdf:load-system "cl-inputs")'
```

The core bundle intentionally does not need a sibling ElmTUI checkout.

## Example

```lisp
(let ((decoder (cl-inputs.decoder:make-decoder)))
  (multiple-value-bind (tokens next-decoder)
      (cl-inputs.decoder:decode-chunk
       decoder
       (cl-inputs.util:string-to-utf-8-bytes "x"))
    (declare (ignore next-decoder))
    (first tokens)))
```

For integration tests and application code, `:faketerm` provides deterministic injected input without a controlling TTY.

## Testing

```sh
CLPM_HOME=.cache/clpm clpm bundle exec --with-client sbcl -- \
  --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval '(asdf:test-system "cl-inputs")'
```

One TTY-specific test may be skipped in non-interactive processes without a controlling terminal; that environment skip is explicitly reported rather than silently passed.

## Dependencies

Core runtime: Alexandria, UIOP/ASDF, Bordeaux Threads, SB-POSIX on the qualified SBCL/POSIX platform, and log4cl. FiveAM is test-only. `cl-events` is required only by the optional events adapter.

## Versioning

`cl-inputs` follows semantic versioning independently of ElmTUI. Pre-1.0 incompatible public API changes increment the minor version.

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT; see [LICENSE](LICENSE).
