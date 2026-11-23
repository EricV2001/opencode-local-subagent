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
  - `explore`: read-only, runs in place, **no shell at all** (the native read/glob/grep/list tools do the discovery).
  - `review`: read-only, runs in place; the only shell commands are `git status`, `git diff`, `git log`, `git show`.
  - `build`: edits allowed, in a git worktree; shell = review's git commands plus `git add`, `git commit`,
    `mkdir`, `touch` (and whatever you add with `--allow-cmd`).
  - In every profile deleting, renaming, destructive git, `sudo` and writes outside the folder are
    blocked; nested agents and skills are hidden.
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
2. **OpenCode 1.x or 2.x** (tested with 1.19.5, 1.19.6, 2.3.0 and 2.4.1): `brew install sst/tap/opencode` (1.x), or v2
   as OpenCode's docs describe (`anomalyco/tap/opencode-v2`, `@opencode/cli`). The wrapper detects the
   version and refuses others. Each major version keeps its own sessions, so a session can't be resumed
   after switching between 1.x and 2.x.
3. `jq`, `git`, `curl`, bash. For the OS sandbox: macOS (built in) or Linux/WSL2 with `bubblewrap`. `lms` on PATH is optional; it lets the report show which device serves the model.
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

With a plugin install the script lives under `~/.claude/plugins/` in a folder that changes with each version,
so point the rule there and check it after updating.

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
| `-C, --cd <dir>` | working directory (default: current) |
| `--profile, -p explore\|review\|build` | permission preset (default `explore`) |
| `-l <label>` | names the run, branch and session |
| `-m <model>` | use this loaded model instead of auto-detect |
| `-v <variant>` | pass a model variant to OpenCode (`opencode run --variant`) |
| `--allow-cmd "<cmd>"` | add a shell command to the allowlist (repeatable); explore has no shell, this turns one on |
| `--allow-read <path>` | OS sandbox: also allow reading this absolute path, e.g. a toolchain in `$HOME` (`~/.pyenv`, `~/.nvm`, `~/.local`); repeatable |
| `--copy <path>` | build: copy a gitignored path into the worktree (real copy, never a symlink) |
| `--keep` | build: keep the worktree even if nothing changed |
| `--no-sandbox` | don't wrap the run in the OS sandbox (also what `build` needs where no sandbox exists, see below) |
| `--no-web` | deny the web tools for this run and, in the sandbox, pin the network to the LM endpoint (`net=pinned`); for repos with secrets, or tasks that don't need the web |
| `--web` | keep the web tools on where they would be off by default (no usable sandbox) |
| `--resume <id>` / `--fork` | continue (or fork) an earlier session, in the directory it started in (build: the same worktree) |
| `-f <file>` | attach a file to the prompt |
| `--ssh <host>` | reach LM Studio on `<host>` through an SSH forward instead of LM Link (see below) |

Environment: `LMSTUDIO_BASE_URL` (default `http://127.0.0.1:1234`), `OPENCODE_LOCAL_MODEL`,
`OCLS_HOME` (default `~/.cache/opencode-local-subagent`), `OPENCODE_ROUTER_RUNS`,
`OCLS_DETECT_TRIES` / `OCLS_DETECT_DELAY` (how long to wait for a model to appear, default 18 × 10 s,
which covers an LM Link reconnect), `OCLS_STALL_TIMEOUT` (stop a run that prints nothing for this many
seconds, default 600, `0` turns it off), `OCLS_AUTO_RESUME` (how often the wrapper continues the session by
itself after a connection drop, default 2, `0` turns it off), `OCLS_SSH_HOST` (same as `--ssh`),
`OCLS_SSH_LOCAL_PORT` (default 11234), `OCLS_SSH_REMOTE_PORT` (default 1234), `OCLS_SSH_WAIT` (seconds to wait
for the tunnel, default 20). The numeric settings must be digits only (exit 2 otherwise).

After a connection drop (LM Link, `ECONNRESET`, `fetch failed`, no model loaded...) the wrapper waits for the
model to come back and continues the same session with `-s`; the report then has an `auto_resumed=<n>` line.
A stall timeout or any other error is not resumed automatically.

### Flaky LM Link? Use the SSH route

LM Link can drop about every 10 minutes (`peer_keepalive_timeout`) even when the network is fine. With
`--ssh <host>` (or `OCLS_SSH_HOST`) the wrapper opens `ssh -f -N -L 127.0.0.1:11234:127.0.0.1:1234 <host>` and talks to
LM Studio's server on that machine directly; it needs passwordless ssh and `lms server start` there. The
tunnel is left running after the run and reused by later runs (an existing listener is reused only if it is the ssh this wrapper started for the same host, recorded in `$OCLS_HOME/tunnel-<port>`; a port held by anything else exits 4, set `OCLS_SSH_LOCAL_PORT`). Cannot
be combined with `LMSTUDIO_BASE_URL`. The report shows `device=ssh:<host>`.

Exit codes: `0` ok · `2` usage, or a `--resume` that can't be placed · `3` empty answer · `4` LM Studio
unreachable / no model / context too small · `5` build needs a git repo · `6` run stopped on an error,
e.g. LM Link dropped or the stall timeout (continue with `--resume`) · anything else is OpenCode's own
exit code.

A build run that fails or gives no answer keeps its worktree, even without changes, so it can be
resumed. Remove it with `--cleanup` if you don't.

## Safety model and its limits

OpenCode has no safety classifier: `--auto` approves everything that isn't explicitly denied. This
project therefore uses five layers:

1. **Permission rules** (`skills/opencode-local-subagent/profiles/*.json`).
   - Shell commands are denied by default and the allowlists are short (see the profiles above):
     OpenCode matches its patterns against the raw command text, so quoting or escaping defeats any
     deny pattern (`find . "-exec"`, `git log "--output=f"`, `rg --p're=sh'`), and tools like `find`,
     `sort`, `rg`, `tree`, `cat` all have program-running or file-writing options. So the allowlist
     shrank instead of the deny list growing: no `find`/`rg`/`sort`/`ls`/`cat`/`wc`/... (the native
     read/glob/grep/list tools cover discovery; an agent that misses `ls` or `wc` can be given them
     with `--allow-cmd`). The deny list stays as a second line for the unquoted forms: deletion,
     renames, destructive git, privilege escalation, redirects (`>`, `>>`, `tee`), `--output`.
   - No `ask` rules: in headless runs OpenCode auto-rejects them, so every outcome is a deterministic
     allow or deny.
   - The working folder's own OpenCode config (`opencode.json(c)`, `.opencode/`) is never loaded, so a
     cloned repo can't override these rules or load a plugin.
   - Edits are allowed in `build` except to `.git` (file or folder), which the wrapper itself relies on.
     The rules govern the agent's tools and commands only; they don't stop a command from reading files
     or writing outside the folder: for writes that is the OS sandbox's job (layer 2).
   - On OpenCode 2.x the rules are converted to its `permissions` list, preceded by a deny-all rule
     (2.x otherwise allows every action no rule mentions).
2. **Guard plugin** (`skills/opencode-local-subagent/plugin/guard/`). A small plugin, loaded by the
   wrapper through the config it injects (1.x `plugin`, 2.x `plugins`), from the skill's own folder,
   which the sandbox keeps read-only. Before any shell command reaches OpenCode's own rules it
   rejects (the call fails and shows under "blocked tool calls") a command that contains anything
   but letters, digits, space and `./_=:@%+,~^-` (so no quotes, backslashes, `$`, backticks,
   `; & | < > ( )`, tabs, newlines or non-ASCII), and any git command with `-c`/`-C`, `--git-dir`,
   `--work-tree`, `--exec-path`, `--config-env`, `--output*`, `--ext-diff`, `--textconv` or `--amend`,
   abbreviations included (`--am`). A consequence: `git commit -m "two words"` can't be written; the
   wrapper commits the result itself, so the agent doesn't need to. git run by the agent also gets
   a hardened environment: no global/system config, no pager, no fsmonitor, no external diff, no hooks,
   no signing, a fixed commit identity. Verified on OpenCode 1.19.5, 1.19.6, 2.3.0 and 2.4.1 against a fake model
   server (`tests/spikes/s24_guard_plugin.sh`, docs/findings.md S24).
3. **OS sandbox (macOS: `sandbox-exec`; Linux and WSL2: bubblewrap).** OpenCode and everything it starts run inside it. They can only
   write to the worktree, the parts of the repo's `.git` that a commit on its own branch needs (not
   hooks or config), temp folders, and a separate set of OpenCode folders under
   `~/.cache/opencode-local-subagent/opencode` (`opencode-v2` for 2.x). Your own OpenCode config, cache and data aren't used or
   writable, so nothing planted there can run later outside the sandbox. Even a test runner you
   allowlisted can't write elsewhere. The worktree's `.git` pointer file and the worktree's `HEAD` and
   `commondir` are read-only inside it, and before it runs any git command on the worktree (to commit
   the result and diff it) the wrapper checks that these still match what it recorded and runs git
   with a pinned git dir and hooks, fsmonitor and external diff off. If the agent changed them, the
   worktree is left alone and the run exits 6. Turn the sandbox off with `--no-sandbox`.
   - **Reads are confined too.** Nothing under `$HOME` can be read except the run's folder (for
     `build`: its worktree, not your original repo), that repo's `.git`, OpenCode's own folders, temp
     folders, the skill folder, the folder holding the `opencode` binary, common toolchain folders
     when they exist (`~/Library/Python`, `~/.pyenv`, `~/.nvm`, `~/.volta`, `~/.bun`, `~/.deno`, `~/.cargo`,
     `~/.rustup`, `~/go`, `~/.rbenv`, `~/.sdkman`, `~/.local/bin`, `~/.local/lib`, `~/.local/share/uv`),
     and what you add with `--allow-read <path>` (another toolchain for a build run's test command).
     System paths (`/usr`, `/opt/homebrew`, ...) stay readable. Secret files in the folder and `~/.ssh`
     stay denied even if you `--allow-read` a parent. `--allow-read` takes an absolute path and
     opens exactly that; secret-file denies only cover the run's folder.
   - **Linux and WSL2 (bubblewrap).** Same read and write rules, built from bind mounts: the whole
     filesystem is read-only, `$HOME` is replaced by an empty tmpfs, and only the paths above are mounted
     back (read-only, or writable for the worktree, OpenCode's folders and temp). The skill's guard folder
     and the `.git` pointers are read-only on top. `--unshare-pid` and `--die-with-parent` end everything
     the agent started with the run. Differences from macOS: (1) **no network pinning**: the network stays
     shared because LM Studio is reached on the host's localhost, so `--no-web` only turns OpenCode's web
     tools off and the header says `net=open`; (2) **secret files are masked once, at the start**: files
     and folders in the run's folder that match the patterns above are replaced by an empty file or
     folder, so ones created during the run are not masked (the agent can't create yours), and only down to
     8 folder levels deep; symlinks to secrets
     are not followed; (3) paths outside `$HOME` other than the system's (e.g. `/root`, other users' homes) are
     readable. Needs `bwrap` (`apt install bubblewrap`) and unprivileged user namespaces; on Ubuntu 23.10+
     AppArmor restricts them: run `sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0` or install
     a bwrap AppArmor profile. If bwrap doesn't work the wrapper says so and falls back as below.
   - **Network pinning.** With `--no-web` the sandbox also denies all network except outbound
     connections to the LM endpoint's port on localhost (the default `127.0.0.1:1234`, or the
     `--ssh` forward's local port); the report header says `net=pinned`. On OpenCode 2.x, which runs a
     local server of its own, loopback stays open but nothing leaves the machine (`net=loopback`).
     If the endpoint isn't on localhost the network can't be pinned: you get a warning and
     `net=open`; use the SSH route. Without `--no-web` the network is open (`net=open`).
4. **Worktree isolation** for edits. The worst case is a throwaway branch.
5. **Review by Claude** before anything reaches your working tree, uncommitted.

Known limits:
- Without a usable OS sandbox (native Windows/Git Bash; Linux without a working `bwrap`; or `sandbox-exec` broken) the wrapper warns and
  only the permission rules and the guard plugin remain. Then `build` **refuses to run** (exit 2) unless you
  pass `--no-sandbox` yourself (on native Windows that leaves explore/review only), because edits and shell commands would be limited only by OpenCode's own rules;
  `explore`/`review` run with a warning and the web tools **off** unless you pass `--web`. Inside another
  sandbox (e.g. Claude Code's own, where `sandbox-exec` can't nest) all profiles run as before: the outer
  sandbox is what confines them, and the wrapper says so.
- Secret files in the working folder (`.env`, `.env.*` except `.env.example`, `*.pem`, `*.key`, `*.p12`,
  `*.pfx`, `id_rsa`/`id_ed25519`/`id_ecdsa*`) and `~/.ssh` can't be read: permission rules block the tools and
  commands that name them, and the sandbox blocks every read of them, content search included (on Linux: files present at the start).
  Other secrets (other file names, files outside the folder) aren't covered.
- The report text from the model (final message, tool lines, errors) is untrusted: it is stripped of
  control characters, size-capped, and the final message sits between markers with a per-run nonce.
  The orchestrating model is told not to follow instructions in it, which is a mitigation, not a guarantee.
- Run files, `$OCLS_HOME` and worktrees are mode 700/600. Symlinks in your uncommitted work are copied
  as symlinks, not followed; `--copy` takes repo-relative paths without `..`.
- An ssh tunnel on the local port is reused only if this wrapper started it for the same host;
  another listener there makes the run stop (exit 4). A plain `http://` `LMSTUDIO_BASE_URL` to another
  machine produces a warning: use ssh or https.
- With the web on (the default on macOS) a prompt injection in a fetched page could make the agent read
  something it can see and send it out through the web tools. Use `--no-web` where it could read secrets,
  and don't run it at all where it could read secrets you wouldn't share with the model. What it can see
  is now the run's folder (reads under `$HOME` are confined on macOS), but anything in that folder counts,
  and `git log -p`/`git show` can show a secret that was once committed.
- The guard rejects per-driver git settings only by option (`--textconv`, `--ext-diff`); a `diff.<x>.textconv`
  or `filter.<x>` entry planted in the repo's own `.git/config` can't be turned off from outside. A build
  worktree's config can't be written by the agent (sandbox); an in-place explore/review run trusts the
  config of your own repo.
- Repos under `/tmp` or `$TMPDIR` get no `.git` protection, because temp folders are writable as a whole.
- Shell pattern rules are best-effort; the guard and the sandbox are the backstop.
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
