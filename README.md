# hired-hand

**Your expensive model writes the plan. Your cheap model does the work.**

`hiredhand` carries the baton between them.

Claude plans. DeepSeek builds. Your token budget goes to thinking, not typing.

## The problem

You pay for two AI plans. They have different strengths.

Claude Pro gives you a strong planner and a metered budget. Every file edit spends that budget on boilerplate. A $10 OpenCode Go plan gives you cheap models that follow a written spec well. They do not need to be brilliant. They need instructions.

A build run can touch twenty files. Each edit burns planner tokens. The cheap model does the same work for pennies.

So write the spec once. Hand it to the cheap model. Keep the expensive plan for planning and review.

## What it does

`hiredhand` runs one OpenCode agent on one spec file.

- It runs the agent under a watchdog: wall-clock limit, idle limit, loop detection, provider-error detection.
- It refuses a write-capable build without `--yes`.
- It refuses a dirty git tree unless you allow it.
- It reports what changed: files, insertions, deletions, new files, whether HEAD moved.
- It appends one JSONL line per run.
- It blocks secret-like paths for training-class models.

You choose the model id. The tool has no vendor lock-in.

## Ways people use it

**Claude hands off the typing.** Ask Claude Code to write `spec.md`. Then ask it to run `hiredhand build --yes spec.md`. Claude plans once and spends its quota on review instead of forty edits.

**You drive it by hand.** Write a spec in your editor. Run one command. Read the diff.

**Any agent with a shell drives it.** Cursor, Aider, Codex, a Makefile, a cron job, a CI step. The contract is a file and an exit code.

**Cross-model review.** Build with one model. Review with another. Different vendors catch different mistakes.

**Parallel worktrees.** One spec per worktree. Cheap models make parallel runs affordable.

**Overnight batches.** Queue a list of specs. Read the log in the morning.

**Cost tracking.** `hiredhand stats` groups runs and outcomes by model.

**Free-tier safety.** Free models may train on what they read. The guard refuses them outside approved roots and denies secret-like paths inside.

## Requirements

- bash >= 4
- git
- coreutils (`timeout`; `gtimeout` on macOS with Homebrew coreutils)
- Python >= 3.8 (standard library only)
- the `opencode` CLI

Windows Git Bash and Linux (including WSL) are tested. macOS uses portable code paths but is not tested here.

## Install

```bash
bash install.sh
```

The default prefix is `$HOME/.local`. The installer copies `bin/`, `lib/`,
`share/` and `tests/` under `$PREFIX/share/hiredhand` and writes
`$PREFIX/bin/hiredhand`. It prints a PATH hint when needed. It never uses sudo.

```bash
PREFIX="$HOME/tools" bash install.sh
bash install.sh --uninstall
```

## Quickstart: the baton

**Step 1. Write a spec.** Claude can do this part.

```markdown
# Add a health endpoint

## Goal
Add `GET /health` returning `{"ok": true}`.

## Files
- `src/server.py`
- `tests/test_server.py`

## Acceptance
- `python -m unittest tests.test_server`
```

**Step 2. Run the cheap model.**

```bash
HH_MODEL=provider/model-name hiredhand build --yes spec.md
```

**Step 3. Read the report and the diff.**

```bash
git diff
hiredhand outcome <run-id> pass 1200 "health endpoint added"
```

Preview a command without running anything:

```bash
HH_MODEL=provider/model-name hiredhand review --dry-run spec.md
```

Review uses the `plan` agent and asks it not to edit, but it is not a sandbox.
The agent can run shell commands that leave side effects, and `hiredhand` does
not report changes in review mode.

`build` refuses to start without `--yes` or `HH_YES=1`. It also refuses on a
dirty git tree unless `HH_DIRTY=1` is set.

## The spec is the interface

The spec is the contract between the planner and the builder. Write it once.
Both models read the same words.

State the goal, the files in scope, the acceptance commands, and any
constraints. Keep the scope narrow enough for one run. Tell the agent not to
commit. The build prompt already asks for `RESULT`, `CHECKS-RUN` and
`UNCERTAINTIES` at the end, so put the commands you want reported under
acceptance.

A planner that writes good specs gets more value from a cheap builder. That is
the trade this tool exists to make.

## Commands

| Command | Purpose |
|---|---|
| `hiredhand build [--yes] [--model M] [--dry-run] <spec>` | Run the build agent with write access. |
| `hiredhand review [--model M] [--dry-run] <spec>` | Run the review agent; not a sandbox. |
| `hiredhand outcome <run-id> <pass\|partial\|fail> [tokens] [note]` | Append a verdict for a run. |
| `hiredhand stats [--json]` | Print per-model run and verdict counts and median duration. |
| `hiredhand approve <dir>` | Approve a project root for training-class models. |
| `hiredhand approvals` | Print approved roots. |
| `hiredhand selftest` | Run offline checks of the pure functions. |
| `hiredhand help` | Print embedded help. |
| `hiredhand --version` | Print the version. |

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `HH_MODEL` | none | Model id. Required unless `--model` is given. |
| `HH_RETRY_MODELS` | empty | Space-separated. On exit 6 for a standard-class model, retry once on the first entry that differs from the failed model. |
| `HH_TRAINING_MODELS` | `*-free` | Space-separated globs matched case-insensitively against the id without `#variant`. |
| `HH_STATE_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/hiredhand` | Run log and temporary files. |
| `HH_CONFIG_DIR` | `${XDG_CONFIG_HOME:-$HOME/.config}/hiredhand` | Approval registry. |
| `HH_PYTHON` | auto | Python interpreter. Candidates must run Python >= 3.8. |
| `HH_OPENCODE` | `opencode` on PATH | OpenCode executable. |
| `HH_TIMEOUT` | `1800` | Wall-clock seconds, integer >= 60. |
| `HH_IDLE` | review 150, build 240 | Seconds without output before a stall kill, integer >= 30. |
| `HH_DIRTY` | `0` | `1` allows build on a dirty tree and measures churn from a pre-run baseline. |
| `HH_YES` | `0` | `1` is the same as `--yes`. |
| `HH_AGENT_BUILD` | `build` | Build agent name. |
| `HH_AGENT_REVIEW` | `plan` | Review agent name. |
| `HH_ISOLATE` | `1` | `1` runs OpenCode with the bundled minimal config, with no user plugins or MCP servers. |
| `HH_STANDALONE` | `1` | `1` passes `--standalone` to `opencode run`. |
| `HH_SYNC` | `0` | `1` adds the work-synchronously sentence to the prompt. |
| `HH_UNFINISHED_CHECK` | `0` | `1` turns an answer that says it is still waiting into exit 3. |
| `HH_SNAPSHOT_PATHS` | `.` | Space-separated paths to hash for non-git change detection. |

An example model id is `provider/model-name`; use whatever id your provider
publishes.

Peak hours: when your first-choice model returns 429/overloaded (exit 6),
point the retry at a cheap fallback. `hy4-flash-free` is one current option;
it trains, so use it only inside an approved root.

```bash
HH_MODEL=provider/deepseek-flash \
HH_RETRY_MODELS="provider/hy4-flash-free" \
hiredhand build --yes spec.md
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. |
| 2 | Usage or configuration error. |
| 3 | Refused by the training guard or dirty-tree check, or the answer was unfinished. |
| 4 | Loop or step cap hit. Not auto-retried. |
| 6 | Provider errors: 429, 5xx, rate limit, overloaded. |
| 124 | Wall-clock timeout. |
| 125 | Idle stall. |

## The training guard

Free tiers are cheap because the provider may train on what the model reads.
The guard makes that trade explicit.

A model is training class when its id (without `#variant`) matches a glob in
`HH_TRAINING_MODELS`. Training-class models are refused outside approved roots
with exit 3. There is no override flag.

Approve a root once:

```bash
hiredhand approve .
```

Approvals are stored as normalized absolute paths in
`$HH_CONFIG_DIR/training-approved.txt`. A root is approved when it is equal to
or inside an approved entry. The registry is never seeded.

Inside an approved root, a training run gets an OpenCode permission config that
denies `read` and `glob` for these default globs:

```
**/.env*      **/*.pem       **/*.key       **/*.p12
**/*.pfx      **/id_rsa*     **/id_ed25519* **/.ssh/**
**/.aws/**    **/.npmrc      **/.pypirc     **/.netrc
**/.secret/** **/*.sqlite    **/*.sqlite3   **/*.db
**/*-wal      **/*.jsonl     **/*.log
```

Add project patterns in `.hiredhand/guard.txt`, one glob per line; `#` starts a
comment. The config also denies the `shell`, `grep`, `subagent`, `execute`,
`webfetch` and `websearch` actions entirely. The same config is passed through
`OPENCODE_CONFIG` only for training-class attempts. Training-class runs are
refused when `HH_STANDALONE` or `HH_ISOLATE` is `0`, because the permission
config would not be enforced.

The run output is scanned for concrete paths that match the guard globs, and
each hit is reported on stderr. A broad glob can still enumerate filenames (for
example `**/*` from the project root); the guard protects file contents, not
directory listings.

## Safety

1. The model provider receives the spec and every file the agent reads.
2. hiredhand writes a local log only; it has no telemetry.
3. `build` can edit files and run shell commands with your user's rights; use a
   disposable checkout or container and keep secrets out of the tree.
4. The training guard is best effort, not a sandbox: it denies reads of listed
   paths and the shell, grep, subagent, execute, webfetch and websearch tools,
   but it does not deny writes.
5. Model ids and provider terms change; check your provider's data-use policy
   yourself.

## Logs and privacy

Runs are appended to `$HH_STATE_DIR/runs.jsonl`. A run line contains the run
id, timestamp, project path, mode, model id, model class, route, spec size,
duration, exit code, output size, change counts, whether HEAD moved, and the
id of the run it retried. Outcome lines add a verdict, an optional token count
and a note. The log does not contain spec text or model output. Temporary files
live in `$HH_STATE_DIR/tmp` and are removed when the command exits.

## Troubleshooting

- `python3` opens the Microsoft Store and the probe fails: install Python from
  python.org, or set `HH_PYTHON` to a working interpreter.
- `timeout` is missing on macOS: install Homebrew coreutils and make sure
  `gtimeout` is on PATH.
- OpenCode is not found: install it, or set `HH_OPENCODE` to an executable path.
- The guard denies nothing: OpenCode permission action names can change. Check
  the names against the OpenCode version you run. The guard is a data-flow
  filter, not a sandbox.
