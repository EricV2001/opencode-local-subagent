---
name: opencode-local-subagent
description: Use when the user asks to delegate, offload or hand a task to a local model, OpenCode, LM Studio or a "local subagent", or when a well-scoped task (codebase exploration, summarising files, web research, a second-opinion review, a mechanical edit) could run on the user's own hardware instead of a Claude subagent.
---

# OpenCode local subagent

You are the **orchestrator and reviewer**. OpenCode, running on whatever model LM Studio has loaded
(locally or on a linked machine via LM Link), is a **background worker that starts cold**: it sees
none of this conversation. Its output is **untrusted until you have verified it**, and you own the
final quality.

The wrapper `scripts/run-opencode.sh` (in this skill's directory) detects the loaded model, applies a
permission profile, runs `opencode run`, and prints a compact report. Always call it through `bash`.

## When to use

| Delegate | Keep it yourself |
|---|---|
| Explore/summarise a codebase or files | Small tasks (faster to just do them) |
| Web research on a focused question | Design/architecture decisions |
| Second-opinion review of a diff | Anything needing user judgment mid-task |
| Scoped mechanical edits with a clear check | Secrets, credentials, `.env` contents |
| The user explicitly asks for the local subagent | Work that needs this conversation's context you can't summarise |

## Profiles

| Profile | Can edit? | Where it runs | Use for |
|---|---|---|---|
| `explore` (default) | no | in place | reading, searching, research |
| `review` | no | in place | second opinion on a diff or files |
| `build` | yes, no delete/rename | throwaway git worktree | edits; **refuses non-git folders** |

Every profile: shell is deny-by-default with a read-only allowlist; `rm`/`mv`/destructive git/`sudo`
and shell redirects (`>`) are denied; writes outside the folder are denied; skills and nested agents
are hidden; web is allowed. On macOS the whole run is also OS-sandboxed (`sandbox=on` in the report):
writes only to the worktree, OpenCode's own folders and temp. Add a project command with
`--allow-cmd "pytest"` (repeatable). Only use `--no-sandbox` if the user asks.
Add `--no-web` whenever the task doesn't need the web and the folder could hold secrets (`.env`,
keys, private data): a prompt injection in a fetched page could otherwise send them out.

## Workflow

1. **Pick the profile** and one bounded task. Split only into file-disjoint tasks, and run at most
   **2 at a time** (more doesn't speed up prompt processing).
2. **Write the brief** to a temp file in exactly this shape:

```markdown
# Task
<the outcome, one paragraph>

# Context
- Working directory: <path>. Key files: <paths, one-line role each>
- Conventions / commands: <test or build command, style rules>

# Requirements
1. <testable requirement>

# Definition of done
- <command or observable check>

# Out of scope
- <paths or concerns not to touch>

# Report format (end your answer with exactly these sections)
## Summary
## Changes made (file: what and why)
## Files to delete / rename (you cannot delete or rename; list them here with the reason)
## Open questions / uncertainties
```

3. **Launch in the background** with the Bash tool's `run_in_background: true`:

```bash
bash <skill-dir>/scripts/run-opencode.sh -C <dir> --profile <explore|review|build> -l <short-label> - < /tmp/brief.md
```

   Continue other work. You are notified when it exits; do not poll.
4. **Read only the report** (stdout). Open `events.jsonl` in the run dir only to debug.
5. **Verify.**
   - explore/review: spot-check the claims that matter against the actual files.
   - build: read the diff (`git -C <worktree> diff <baseline>..HEAD`, printed in the report), rerun
     the definition-of-done check inside the worktree, and judge each hunk.
6. **Merge build results selectively** into the user's working tree, uncommitted:

```bash
git -C <worktree> diff <baseline>..HEAD -- <chosen files> | git -C <repo> apply --3way
```

   Never commit for the user. For "Files to delete / rename", ask the user before doing it.
   Then `bash <skill-dir>/scripts/run-opencode.sh --cleanup <run-dir>`.
7. **Report to the user**: what was delegated, what you verified, what you took, what you left out and why.
8. **Follow up** on the same session with `--resume <session_id>` (it keeps the context) instead of a
   cold relaunch. Pass the same `--profile`. The wrapper runs the resume in the session's own
   directory; for build that's the same worktree, with the edits made so far. A build run that
   failed or gave no answer keeps its worktree for this, even without changes; `--cleanup` it if
   you don't resume.

## Speed expectations

The first run in a folder costs ~1–2 min (OpenCode's ~8.5k-token prompt is processed from scratch);
later runs in the same folder reuse LM Studio's prompt cache and start in seconds. Prefer `--resume`
for follow-ups. Generation is slower than a Claude subagent; keep tasks small.

## Report and exit codes

The report contains `RUN_DIR`, model/context/device, `session_id`, for build the changed files
(`!! DELETED:` lines first), blocked tool calls, and the final message.

| Exit | Meaning | Do |
|---|---|---|
| 0 | done | verify as above |
| 3 | empty answer (thinking model ran out, or it stopped after blocked calls) | `--resume <id>` with a short nudge, or narrow the task |
| 2 | usage error, including a `--resume` the wrapper can't place (unknown session, worktree removed) | start a new run |
| 4 | LM Studio unreachable, no model loaded, or context too small (it already waited ~3 min for a model to appear) | tell the user what the message says; don't retry blindly |
| 5 | build needs a git repo with at least one commit | use explore, or ask the user |
| 6 | run stopped on an error, shown under `--- run error ---` (e.g. LM Link dropped, or no output for 10 min) | for a link drop: `--resume <id>` once or twice, finished steps are kept; if it keeps dropping, tell the user |
| other | OpenCode error | read `stderr.log` in the run dir |

## Common mistakes

- `--allow-cmd` for a test runner in an explore/review run: those runs can't write to the folder,
  so caches and coverage files fail. Use a build run for anything that has to run tests.
- Every shell command containing `>` is denied, including harmless ones like `grep "a>b"`. If the
  report shows such blocks, rephrase the task; don't expect the agent to find a way around it.

- Brief relies on this conversation ("fix the bug we discussed"): the worker has none of it.
- Treating the final message as fact: verify file contents and rerun checks.
- Applying the whole build diff blindly instead of choosing hunks.
- Leaving worktrees behind: run `--cleanup` after merging; `--prune 14` clears old runs.
- Launching in the foreground: the user waits minutes for nothing.
