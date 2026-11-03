# opencode-local-subagent

A [Claude Code](https://claude.com/claude-code) skill that lets Claude hand tasks to a **local
subagent**: the [OpenCode](https://opencode.ai) CLI running on **whatever model is loaded in
[LM Studio](https://lmstudio.ai)**. The model can run on the same machine or on another machine
linked through [LM Link](https://lmstudio.ai/docs/lmlink/basics/faq).

Claude stays the orchestrator and reviewer. The local model does the work in the background and
returns a short report. Edits happen in a throwaway git worktree, and Claude merges only the parts
that hold up.

```
Claude Code ──(skill)──> run-opencode.sh ──> opencode run ──> LM Studio (localhost:1234)
     ▲                         │                                   │ LM Link (optional)
     └──── compact report ─────┘                                   └──> model on another machine
```

## What it does

- **Model-agnostic.** The wrapper asks LM Studio which model is loaded (`/api/v0/models`) and passes
  the provider config to OpenCode inline. It doesn't touch your `opencode.json` and needs no
  `opencode auth login`. Switch models in LM Studio and the next run uses the new one.
- **Permission profiles.**
  - `explore` / `review`: read-only, run in place.
  - `build`: edits allowed, in a git worktree.
  - In every profile, shell commands are denied unless allowlisted; deleting, renaming, destructive
    git, `sudo` and writes outside the folder are blocked; nested agents and skills are hidden.
- **Worktree builds.** `build` copies your uncommitted work into a fresh worktree, records a baseline
  commit, lets the agent edit, commits the result, and reports the diff with deletions flagged.
  If nothing changed, the worktree is removed.
- **Report, not transcript.** Claude reads a compact report: the changes, blocked tool calls and the
  agent's final answer. The full event log stays on disk.
- **Behaves like Claude's own subagents.** Each run starts in a fresh context, runs in the
  background, can be resumed with `--resume <session_id>`, and doesn't spawn agents of its own.

## Requirements (per device)

1. **LM Studio** with its local server running (`lms server start`, or the Developer tab).
   - To use models on another machine: sign in with the same account on both and enable LM Link
     (`lms login`, `lms link enable`). Remote models then appear on `localhost:1234`.
2. **OpenCode**: `brew install sst/tap/opencode` (or see [opencode.ai](https://opencode.ai)).
3. `jq`, `git`, `curl`, bash. `lms` on PATH is optional; it lets the report show which device serves the model.
4. A loaded model with **tool calling** and a context of at least ~12k tokens; 32k+ is recommended.

## Install

**As a Claude Code plugin** (works on any device):

```
/plugin marketplace add EricV2001/opencode-local-subagent
/plugin install opencode-local-subagent@opencode-local-subagent
```

**Or as a plain skill** (symlink):

```bash
git clone https://github.com/EricV2001/opencode-local-subagent.git
cd opencode-local-subagent && ./install.sh     # links into ~/.claude/skills and checks requirements
```

Optional, to stop Claude asking for permission every time it launches the wrapper, add to
`~/.claude/settings.json` (adjust the path to where the skill lives):

```json
{ "permissions": { "allow": ["Bash(bash ~/.claude/skills/opencode-local-subagent/scripts/run-opencode.sh:*)"] } }
```

## Usage

Just ask Claude, e.g. *"have the local subagent summarise how auth works in this repo"* or
*"delegate the lint fixes in src/utils to the local model"*. The skill tells Claude how to write the
brief, launch the run in the background, review the result and merge it.

The wrapper also works on its own:

```bash
S=skills/opencode-local-subagent/scripts/run-opencode.sh
bash $S -C ~/code/app "List the HTTP endpoints and their handlers"           # explore (default)
bash $S -C ~/code/app --profile build -l fix-calc - < brief.md                # edit in a worktree
bash $S -C ~/code/app --profile build --allow-cmd "pytest" - < brief.md       # allow the test runner
bash $S -C ~/code/app --resume ses_123 "Tests still fail on X; fix that"      # follow-up, same context
bash $S --cleanup ~/.cache/opencode-local-subagent/runs/<run>                 # remove worktree + branch
bash $S --prune 14                                                            # delete runs older than 14 days
```

| Flag | Meaning |
|---|---|
| `-C <dir>` | working directory (default: current) |
| `--profile explore\|review\|build` | permission preset (default `explore`) |
| `-l <label>` | names the run, branch and session |
| `-m <model>` | use this loaded model instead of auto-detect |
| `--allow-cmd "<cmd>"` | add a shell command to the allowlist (repeatable) |
| `--copy <path>` | build: copy a gitignored path into the worktree (real copy, never a symlink) |
| `--keep` | build: keep the worktree even if nothing changed |
| `--resume <id>` / `--fork` | continue (or fork) an earlier session |
| `-f <file>` | attach a file to the prompt |

Environment: `LMSTUDIO_BASE_URL` (default `http://127.0.0.1:1234`), `OPENCODE_LOCAL_MODEL`,
`OCLS_HOME` (default `~/.cache/opencode-local-subagent`), `OPENCODE_ROUTER_RUNS`.

Exit codes: `0` ok · `2` usage · `3` empty answer · `4` LM Studio unreachable / no model / context
too small · `5` build needs a git repo · anything else is OpenCode's own exit code.

## Safety model and its limits

OpenCode has no safety classifier: `--auto` approves everything that isn't explicitly denied. This
project therefore uses three layers:

1. **Permission rules** (`skills/opencode-local-subagent/profiles/*.json`). Shell commands are
   denied by default, plus explicit denies for deletion, renames, destructive git and privilege
   escalation. No `ask` rules: in headless runs OpenCode auto-rejects them, so every outcome is a
   deterministic allow or deny.
2. **Worktree isolation** for edits. The worst case is a throwaway branch.
3. **Review by Claude** before anything reaches your working tree, uncommitted.

Known limits:
- A git worktree isn't a sandbox. A command that *is* allowed (e.g. a test runner you allowlisted)
  runs arbitrary code with your user's rights.
- Shell pattern rules are best-effort: keep the allowlist small.
- Gitignored files (`.env`, `node_modules`, data) aren't in the worktree unless you `--copy` them.

## Performance notes

Measured with a large MoE model served over LM Link (details in [docs/findings.md](docs/findings.md)):
- OpenCode's prompt is about 8.5k tokens. The first run in a folder pays full prompt processing
  (~1 min at ~134 tok/s). Later runs in the same folder hit LM Studio's prefix cache and start in seconds.
- Hiding skills from the subagent cut the prompt from 14.7k to 8.4k tokens and made it cacheable.
- Parallel cold runs don't add throughput, so run 1–2 at a time.
- Memory levels off after the first run; it doesn't grow per run.

## Tests

```bash
bash tests/run_tests.sh      # deterministic: stub opencode/lms, fixture LM Studio API (no model needed)
bash tests/live/e2e.sh       # live: explore + build against your running LM Studio (skips if unreachable)
```

`tests/spikes/` holds the experiments behind the design decisions.

## Credits

Forked from [luckeyfaraday/delegate-to-opencode](https://github.com/luckeyfaraday/delegate-to-opencode)
(MIT), which provided the original wrapper: run directories, session capture, resume/fork and briefs
via stdin. This fork adds LM Studio auto-detection, permission profiles, worktree builds and the
local-model skill.

## License

MIT, see [LICENSE](LICENSE).
