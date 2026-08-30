# cl-inputs agent guidance

`cl-inputs` is the standalone Common Lisp terminal-input library extracted from the historical ElmTUI `cl-inputs/` subtree. Treat this repository as the write authority for new `cl-inputs` library work. The old ElmTUI subtree is a compatibility copy until a separately coordinated consumer migration removes that duplication.

## Boundaries

- Keep the core `cl-inputs` system independent of ElmTUI application/rendering state.
- Keep `cl-events` integration optional in the `cl-inputs/events` ASDF system; do not make it a core dependency.
- Preserve SBCL/POSIX qualification unless portability work is explicitly implemented and tested.
- Do not publish, tag, push, or mutate the historical ElmTUI checkout without explicit authorization.

## Lisp editing discipline

For `.lisp` and `.asd` changes, operate on complete balanced forms rather than raw line fragments. After each coherent edit, validate reader/parenthesis structure, load the system, and run the focused tests. Preserve package boundaries and avoid introducing read-time evaluation or hidden global side effects.

## Verification

Use the local CLPM bundle when dependencies are needed:

```sh
CLPM_HOME=.cache/clpm clpm bundle install
CLPM_HOME=.cache/clpm clpm bundle exec --with-client sbcl -- \
  --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval '(asdf:test-system "cl-inputs")'
```

One TTY-specific test may legitimately skip in a non-interactive process without a controlling terminal; all other failures are real failures.
