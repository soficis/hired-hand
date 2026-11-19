#!/usr/bin/env bash
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS=0

find_python() {
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

PY="$(find_python)" || {
  echo "python >= 3.8 is required" >&2
  exit 2
}

run_suite() {
  local name="$1"
  shift
  if "$@"; then
    printf '%s: ok\n' "$name"
  else
    printf '%s: FAILED\n' "$name" >&2
    STATUS=1
  fi
}

run_suite "unittest" "$PY" -m unittest discover -s "$TESTS_DIR" -p 'test_*.py'
run_suite "core" bash "$TESTS_DIR/test_core.sh"
run_suite "cli" bash "$TESTS_DIR/test_cli.sh"

if ((STATUS == 0)); then
  printf 'all suites passed\n'
else
  printf 'one or more suites failed\n' >&2
fi
exit "$STATUS"
