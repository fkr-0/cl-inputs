# Changelog

All notable changes to `cl-inputs` are recorded here. The library follows semantic versioning independently of ElmTUI.

## Unreleased

Candidate version: **0.2.0**. The library is now maintained in a standalone
repository extracted from ElmTUI history; this is not yet a registry publication.

### Added

- Standalone repository extraction preserving the relevant ElmTUI subtree history.
- Deterministic fake-terminal/device coverage and modular ASDF test suites.
- Timeout-aware input-source and terminal-device behavior.
- Optional `cl-events` integration boundary through `cl-inputs/events`.
- Typed `:terminal-response` tokens plus bounded response correlation for cursor, status, and device-attribute queries.
- Deterministic routing coverage for matched, unmatched, expired, malformed, and interleaved response/input streams.
- A separate `cl-inputs/events-tests` system so optional adapter behavior is qualified without adding `cl-events` to core tests.
- Standalone README and path-independent CLPM bundle metadata.
- A public package/ASDF boundary contract covering core, optional events,
  terminal/device seams, and both test systems.

### Changed

- Simplified decoder/input-loop paths around one canonical token pipeline.
- Kept core terminal decoding and device ownership independent of ElmTUI.
- Routed terminal replies through the owned input source so TTY helpers and ANSI metadata no longer read response bytes directly.
- Made event-bus integration explicitly secondary rather than a hard or dynamically loaded dependency of the core input library.
- Adapted `cl-events.types:event` to the event-topic/payload/timestamp protocol only when `cl-inputs/events` is loaded.
- Removed the unimplemented `device-enable-raw-char-mode` phantom export; use
  `enable-raw-char-mode`.
- Removed the former `cl-inputs.sink`/facade event-bus compatibility shims.
  Existing callers must explicitly load `cl-inputs/events` and use
  `cl-inputs.events:event-bus-sink` / `cl-inputs.events:token->event`.

### Fixed

- Default input-source creation now matches its documented lazy-creation contract.
- Terminal replies cannot be delivered as ordinary user input; stale or unmatched replies fail closed to bounded protocol queues.
- Response waits preserve unrelated user-input ordering and share the source's monotonic deadline/readiness budget.
- Same-type response correlations are deterministically FIFO; explicit
  cancellation frees bounded correlation capacity; unmatched response and
  diagnostic backlogs remain bounded.
- Short/failed query writes and terminal source close/cancel/EOF/error while
  waiting cancel correlations that can no longer be satisfied.
- Unsupported default device operations now signal a printable `device-error`
  instead of constructing the condition with a mismatched initarg/unbound report slot.
- Terminal/input tests fail their ASDF operation on real failures while retaining the explicit no-controlling-TTY environment skip.

### Release-candidate metadata note

- The repository inherits an older `v0.2.0` tag targeting the historical ElmTUI
  release commit. The standalone candidate does not retarget or delete that tag;
  tag/publication lineage requires a separate authorized release decision.

## 0.1.0

- Initial terminal decoder, keymap, device, sink, token, and input-loop library.
