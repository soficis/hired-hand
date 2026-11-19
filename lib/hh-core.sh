# shellcheck shell=bash
# Pure helpers for the hiredhand CLI. Sourced by bin/hiredhand and by tests.
# No top-level side effects: every function only reads its arguments and the
# environment, and prints or sets a variable.

hh_platform() {
  case "$(uname -s 2>/dev/null || printf 'unknown')" in
    MINGW*|MSYS*|CYGWIN*) printf 'windows\n' ;;
    *) printf 'posix\n' ;;
  esac
}

hh_find_python() {
  local candidate
  if [[ -n "${HH_PYTHON:-}" ]]; then
    if "$HH_PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
      # shellcheck disable=SC2034
      HH_PY="$HH_PYTHON"
      return 0
    fi
    echo "hiredhand: HH_PYTHON is not a working Python >= 3.8: $HH_PYTHON" >&2
    return 1
  fi
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
      # shellcheck disable=SC2034
      HH_PY="$(command -v "$candidate")"
      return 0
    fi
  done
  echo "hiredhand: Python >= 3.8 not found; install python3 or set HH_PYTHON" >&2
  return 1
}

hh_find_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    # shellcheck disable=SC2034
    HH_TIMEOUT_BIN="$(command -v timeout)"
    return 0
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    # shellcheck disable=SC2034
    HH_TIMEOUT_BIN="$(command -v gtimeout)"
    return 0
  fi
  echo "hiredhand: timeout not found; install coreutils or set PATH to include gtimeout" >&2
  return 1
}

hh_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf 'sha256sum\n'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    printf 'shasum -a 256\n'
    return 0
  fi
  return 1
}

hh_lower() {
  printf '%s\n' "${1,,}"
}

model_class() {
  local model="${1:-}" glob
  model="${model%%#*}"
  model="$(hh_lower "$model")"
  for glob in ${HH_TRAINING_MODELS:-*-free}; do
    glob="$(hh_lower "$glob")"
    # shellcheck disable=SC2254
    case "$model" in
      $glob) printf 'training\n'; return 0 ;;
    esac
  done
  printf 'standard\n'
}

norm_path() {
  local p="${1:-}" resolved
  p="${p//\\//}"
  p="${p%$'\r'}"
  # shellcheck disable=SC2088
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p:2}" ;;
  esac
  if [[ "$(hh_platform)" == "windows" ]]; then
    # Git Bash may see the same directory as /c/..., C:/..., or /tmp/...
    # Use the Windows spelling so every form maps to one canonical value.
    if [[ -d "$p" ]]; then
      p="$(cd -- "$p" 2>/dev/null && pwd -W 2>/dev/null || printf '%s' "$p")"
    elif [[ -e "$p" ]]; then
      local parent base
      parent="$(dirname -- "$p")"
      base="$(basename -- "$p")"
      if resolved="$(cd -- "$parent" 2>/dev/null && pwd -W 2>/dev/null)"; then
        p="$resolved/$base"
      fi
    fi
    p="${p//\\//}"
    if [[ "$p" =~ ^([A-Za-z]):/(.*)$ ]]; then
      p="/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    elif [[ "$p" =~ ^([A-Za-z]):$ ]]; then
      p="/${BASH_REMATCH[1]}"
    elif [[ "$p" =~ ^/([A-Za-z])/(.*)$ ]]; then
      p="/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    elif [[ "$p" =~ ^/([A-Za-z])$ ]]; then
      p="/${BASH_REMATCH[1]}"
    fi
    while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
    while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
    p="$(hh_lower "$p")"
    printf '%s\n' "$p"
    return 0
  fi
  if [[ -d "$p" ]]; then
    if resolved="$(cd -P -- "$p" 2>/dev/null && pwd -P)"; then
      p="$resolved"
    fi
  elif [[ -e "$p" ]]; then
    local parent base
    parent="$(dirname -- "$p")"
    base="$(basename -- "$p")"
    if resolved="$(cd -P -- "$parent" 2>/dev/null && pwd -P)"; then
      p="$resolved/$base"
    fi
  fi
  while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
  printf '%s\n' "$p"
}

trim_ws() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_approved_root() {
  local root="$1" reg line entry normalized
  if [[ -n "${2:-}" ]]; then
    reg="$2"
  else
    reg="${HH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/hiredhand}/training-approved.txt"
  fi
  [[ -f "$reg" ]] || return 1
  normalized="$(norm_path "$root")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="$(trim_ws "$line")"
    if [[ -z "$line" || "$line" == \#* ]]; then
      continue
    fi
    entry="$(norm_path "$line")"
    if [[ -z "$entry" ]]; then
      continue
    fi
    if [[ "$normalized" == "$entry" || "$normalized" == "$entry"/* ]]; then
      return 0
    fi
  done < "$reg"
  return 1
}

training_refusal() {
  local model="$1" root="$2" reg="${3:-}"
  {
    echo "hiredhand: REFUSED: training-class model '$model' may train on the data it reads."
    echo "hiredhand: Training-class models may only run in a project root listed in:"
    echo "hiredhand:   $reg"
    echo "hiredhand: root '$root' is not approved. There is no override flag."
  } >&2
}

assert_training_allowed() {
  local model="$1" root="$2" reg="${3:-}"
  [[ "$(model_class "$model")" == "training" ]] || return 0
  if is_approved_root "$root" "$reg"; then
    return 0
  fi
  training_refusal "$model" "$root" "$reg"
  return 3
}

retry_model() {
  local status="$1" mclass="$2" failed="${3:-}" entry
  [[ "$status" == "6" ]] || return 0
  [[ "$mclass" == "standard" ]] || return 0
  for entry in ${HH_RETRY_MODELS:-}; do
    if [[ "${entry%%#*}" != "${failed%%#*}" ]]; then
      printf '%s\n' "$entry"
      return 0
    fi
  done
  return 0
}

default_guard_globs() {
  printf '%s\n' \
    '**/.env*' \
    '**/*.pem' \
    '**/*.key' \
    '**/*.p12' \
    '**/*.pfx' \
    '**/id_rsa*' \
    '**/id_ed25519*' \
    '**/.ssh/**' \
    '**/.aws/**' \
    '**/.npmrc' \
    '**/.pypirc' \
    '**/.netrc' \
    '**/.secret/**' \
    '**/*.sqlite' \
    '**/*.sqlite3' \
    '**/*.db' \
    '**/*-wal' \
    '**/*.jsonl' \
    '**/*.log'
}

load_guard_globs() {
  local root="$1" file line
  default_guard_globs
  file="$root/.hiredhand/guard.txt"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="$(trim_ws "$line")"
    if [[ -z "$line" || "$line" == \#* ]]; then
      continue
    fi
    printf '%s\n' "$line"
  done < "$file"
}

build_guard_prompt() {
  local glob
  printf 'TRAINING-DATA GUARD (prompt-level instruction backed by the OpenCode permission config):\n'
  printf 'This run uses a training-class model. Do NOT open, read, grep, cat, copy, or paste any file matching these excluded paths/globs:\n'
  for glob in "$@"; do
    printf '  - %s\n' "$glob"
  done
  printf 'If the task requires one of them, stop and say so instead of opening it.\n'
  printf 'The permission config denies reads of these paths and disables the shell, grep, subagent, execute, webfetch and websearch tools. Use the read and glob tools only, and never the excluded paths.\n'
}
