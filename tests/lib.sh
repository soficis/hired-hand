# shellcheck shell=bash
# Assertion helpers for the shell test scripts. Source this file, do not run it.
# Every assert takes the actual value first, then the expected value, then a name.

TESTS_PASS=0
TESTS_FAIL=0

pass() {
  TESTS_PASS=$((TESTS_PASS + 1))
  printf 'ok %s\n' "$1"
}

fail() {
  TESTS_FAIL=$((TESTS_FAIL + 1))
  printf 'not ok %s: %s\n' "$1" "${2:-}" >&2
}

assert_eq() {
  if [[ "$1" == "$2" ]]; then
    pass "$3"
  else
    fail "$3" "expected [$2], got [$1]"
  fi
}

assert_rc() {
  if [[ "$1" == "$2" ]]; then
    pass "$3"
  else
    fail "$3" "expected rc $2, got $1"
  fi
}

assert_contains() {
  if [[ "$1" == *"$2"* ]]; then
    pass "$3"
  else
    fail "$3" "missing [$2] in [$1]"
  fi
}

assert_file() {
  if [[ -f "$1" ]]; then
    pass "$2"
  else
    fail "$2" "missing file $1"
  fi
}

finish() {
  printf '%d passed, %d failed\n' "$TESTS_PASS" "$TESTS_FAIL"
  if ((TESTS_FAIL > 0)); then
    exit 1
  fi
  exit 0
}
