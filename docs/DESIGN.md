# Design

## Run flow

1. Parse the command, resolve the spec path to an absolute path, and find the
   project root with `git rev-parse --show-toplevel` (or the current directory
   outside git).
2. Classify the model with `model_class`. A training-class model must be inside
   an approved root; otherwise the command exits 3 before starting OpenCode.
3. For `build`, require `--yes` or `HH_YES=1`, then refuse a dirty tree unless
   `HH_DIRTY=1`. With `HH_DIRTY=1`, a `git stash create` baseline keeps
   pre-existing churn out of the change report.
4. Create the state directory, the temporary directory and the run log path.
   Temporary files are removed by one EXIT trap.
5. For each attempt, prepare the training guard when needed, then run an outer
   `timeout` around `lib/runner.py`, which runs `opencode run` with JSON events.
6. Report the working-tree changes, append the run line, and optionally retry
   once after provider errors.
7. Exit with the run's status.

Everything in `bin/hiredhand` runs inside `main()`. Bash parses the whole file
before executing it, so editing the script while a run is in progress cannot
corrupt that run.

## The watchdog

`lib/runner.py` starts the child in its own process group or session, streams
OpenCode's JSON events, and kills the whole child tree when a limit is reached.

| Code | Condition |
|---|---|
| 124 | Wall-clock timeout. |
| 125 | No output for the idle limit. |
| 4 | Two consecutive steps with no tool work, or more than 80 steps. |
| 6 | Two consecutive provider-error events with no tool work between them. |
| 3 | Optional: the final answer says it is still waiting. |
| 0 | The child exited successfully, or lingered 20 seconds after a final answer. |

On POSIX the runner sends `SIGTERM` to the process group, waits up to five
seconds, then sends `SIGKILL`. On Windows it uses `taskkill /PID <pid> /T /F`.
The kill helper never raises, and a `try/finally` block stops the child tree if
the runner itself fails or is interrupted.

Provider failures are detected from error events and from text carrying a
provider signature (429, 5xx, rate limit, overloaded, upstream, connection
reset). A bare mention of a timeout only counts next to error or provider
wording. Tool output is not treated as a provider failure.

`--format json` is inserted for `run`, `--standalone` is on by default, and
`--sync` appends the synchronous-work sentence to the last argument. Isolation
sets `XDG_CONFIG_HOME` to `share/opencode-isolated`, which has an empty plugin
and MCP list, so user plugins and MCP servers do not load.

## Training guard

`lib/guard.py` generates an OpenCode permission document:

- `path_forms(root)` returns forward-slash, backslash and drive spellings of a
  root.
- `variants(glob, root)` returns the glob as written, root-anchored forms and
  an unanchored `**/` form, with duplicates removed.
- `make_config` creates `read` and `glob` deny rules for every variant, then
  one deny-all rule each for `shell`, `grep`, `subagent`, `execute`, `webfetch`
  and `websearch`.
- `scan_mentions` tokenizes run output and reports concrete paths that match a
  guard glob. It skips tokens containing `*`, so prose that merely quotes a
  glob does not trigger a warning.

The config is written to a temporary file and exported as `OPENCODE_CONFIG`
for training-class attempts only. Every other attempt unsets that variable.
Training-class attempts are refused when `HH_STANDALONE` or `HH_ISOLATE` is
`0`, because the config would not be enforced.
The CLI loads the default globs plus non-comment lines from
`.hiredhand/guard.txt` in the project root.

The guard is a data-flow filter, not a sandbox. It does not deny writes, and
OpenCode's permission action names must be verified against the version in use.

## Retry

A run that exits 6 on a standard-class model may retry once. The retry model is
the first entry in `HH_RETRY_MODELS` whose id (without `#variant`) differs from
the failed one. An empty list means no retry. Exit 4 is never retried. The
second attempt is logged with route `retry-upstream` and `retry_of` set to the
first run id.

## State files

`$HH_STATE_DIR/runs.jsonl` receives one JSON object per line. Run lines record
the model, class, route, spec size, duration, exit code, output size, change
counts and HEAD movement. Outcome lines record a verdict, an optional token
count and a note. Temporary guard configs, output captures and snapshots live
in `$HH_STATE_DIR/tmp` and are deleted on exit. The state directory is mode 700
on POSIX.

Change detection uses `git diff --shortstat` and untracked files inside git.
Outside git, a snapshot hashes files with SHA-256, skipping `.git`,
`node_modules`, `build`, `dist`, `.dart_tool`, `.venv` and `__pycache__`, and
ignoring files of 20 MB or more. The comparison happens in Python so paths
with spaces work.
