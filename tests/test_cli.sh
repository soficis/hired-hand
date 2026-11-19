#!/usr/bin/env bash
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
BIN="$ROOT/bin/hiredhand"
FAKE="$ROOT/tests/fake-opencode"

# shellcheck source=lib.sh
# shellcheck disable=SC1091
. "$TESTS_DIR/lib.sh"

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
  echo "python >= 3.8 is required for the CLI tests" >&2
  exit 2
}
if [[ "$PY" != *.exe && -f "$PY.exe" ]]; then
  PY="$PY.exe"
fi

native() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

PY_NATIVE="$(native "$PY")"
FAKE_NATIVE="$(native "$FAKE")"
WORKROOT="$(mktemp -d)"
trap 'rm -rf "$WORKROOT"' EXIT

CASE=""
CASE_NATIVE=""
OUT=""
RC=0
COUNTER=0

setup_case() {
  COUNTER=$((COUNTER + 1))
  CASE="$WORKROOT/case-$COUNTER"
  mkdir -p "$CASE"
  CASE_NATIVE="$(native "$CASE")"
  export HH_STATE_DIR="$CASE/state"
  export HH_CONFIG_DIR="$CASE/config"
  export FAKE_ARGV_LOG="$CASE_NATIVE/argv.jsonl"
  export HH_OPENCODE="$PY_NATIVE $FAKE_NATIVE"
  export HH_MODEL="provider/model-name"
  unset FAKE_MODE FAKE_EDIT_FILE FAKE_CONFIG_COPY WRAP_FAKE
  unset HH_TIMEOUT HH_IDLE HH_DIRTY HH_YES HH_SYNC HH_ISOLATE HH_STANDALONE
  unset HH_UNFINISHED_CHECK HH_RETRY_MODELS HH_TRAINING_MODELS HH_PYTHON
  unset HH_AGENT_BUILD HH_AGENT_REVIEW HH_SNAPSHOT_PATHS OPENCODE_CONFIG
}

run_bin() {
  local dir="$1"
  shift
  OUT="$(cd "$dir" || exit 2; "$BIN" "$@" 2>&1)"
  RC=$?
}

make_repo() {
  local dir="$1"
  mkdir -p "$dir/sub"
  git init -q "$dir"
  git -C "$dir" config user.name test
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config core.autocrlf false
  printf 'one\n' > "$dir/file.txt"
  printf 'goal\n' > "$dir/spec.md"
  printf 'keep\n' > "$dir/sub/.keep"
  git -C "$dir" add file.txt spec.md sub/.keep
  git -C "$dir" commit -q -m init
}

fake_field() {
  "$PY" - "$FAKE_ARGV_LOG" "$1" <<'PY'
import json
import sys

path, key = sys.argv[1], sys.argv[2]
records = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
print(records[-1].get(key))
PY
}

fake_argv_after() {
  "$PY" - "$FAKE_ARGV_LOG" "$1" <<'PY'
import json
import sys

path, flag = sys.argv[1], sys.argv[2]
records = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
argv = records[-1]["argv"]
print(argv[argv.index(flag) + 1])
PY
}

fake_has_arg() {
  "$PY" - "$FAKE_ARGV_LOG" "$1" <<'PY'
import json
import sys

path, flag = sys.argv[1], sys.argv[2]
records = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
print("yes" if flag in records[-1]["argv"] else "no")
PY
}

log_field() {
  "$PY" - "$HH_STATE_DIR/runs.jsonl" "$1" "$2" <<'PY'
import json
import sys

path, key, index = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
print(rows[index].get(key))
PY
}

log_count() {
  if [[ ! -f "$HH_STATE_DIR/runs.jsonl" ]]; then
    printf '0\n'
    return 0
  fi
  wc -l < "$HH_STATE_DIR/runs.jsonl" | tr -d ' '
}

# --version and help are independent of a project.
setup_case
run_bin "$CASE" --version
assert_rc "$RC" 0 "--version exits 0"
assert_eq "$OUT" "hiredhand 0.1.0" "--version output"

setup_case
mkdir -p "$CASE/home"
OUT="$(HOME="$CASE/home" "$BIN" help 2>&1)"
RC=$?
assert_rc "$RC" 0 "help exits 0 with an empty HOME"
assert_contains "$OUT" "hiredhand build" "help lists build"
assert_contains "$OUT" "not a sandbox" "help states the guard limit"

# Model and confirmation checks happen before any run.
setup_case
make_repo "$CASE/repo"
OUT="$(cd "$CASE/repo" || exit 2; HH_MODEL="" "$BIN" build --yes spec.md 2>&1)"
RC=$?
assert_rc "$RC" 2 "missing model exits 2"
assert_contains "$OUT" "no model" "missing model message"

setup_case
make_repo "$CASE/repo"
run_bin "$CASE/repo" build spec.md
assert_rc "$RC" 2 "build without --yes exits 2"
assert_contains "$OUT" "pass --yes" "build without --yes message"

# Dirty-tree rules.
setup_case
make_repo "$CASE/repo"
printf 'two\n' >> "$CASE/repo/file.txt"
run_bin "$CASE/repo" build --yes spec.md
assert_rc "$RC" 3 "dirty tracked file exits 3"
assert_contains "$OUT" "uncommitted changes" "dirty tracked message"
if [[ -e "$FAKE_ARGV_LOG" ]]; then
  fail "dirty tree does not start opencode"
else
  pass "dirty tree does not start opencode"
fi

setup_case
make_repo "$CASE/repo"
printf 'extra\n' > "$CASE/repo/extra.txt"
run_bin "$CASE/repo" build --yes spec.md
assert_rc "$RC" 3 "untracked file exits 3"

setup_case
make_repo "$CASE/repo"
printf 'two\n' >> "$CASE/repo/file.txt"
export HH_DIRTY=1
run_bin "$CASE/repo" build --yes spec.md
assert_rc "$RC" 0 "HH_DIRTY=1 allows a dirty tree"
assert_eq "$(log_field files -1)" "0" "HH_DIRTY=1 baseline excludes existing churn"
assert_eq "$(log_field ins -1)" "0" "HH_DIRTY=1 baseline excludes existing insertions"
assert_eq "$(log_field del -1)" "0" "HH_DIRTY=1 baseline excludes existing deletions"

# The clean-tree build that creates only an untracked file is the regression
# for the empty-diff crash: it must log the run and report one new file.
setup_case
make_repo "$CASE/repo"
export FAKE_MODE=edit
export FAKE_EDIT_FILE=added.txt
run_bin "$CASE/repo" build --yes spec.md
assert_rc "$RC" 0 "clean build with an untracked edit exits 0"
assert_file "$HH_STATE_DIR/runs.jsonl" "clean build writes a run log"
assert_eq "$(log_count)" "1" "clean build logs one run"
assert_eq "$(log_field new -1)" "1" "clean build reports one new file"
assert_eq "$(log_field files -1)" "0" "clean build reports no modified files"
assert_eq "$(fake_has_arg --auto)" "yes" "build passes --auto"
tmp_left="$(find "$HH_STATE_DIR/tmp" -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$tmp_left" "0" "run removes its temporary files"

setup_case
make_repo "$CASE/repo"
export FAKE_MODE=fail
run_bin "$CASE/repo" build --yes spec.md
assert_rc "$RC" 1 "failing opencode passes its status through"
assert_eq "$(log_count)" "1" "failed run is logged"
assert_eq "$(log_field exit -1)" "1" "failed run records exit 1"

# Spec path is absolute before the repository root becomes the cwd.
setup_case
make_repo "$CASE/repo"
OUT="$(cd "$CASE/repo/sub" || exit 2; "$BIN" build --yes ../spec.md 2>&1)"
RC=$?
assert_rc "$RC" 0 "relative spec from a subdirectory exits 0"
spec_arg="$(fake_argv_after --file)"
spec_want="$(native "$CASE/repo/spec.md")"
assert_eq "${spec_arg//\\//}" "${spec_want//\\//}" "spec path passed to opencode is absolute"

# Training guard.
setup_case
make_repo "$CASE/repo"
export HH_MODEL="provider/model-free"
run_bin "$CASE/repo" build --yes spec.md
assert_rc "$RC" 3 "training model on an unapproved root exits 3"
assert_contains "$OUT" "REFUSED" "training refusal message"
if [[ -e "$FAKE_ARGV_LOG" ]]; then
  fail "unapproved training run does not start opencode"
else
  pass "unapproved training run does not start opencode"
fi

setup_case
make_repo "$CASE/repo"
"$BIN" approve "$CASE/repo" >/dev/null 2>&1
assert_rc "$?" 0 "approve exits 0"
export HH_MODEL="provider/model-free"
export FAKE_CONFIG_COPY="$CASE_NATIVE/guard.json"
export WRAP_FAKE="$FAKE_NATIVE"
cat > "$CASE/wrap-opencode" <<'PY'
import os
import sys

source = os.environ.get("OPENCODE_CONFIG")
if source:
    with open(source, encoding="utf-8") as handle:
        content = handle.read()
    with open(os.environ["FAKE_CONFIG_COPY"], "w", encoding="utf-8", newline="\n") as handle:
        handle.write(content)
os.execv(sys.executable, [sys.executable, os.environ["WRAP_FAKE"]] + sys.argv[1:])
PY
WRAP_OPENCODE="$(native "$CASE/wrap-opencode")"
export HH_OPENCODE="$PY_NATIVE $WRAP_OPENCODE"
run_bin "$CASE/repo" build --yes spec.md
assert_rc "$RC" 0 "approved training run exits 0"
assert_file "$FAKE_CONFIG_COPY" "training run exports a guard config"
guard_config="$(cat "$FAKE_CONFIG_COPY")"
assert_contains "$guard_config" '"action": "shell"' "guard config denies shell"
assert_contains "$guard_config" '"resource": "*"' "guard config uses a wildcard resource"
tmp_left="$(find "$HH_STATE_DIR/tmp" -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$tmp_left" "0" "training run removes its temporary files"

setup_case
make_repo "$CASE/repo"
"$BIN" approve "$CASE/repo" >/dev/null 2>&1
export HH_MODEL="provider/model-free"
export HH_STANDALONE=0
run_bin "$CASE/repo" build --yes spec.md
assert_rc "$RC" 3 "training run with HH_STANDALONE=0 exits 3"
assert_contains "$OUT" "HH_STANDALONE=1" "training run explains the standalone requirement"

setup_case
make_repo "$CASE/repo"
run_bin "$CASE/repo" build --yes spec.md
assert_rc "$RC" 0 "standard run exits 0"
assert_eq "$(fake_field OPENCODE_CONFIG)" "None" "standard run has no OPENCODE_CONFIG"

# Upstream retry, loop cap and dry run.
setup_case
make_repo "$CASE/repo"
run_bin "$CASE/repo" review spec.md
assert_rc "$RC" 0 "review exits 0"
assert_eq "$(fake_argv_after --agent)" "plan" "review uses the review agent"
assert_eq "$(fake_has_arg --auto)" "no" "review does not pass --auto"

setup_case
make_repo "$CASE/repo"
export FAKE_MODE=upstream
export HH_RETRY_MODELS="provider/other-model"
run_bin "$CASE/repo" build --yes spec.md
assert_rc "$RC" 6 "provider errors exit 6 after one retry"
assert_eq "$(log_count)" "2" "provider error retries once"
assert_eq "$(log_field route 0)" "explicit" "first attempt route is explicit"
assert_eq "$(log_field route 1)" "retry-upstream" "second attempt route is retry-upstream"
assert_eq "$(log_field model 1)" "provider/other-model" "retry uses the configured model"

setup_case
make_repo "$CASE/repo"
export FAKE_MODE=loop
run_bin "$CASE/repo" build --yes spec.md
assert_rc "$RC" 4 "loop exits 4"
assert_eq "$(log_count)" "1" "loop is not retried"

setup_case
make_repo "$CASE/repo"
run_bin "$CASE/repo" build --dry-run spec.md
assert_rc "$RC" 0 "dry run exits 0"
assert_contains "$OUT" "mode: build" "dry run prints the mode"
assert_contains "$OUT" "approved: no" "dry run prints the approval state"
assert_contains "$OUT" "command:" "dry run prints the command"
if [[ -e "$FAKE_ARGV_LOG" ]]; then
  fail "dry run does not invoke opencode"
else
  pass "dry run does not invoke opencode"
fi
if [[ -d "$HH_STATE_DIR" ]]; then
  fail "dry run does not create the state directory"
else
  pass "dry run does not create the state directory"
fi

# Non-git change detection keeps names with spaces intact.
setup_case
mkdir -p "$CASE/plain"
printf 'old\n' > "$CASE/plain/my file.txt"
printf 'goal\n' > "$CASE/plain/spec.md"
export FAKE_MODE=edit
export FAKE_EDIT_FILE="my file.txt"
run_bin "$CASE/plain" build --yes spec.md
assert_rc "$RC" 0 "non-git build exits 0"
assert_contains "$OUT" "modified: ./my file.txt" "non-git report names the file with a space"
assert_eq "$(log_field files -1)" "1" "non-git report counts the modified file"

# State, outcomes and stats.
setup_case
make_repo "$CASE/repo"
run_bin "$CASE/repo" build --yes spec.md
assert_rc "$RC" 0 "first stats run exits 0"
if [[ -d "$HH_STATE_DIR" ]]; then
  pass "run creates the state directory"
else
  fail "run creates the state directory"
fi
run_bin "$CASE/repo" build --yes spec.md
assert_rc "$RC" 0 "second stats run exits 0"

OUT="$("$BIN" stats --json 2>&1)"
RC=$?
assert_rc "$RC" 0 "stats --json exits 0"
stats_runs="$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("runs"))')"
assert_eq "$stats_runs" "2" "stats --json counts two runs"
OUT="$("$BIN" stats 2>&1)"
RC=$?
assert_rc "$RC" 0 "stats exits 0"
assert_contains "$OUT" "runs=2" "stats prints two runs"

setup_case
run_bin "$CASE" outcome run-1 maybe
assert_rc "$RC" 2 "outcome rejects a bad verdict"
run_bin "$CASE" outcome run-1 pass nope
assert_rc "$RC" 2 "outcome rejects non-numeric tokens"
run_bin "$CASE" outcome run-1 pass 123 "a note"
assert_rc "$RC" 0 "outcome appends a valid record"
assert_eq "$(log_field claude_tokens_est -1)" "123" "outcome stores token count"
assert_eq "$(log_field note -1)" "a note" "outcome stores the note"

setup_case
run_bin "$CASE" approvals
assert_rc "$RC" 0 "approvals exits 0"
assert_contains "$OUT" "no approved roots" "approvals starts empty"

finish
