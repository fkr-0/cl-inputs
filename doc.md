# cl-inputs 0.2.0 API reference

This document describes the standalone `cl-inputs` 0.2.0 release-candidate API. The system name and package family are `cl-inputs`; the historical design name `cl-input` is not an ASDF system name.

The qualified runtime is SBCL on POSIX/Linux. Core loading has no ElmTUI or `cl-events` dependency. `cl-events` integration is an explicit optional system.

## ASDF system boundary

| System | Depends on | Purpose |
| --- | --- | --- |
| `cl-inputs` | Alexandria, UIOP/ASDF, Bordeaux Threads, SB-POSIX, log4cl | Runtime decoder, source lifecycle, routing, device and terminal seams |
| `cl-inputs/events` | `cl-inputs`, `cl-events` | Optional event-bus adapter |
| `cl-inputs/tests` | `cl-inputs`, FiveAM | Core regression suite; no `cl-events` |
| `cl-inputs/events-tests` | `cl-inputs/events`, FiveAM | Optional adapter regression suite |

Loading `cl-inputs` neither loads nor probes `cl-inputs/events`. A compatible standalone `cl-events` must already be ASDF-discoverable before loading the optional adapter.

## Package boundary

| Package | Role | Facade reexport? |
| --- | --- | --- |
| `cl-inputs` | Convenience public facade | n/a |
| `cl-inputs.api` | High-level source/raw helpers | yes |
| `cl-inputs.tokens` | `input-token` data and token-kind constants | yes |
| `cl-inputs.keymap` | Key lookup/canonicalization | yes |
| `cl-inputs.decoder` | Semantic decoder | yes |
| `cl-inputs.routing` | Terminal-response correlation/router | yes |
| `cl-inputs.sink` | Token sink protocol and composition | yes |
| `cl-inputs.device.api` | Device protocol, lifecycle, I/O, locking, conditions | yes |
| `cl-inputs.terminal.api` | Terminal drawing/control generics | yes |
| `cl-inputs.protocol` | Bounded raw terminal protocol recognizer | no; focused low-level API |
| `cl-inputs.escape` | CSI extension hook | no |
| `cl-inputs.adapters` | Token-to-normalized-event conversion | no |
| `cl-inputs.util` | UTF-8/output conversion helpers | no |
| `cl-inputs.device.tty` | TTY backend and constructor | no |
| `cl-inputs.device.faketerm` | Deterministic fake backend/test helpers | no |
| `cl-inputs.device.urxvt` | URxvt/PTTY backend implementation | no public package-export promise |
| `cl-inputs.terminal.ansii` | ANSI sequence registry/rendering support | no |
| `cl-inputs.events` | Optional `cl-events` adapter | separate system only |
| `cl-inputs.tests.*` | Regression suites | test systems only |

The facade deliberately does not reexport `cl-inputs.protocol` or backend-specific helpers. Code that needs those extension seams should name the focused package explicitly.

## Tokens and decoding

`cl-inputs.tokens:input-token` carries `kind`, `data`, and `ts`. Construct tokens with `make-token`; inspect them with `input-token-kind`, `input-token-data`, and `input-token-ts`.

Established kinds include:

- `:key`, `:mouse`, `:resize`, `:paste`, and `:focus` for user input;
- `:terminal-response` for syntactically valid terminal replies;
- `:protocol` for bounded malformed/unsupported protocol diagnostics.

Create a semantic decoder with `cl-inputs.decoder:make-decoder`. `decode-chunk` incrementally consumes octets; `finish-decoder` resolves buffered terminal state at end of input. `decoder-next-deadline` exposes ESC ambiguity timing and `decoder-buffered-byte-count` exposes retained byte count for bounded-state diagnostics.

The lower-level `cl-inputs.protocol` package exposes the raw recognizer, explicit size defaults, parser state/deadline/buffer accounting, protocol-event accessors, and UTF-8 decode helper. It is part of the focused core API but is not facade-reexported.

## Owned input-source lifecycle

`cl-inputs.loop:make-input-source` is the canonical pull-mode constructor. By default the source owns its device lifecycle: open, nonblocking setup, raw setup, raw restoration, and close. The source states and terminal outcomes are observable through `input-source-state` and `input-source-terminal-outcome`.

`close-input-source` and `cancel-input-source` are idempotent. An owned source serializes teardown with active reads and uses bounded readiness slices so close/cancel cannot permanently strand a reader. EOF and read failures become terminal outcomes. Callers that intentionally own the device themselves can pass `:owns-device-p nil`; they then retain responsibility for setup and teardown.

`cl-inputs.api:make-ready-input-source` delegates to this lifecycle instead of duplicating open/raw ownership. `with-input-source` supplies unwind-protected cleanup. `read-tokens` also cleans its source on every exit path.

## Terminal-response routing

`next-token` returns only established user-input kinds. Terminal replies never leak into ordinary input. They are matched to response correlations or retained in a bounded unmatched-response queue. Protocol diagnostics have their own bounded queue.

The router defaults are exported by `cl-inputs.routing`:

- at most 16 live response correlations;
- at most 32 unmatched responses;
- at most 32 protocol diagnostics.

`register-response-correlation` / `expect-terminal-response` create a correlation with an absolute monotonic deadline. States are `:pending`, `:matched`, `:expired`, or `:cancelled`. A response observed at or after the deadline cannot match. Same-response-type correlations match in registration FIFO order. Explicit cancellation is terminal and frees bounded correlation capacity on the next router maintenance operation.

For built-in queries, use `send-terminal-query`; it registers before writing bytes, so an immediate reply cannot race registration. Supported identifiers are:

- `:cursor-position`;
- `:device-status`;
- `:primary-device-attributes`;
- `:secondary-device-attributes`.

A short write or write error cancels the just-created correlation before propagating the error. `wait-terminal-response` pumps the same source while preserving unrelated user-input order. If the source closes, is cancelled, reaches EOF, or enters a terminal read error while waiting, a still-pending correlation is cancelled because it can no longer be satisfied. A caller-only wait timeout returns `nil` without cancelling a correlation whose own absolute deadline remains live.

`take-unmatched-terminal-response` and `take-input-protocol-diagnostic` drain the two bounded fail-closed queues.

## Device API

Use `cl-inputs.device.api:make-device` for the available backends `:tty`, `:faketerm`, and `:urxvt`. Device backends implement the public generics for open/close, raw character mode, nonblocking mode, readiness, byte I/O, capabilities, and terminal modes. Faketerm is deterministic-test qualified; TTY qualification permits the explicit no-controlling-TTY environment skip; URxvt is compile/load qualified only, not claimed as a live portability result.

A single `device-read-bytes` attempt returns a positive byte count, zero for a zero-length request, `:eof`, `:would-block`, or `:interrupted`. Retry and deadline policy belongs to the caller. Unsupported default generic operations signal the public `device-error` condition rather than silently succeeding.

`cl-inputs.device.tty:make-tty-device` is the focused TTY constructor. `cl-inputs.device.faketerm` exposes deterministic injection/capture and selected lifecycle counters for tests. Backend-specific diagnostic/test hooks are not facade API.

The old external symbol `cl-inputs.device.api:device-enable-raw-char-mode` is not part of 0.2.0: it was a phantom export with no definition. Use `enable-raw-char-mode`.

## Terminal API

`cl-inputs.terminal.api` provides the terminal drawing/control generics: clear/draw/fill/scroll, cursor positioning/visibility, flush, style application/reset, and `with-styled-output`.

`get-cursor-position` returns the position tracked by the backend; it does not consume CPR bytes. For an authoritative cursor-position report, issue a `:cursor-position` query through the input source. `get-terminal-size` returns WIDTH and HEIGHT as two values when the backend knows them; otherwise the generic fallback returns `nil` values.

The `%emit-ansi`, `%style->sgr-string`, and `+esc+` exports are retained compatibility helpers used by existing backends. New consumers should prefer the higher-level terminal generics unless implementing a backend.

`cl-inputs.terminal.ansii:read-escape-bytes` is a retained legacy stream-level helper. It is not used by the owned input-source pipeline and must not be run against a stream concurrently owned by an input source; new input decoding should use `cl-inputs.decoder`/`cl-inputs.protocol` instead.

## Sink and optional events compatibility

Core sink composition is `cl-inputs.sink:accept-token`, the per-kind sink generics, `fn-sink`, and `tee-sink`.

0.2.0 deliberately removes `cl-inputs.sink:event-bus-sink`, `cl-inputs.sink:token->event`, and their former `cl-inputs` facade reexports. Those compatibility shims dynamically loaded `cl-events`, violating the core/optional boundary. Migrate callers to:

```lisp
(asdf:load-system "cl-inputs/events")

(cl-inputs.events:token->event token)
(cl-inputs.events:event-bus-sink bus :topic :input/token)
```

No core API dynamically loads the optional adapter.

## Qualification contract

Run the core suite from the standalone repository with the local CLPM bundle:

```sh
CLPM_HOME=.cache/clpm clpm bundle exec --with-client sbcl -- \
  --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval '(asdf:test-system "cl-inputs")'
```

When standalone `cl-events` is independently ASDF-discoverable, qualify the adapter separately with `(asdf:test-system "cl-inputs/events")`.

The only accepted environmental skip is the explicit TTY-construction test when the process has no controlling terminal. All other failures are release-candidate failures.

## Release-lineage note

The Git history inherited an older `v0.2.0` tag from the ElmTUI repository, pointing to that historical release rather than this standalone candidate. Phase-D qualification does not move, delete, or recreate tags. Publication/tag lineage therefore requires a separate authorized release decision.
