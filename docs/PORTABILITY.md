# Portability

## Tested

- Windows Git Bash
- Linux, including WSL Ubuntu

macOS code paths are portable but untested.

## macOS

macOS ships bash 3.2. `hiredhand` requires bash >= 4 and exits 2 with a hint on
older shells. Install bash from Homebrew and run the script with that bash.
macOS also lacks `timeout`; install Homebrew coreutils and keep `gtimeout` on
PATH. The installer and `hh_find_timeout` accept either name.

`readlink -f` is not available on older macOS. The entrypoint falls back to the
unresolved script path, which still works when the script is invoked by path.

## Paths and case

Windows paths appear as `C:/x`, `C:\x` or `/c/x` depending on the program.
`norm_path` unifies those forms and lowercases only on Windows. On POSIX it
preserves case.

The guard's `path_forms` emits forward-slash, backslash and drive spellings for
a root. `scan_mentions` also tries a lowercase comparison when the root looks
like a Windows path.

`OPENCODE_CONFIG` is converted with `cygpath -w` on Windows when available, so
a native OpenCode process receives a spelling it can open.

## Python

The Python probe runs `import sys; sys.exit(sys.version_info < (3, 8))`. The
Microsoft Store `python3` stub fails this probe, so the search falls through to
`python`. Set `HH_PYTHON` to skip the search.

## Processes

POSIX runs use `start_new_session=True` and kill the process group. Windows
runs use `CREATE_NEW_PROCESS_GROUP` and `taskkill /PID <pid> /T /F` so child
sessions die with the run.

## Shell details

- `mktemp` templates end in six `X` characters, with no suffix after them.
- The runner's wall-clock limit is 20 seconds shorter than the outer timeout,
  so it can kill and clean up the child tree before the outer timeout fires.
- Change detection does not rely on GNU-only `join` flags. Snapshot comparison
  is done in Python.
- Git Bash formats `sha256sum` output with a binary marker; the snapshot parser
  accepts both the text and binary forms.
