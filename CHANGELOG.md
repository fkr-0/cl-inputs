# Changelog

All notable changes to `cl-inputs` are recorded here. The library follows semantic versioning independently of ElmTUI.

## Unreleased

Candidate version: **0.2.0**. This remains an in-tree candidate and is not a
registry publication or separate-repository release.

### Added

- Deterministic fake-terminal/device coverage and modular ASDF test suites.
- Timeout-aware input-source and terminal-device behavior.
- Optional `cl-events` integration boundary through `cl-inputs/events`.
- Standalone README and path-independent CLPM bundle metadata.

### Changed

- Simplified decoder/input-loop paths around one canonical token pipeline.
- Kept core terminal decoding and device ownership independent of ElmTUI.
- Made event-bus integration optional rather than a hard dependency of the core input library.

### Fixed

- Default input-source creation now matches its documented lazy-creation contract.
- Terminal/input tests fail their ASDF operation on real failures while retaining the explicit no-controlling-TTY environment skip.

## 0.1.0

- Initial terminal decoder, keymap, device, sink, token, and input-loop library.
