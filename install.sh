#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
prefix="${PREFIX:-$HOME/.local}"
uninstall=0

for arg in "$@"; do
  case "$arg" in
    --uninstall) uninstall=1 ;;
    *)
      echo "usage: install.sh [--uninstall]" >&2
      exit 2
      ;;
  esac
done

if [[ "$prefix" != /* && "$prefix" != [A-Za-z]:[\\/]* ]]; then
  prefix="$(pwd)/$prefix"
fi
if [[ "$prefix" != "/" ]]; then
  prefix="${prefix%/}"
fi
share="$prefix/share/hiredhand"
wrapper="$prefix/bin/hiredhand"

if ((uninstall)); then
  rm -f "$wrapper"
  rm -rf "$share"
  echo "hiredhand: uninstalled from $prefix"
  exit 0
fi

if ((BASH_VERSINFO[0] < 4)); then
  echo "install: bash >= 4 is required (found ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "install: git is required" >&2
  exit 1
fi

python=""
if [[ -n "${HH_PYTHON:-}" ]]; then
  if "$HH_PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
    python="$HH_PYTHON"
  fi
else
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
      python="$(command -v "$candidate")"
      break
    fi
  done
fi
if [[ -z "$python" ]]; then
  echo "install: Python >= 3.8 is required; install python3 or set HH_PYTHON" >&2
  exit 1
fi
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  echo "install: timeout or gtimeout is required (coreutils)" >&2
  exit 1
fi
if ! command -v opencode >/dev/null 2>&1; then
  echo "install: warning: opencode is not on PATH; set HH_OPENCODE after installing it" >&2
fi

rm -rf "$share"
mkdir -p "$share" "$prefix/bin"
for directory in bin lib share tests; do
  cp -R "$repo/$directory" "$share/"
done
find "$share" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
find "$share" -type f -name '*.pyc' -delete 2>/dev/null || true

{
  printf '#!/usr/bin/env bash\n'
  printf 'HH_HOME=%q exec bash %q "$@"\n' "$share" "$share/bin/hiredhand"
} > "$wrapper"
chmod +x "$wrapper"

echo "hiredhand: installed to $prefix"
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "install: add $prefix/bin to PATH to run hiredhand" ;;
esac
