# cl-inputs

`cl-inputs` is a reusable terminal-input library for Common Lisp. It owns byte decoding, semantic input tokens, terminal device ports, fake terminals, sinks, and synchronous/asynchronous input loops. ElmTUI consumes these APIs but is not part of the library.

## Core boundary

The primary `cl-inputs` system is input-domain code. It does not require ElmTUI. Event-bus integration is an optional adapter exposed through the secondary `cl-inputs/events` system; compatibility helpers in `cl-inputs.sink` can load that adapter when it is available.

## Features

- incremental ANSI/escape-sequence decoder;
- semantic key, mouse, resize, paste, focus, and control tokens;
- key-sequence mapping and canonicalization;
- TTY, fake-terminal, and URxvt-oriented device implementations;
- push sinks and pull input sources;
- bounded waits and deterministic fake-device tests;
- terminal capability/mode helpers;
- optional `cl-events` bus adapter.

## Loading

```lisp
(asdf:load-system "cl-inputs")
```

For optional `cl-events` integration:

```lisp
(asdf:load-system "cl-inputs/events")
```

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
