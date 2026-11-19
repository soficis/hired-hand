# Security policy

## Supported versions

0.1.x receives security fixes.

## Reporting a vulnerability

Use GitHub private vulnerability reporting for this repository. Do not open a
public issue for a vulnerability. Do not paste secrets, access tokens, private
paths or full run logs into an issue.

## Threat model

- The spec and repository files are untrusted input to a write-capable agent.
  A prompt injection can ask the agent to read files, run commands or change
  code.
- `build` runs with your user's rights and can edit any file that user can
  write, not only the files named in the spec.
- `review` is not a read-only sandbox. It uses the `plan` agent and does not
  enable `--auto`, but the agent can run shell commands that leave side effects,
  and `hiredhand` does not report changes in review mode.
- The training guard limits what a training-class model can read through
  OpenCode's `read` and `glob` actions and disables indirect-read tools, but it
  is not a sandbox. A broad glob can still enumerate filenames. It does not
  deny writes, and it cannot stop a tool that OpenCode adds under a different
  permission name.
- Provider-side data use is outside this tool's control. Check the provider's
  policy for the model you select.

## Guidance

- Use a disposable checkout or container for build runs.
- Keep secrets outside the working tree, and list project-specific secret
  globs in `.hiredhand/guard.txt` before approving a root.
- Review `hiredhand approvals` before running a training-class model.
- Treat run output and logs as potentially sensitive.
