# Contributing

## Checks

Run the full local gate before opening a pull request:

```bash
bash tools/check-all.sh
```

It checks bash syntax, Python syntax, the scrub gate and every test suite. CI
also runs shellcheck on Linux.

## Style

- `set -euo pipefail` in scripts.
- Quote variables, and do not rely on GNU-only flags without a portable
  fallback.
- ASCII only, LF line endings, one final newline.
- Two-space indentation in shell, four spaces in Python.
- Comments explain the code, not its history.

## Tests

Add or update tests for every behaviour change. Shell tests use the small
assert helpers in `tests/lib.sh`; Python tests use `unittest`. Do not add a test
dependency.

## Data

Do not commit personal data, private project names, real model ids, hostnames,
credentials or run logs. The scrub gate rejects non-ASCII bytes, CR bytes and
the public secret patterns. Maintainers can point `SCRUB_PATTERNS` at a private
list for additional names.
