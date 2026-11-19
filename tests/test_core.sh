#!/usr/bin/env bash
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib.sh
# shellcheck disable=SC1091
. "$TESTS_DIR/lib.sh"
# shellcheck source=../lib/hh-core.sh
# shellcheck disable=SC1091
. "$ROOT/lib/hh-core.sh"

REAL_PLATFORM="$(hh_platform)"
hh_platform() {
  printf '%s\n' "${TEST_PLATFORM:-$REAL_PLATFORM}"
}
TEST_PLATFORM="$REAL_PLATFORM"

assert_eq "$(model_class 'provider/model-name')" "standard" "model_class: standard"
assert_eq "$(model_class 'provider/model-name-free')" "training" "model_class: default training glob"
assert_eq "$(model_class 'provider/model-name-free#high')" "training" "model_class: variant suffix ignored"
assert_eq "$(model_class 'PROVIDER/MODEL-NAME-FREE')" "training" "model_class: case-insensitive"
export HH_TRAINING_MODELS="provider/*-trial"
assert_eq "$(model_class 'provider/model-trial')" "training" "model_class: custom glob"
assert_eq "$(model_class 'provider/model-name')" "standard" "model_class: custom glob leaves others"
unset HH_TRAINING_MODELS

TEST_PLATFORM="windows"
a="$(norm_path 'C:/work/proj')"
b="$(norm_path 'C:\work\proj')"
c="$(norm_path '/c/work/proj')"
assert_eq "$a" "$b" "norm_path: C:/ and C:\\ agree"
assert_eq "$b" "$c" "norm_path: drive and /c/ agree"
TEST_PLATFORM="posix"
assert_eq "$(norm_path '/CaseSensitive/Path')" "/CaseSensitive/Path" "norm_path: case preserved on posix"
TEST_PLATFORM="$REAL_PLATFORM"
if [[ "$REAL_PLATFORM" == "windows" ]]; then
  tmp_norm="$(mktemp -d)"
  mkdir -p "$tmp_norm/repo"
  a="$(cd "$tmp_norm/repo" && norm_path ".")"
  b="$(cd "$tmp_norm/repo" && norm_path "$(pwd -W)")"
  assert_eq "$a" "$b" "norm_path: dot and Windows spelling agree"
  rm -rf "$tmp_norm"
fi

tmp="$(mktemp -d)"
registry="$tmp/approved.txt"
printf '/work/proj\n' > "$registry"
if is_approved_root "/work/proj" "$registry"; then pass "approval: exact root"; else fail "approval: exact root"; fi
if is_approved_root "/work/proj/sub" "$registry"; then pass "approval: inside root"; else fail "approval: inside root"; fi
if is_approved_root "/work/project2" "$registry"; then fail "approval: sibling prefix rejected"; else pass "approval: sibling prefix rejected"; fi
rm -rf "$tmp"

HH_RETRY_MODELS="provider/one provider/two"
assert_eq "$(retry_model 6 standard provider/one)" "provider/two" "retry_model: first different entry"
assert_eq "$(retry_model 4 standard provider/one)" "" "retry_model: rc 4 is not retried"
assert_eq "$(retry_model 6 training provider/one)" "" "retry_model: training class is not retried"
HH_RETRY_MODELS="provider/one"
assert_eq "$(retry_model 6 standard provider/one)" "" "retry_model: no different entry"
export HH_RETRY_MODELS=""
assert_eq "$(retry_model 6 standard provider/one)" "" "retry_model: empty list"
unset HH_RETRY_MODELS

count="$(default_guard_globs | wc -l | tr -d ' ')"
assert_eq "$count" "19" "guard globs: default count"

tmp="$(mktemp -d)"
mkdir -p "$tmp/.hiredhand"
printf '# a comment\ncustom/**\n\n' > "$tmp/.hiredhand/guard.txt"
globs="$(load_guard_globs "$tmp")"
assert_contains "$globs" "custom/**" "guard globs: project file read"
assert_contains "$globs" "**/.env*" "guard globs: defaults kept"
rm -rf "$tmp"

prompt="$(build_guard_prompt 'secrets/**')"
assert_contains "$prompt" "permission config" "guard prompt: names the permission config"
assert_contains "$prompt" "secrets/**" "guard prompt: names the glob"
if [[ "$prompt" == *"hard boundary"* ]]; then
  fail "guard prompt: no hard-boundary claim"
else
  pass "guard prompt: no hard-boundary claim"
fi

finish
