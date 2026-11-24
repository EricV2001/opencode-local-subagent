# Security policy

This project runs a local model with tool access on your machine, so its safety layers matter. The
README's [Safety model and its limits](README.md#safety-model-and-its-limits) section describes what
the layers block and what they don't.

## Reporting a vulnerability

Please report security problems privately through GitHub:
**Security → Report a vulnerability** on this repository. Don't open a public issue.

Useful in a report:
- the OpenCode version, the OS, and whether the OS sandbox was on (`sandbox=` in the report header);
- the profile and flags used;
- a brief or folder that reproduces it.

## In scope
- Ways for the agent to escape its profile: running a shell command that should be denied, deleting or
  renaming files, or writing outside the folder or worktree.
- Ways for the agent or a cloned repo to read secrets the sandbox should hide, or to send data out with
  `--no-web` on macOS.
- Ways for a folder's contents to change the wrapper's behaviour, such as its git commands or its report.

## Supported versions
Only the latest release gets fixes.
