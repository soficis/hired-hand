#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -z "${SCRUB_PATTERNS:-}" ]]; then
  SCRUB_PATTERNS="tools/ci-scrub-patterns.txt"
  export SCRUB_PATTERNS
fi

find_python() {
  local candidate
  if [[ -n "${HH_PYTHON:-}" ]]; then
    printf '%s\n' "$HH_PYTHON"
    return 0
  fi
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

fail() {
  echo "check-all: $1 failed" >&2
  exit 1
}

python="$(find_python)" || fail "python >= 3.8 not found"

echo "check-all: bash syntax"
for file in bin/hiredhand install.sh lib/*.sh tests/*.sh tools/*.sh; do
  bash -n "$file" || fail "bash -n $file"
done

echo "check-all: python syntax"
"$python" -m py_compile lib/guard.py lib/runner.py tests/fake-opencode || fail "py_compile"

echo "check-all: scrub (patterns: $SCRUB_PATTERNS)"
bash tools/scrub-check.sh || fail "scrub-check"

echo "check-all: tests"
bash tests/run.sh || fail "tests"

echo "check-all: ok"
