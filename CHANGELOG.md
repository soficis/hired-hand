# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog, and this project uses semantic
versioning.

## [0.1.0] - UNRELEASED

### Added

- `hiredhand build` and `hiredhand review`, which hand a written spec to an
  OpenCode agent under a watchdog.
- Timeout, idle-stall, loop and step-cap detection, provider-error detection,
  and one optional retry on a different model.
- A training-class model guard that refuses unapproved project roots and
  generates an OpenCode permission config that denies secret-like paths and
  indirect-read tools inside approved roots.
- `hiredhand approve`, `approvals`, `outcome`, `stats` and `selftest`.
- A JSONL run log with per-run model, route, duration, exit code and change
  counts.
- Install and uninstall support through `install.sh`.
- CI for Linux, Windows and macOS, plus shellcheck on Linux.
