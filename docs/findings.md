# Spike findings

This is the project's development log: each section records a measurement or a design decision in
the order it was made (so the numbering isn't strictly sorted, and early sections describe behaviour
that later sections changed). The README describes the current behaviour.

Environment: OpenCode 1.19.5 (Homebrew), LM Studio over LM Link, model
`swift-1.5-qwen3.8-flash-next-gsq-rco` (served by the Mac Studio), macOS 27.
Shared helpers: `tests/spikes/common.sh`.

## S1 — fresh context per run ✅ (`s1_fresh_session.sh`)
- Two plain `opencode run` calls get different session IDs, and the second didn't know the
  secret word from the first.
- `-s <session_id>` resumes with the earlier context intact (it recalled the word).

## S2 — config injection via `OPENCODE_CONFIG_CONTENT` ✅ (`s2_s5_config_and_events.sh`)
An inline provider config (`@ai-sdk/openai-compatible`, `baseURL: http://127.0.0.1:1234/v1`,
model id from `/api/v0/models`) works with `-m lmstudio/<id>`, with no `opencode.json` on disk and
no `opencode auth login`.

## S3 — `ask` in a headless run ✅ (`s3_headless_ask.sh`)
- With no `--auto`, an `ask` rule is **auto-rejected** (stderr: `permission requested: … ; auto-rejecting`).
  The tool event has `status:"error"`, "The user rejected permission…". **It doesn't hang.**
- After the rejections the model produced **no final text** (138 s). This confirms that we need
  the empty-answer check (exit 3).
- Design consequence: still avoid `ask` (use only allow/deny) so outcomes are deterministic;
  `--auto` stays on.

## S4 — deny enforcement with `--auto` ✅ (`s4_deny_enforcement.sh`)
Permissions: `edit: allow`, `external_directory: deny`, `task/webfetch/websearch/doom_loop: deny`,
`bash` deny-by-default with an allowlist plus explicit denies.
- `rm victim.txt && ls …` → **denied** (compound commands are parsed; the `rm` part matched the deny).
- The `python3 -c os.remove` deletion was refused as well (the model saw the deny rule and didn't try to get around it).
- Writing a new file inside the project → **allowed**.
- Writing a file outside the project → **denied** by `external_directory`. Note that OpenCode always
  allows its own temp/tool-output directories (`$TMPDIR/opencode/*`).
- Error text returned to the model: "The user has specified a rule which prevents you from using
  this specific tool call…". The model reported each blocked step clearly.
- Runtime: 254 s for 4 small steps with this model, so the SKILL should use background runs.

## S5 — JSON event format (OpenCode 1.19.5) ✅
Event types: `step_start`, `text`, `tool_use`, `step_finish`. Every event has top-level `type`,
`timestamp`, `sessionID`, and a `part` object.
- text: `.part.text`
- tool_use: `.part.tool`, `.part.state.status` (`completed|error`), `.part.state.input`, `.part.state.error`

**Upstream bug:** `run-opencode.sh` reads the final message from `.text // .data`, but the text is at
**`.part.text`**, so upstream's `last_message.txt` comes out empty. Fix: `.part.text // .text`,
joined with newlines. Report denied tool calls too (tool_use with `status=="error"`).

## S8 — LM Link ✅ (partly)
- `localhost:1234/api/v0/models` lists **only the loaded model**, served by the Mac Studio
  (`lms ps --json` → its `deviceIdentifier` matches the remote device in `lms ls`).
  Models that are only downloaded (local or remote) don't appear, so the filter `state=="loaded"` is enough.
- `loaded_context_length` (46848) and `parallel` (4, from `lms ps --json`) are reported for the remote model.
- `lms ps --json` gives a `deviceIdentifier` (a hash), not a readable name. `lms ls` lists models
  per device. The report shows "local" vs "remote (LM Link)" by comparing against local device models where possible.
- Pending: (d) zero-config check on a second device.

## S9 — where the time goes ✅ (`s9*_*.sh`)
Question: why does a trivial "reply PONG" take ~120 s?
- Not the binary (`opencode --version` 0.2 s), not models.dev, update checks or LSP downloads
  (turning those off made no difference), and not title generation (`--title` → still 116 s).
- `lms ps` shows `generating` for the whole stall, and the opencode process has 2 connections to `:1234`.
- **Cause: prompt processing.** Raw LM Studio test (`s9f`): this model processes prompts at **~134 tok/s**
  without cache. OpenCode's prompt is **~14.7k tokens** even for a trivial task → ~110 s.
  OpenCode's `step_start` is only emitted at the first output token, so the step timings
  in the events leave prompt processing out.
- **The prefix cache works:** an identical 24k-token prompt went from 179 s to **1.1 s** the second time.
- **The default prompt isn't cache-stable across runs:** two default runs in the same folder had 14,745 vs 14,627
  input tokens (the content changes, most likely the skills list from `~/.claude/skills`), so both were cold (119 s / 117 s).
- **`skill: deny` fixes both problems** (`s9g`): prompt **8,448 tokens (−43%)**, cold run **69 s**, and
  the next run in the same folder **4 s** (cache hit).
- Generation speed (from S4): ~20–25 tok/s output, including reasoning tokens.

**Design consequences:**
1. All profiles set `skill: "deny"`. That gives a smaller prompt that stays the same across runs, and it also stops the
   subagent from seeing/using Claude's skills, including this one (no recursion).
2. Try removing more unused tool definitions (`tools: { todowrite:false, webfetch:false, websearch:false, … }`)
   to shrink the prompt further, and measure it.
3. The first run after a model load (or after the cache is evicted) costs ~1 min. Later runs in the same project are cheap.
   The SKILL.md should say so, and prefer `--resume` for follow-ups.
4. When choosing a faster model: prompt-processing speed matters most for this workload (~8k-token prompt per run),
   more than generation speed.

## S10 — is it worth hiding web/todo tools? ❌ not worth it (`s6_s10_memory_and_tools.sh`)
All with `skill: deny`, cold runs:
| Variant | Input tokens | Cold time |
|---|---|---|
| A baseline | 8,451 | 73 s |
| B + webfetch/websearch denied | 8,143 (−308) | 63 s |
| C + todowrite denied | 7,507 (−944 total, −11%) | 61 s |
| D same as C via `tools: false` | 7,507 | 61 s |
- `permission: deny` removes the tool from the prompt just like `tools: false` does.
- Gain: at most ~1k tokens ≈ 7–10 s on a **cold** run, and nothing on warm (cached) runs.
- **Decision:** keep web tools available (research tasks) and keep todowrite (it helps local models with
  multi-step tasks). This revises R6, which denied webfetch/websearch by default: the profiles allow them.

## S6 — memory ✅ (Mac Studio over SSH, sampled every 5 s; 96 GB RAM machine)
- Before: `llama-server` RSS 73.2 GB, 10% free, swap 7.0 GB.
- First run: RSS → ~77 GB (+3.8 GB as KV/cache pages get touched), swap → 8.6 GB.
- 4 sequential runs: RSS stays at 77–78 GB.
- 3 parallel runs: peak 78.3 GB, swap 8.95 GB.
- 30 min afterwards: **stable at 76.9 GB**, swap slowly going down (8.87 GB). Nothing keeps growing per run.
- **Conclusion:** memory levels off after the first use and doesn't build up across runs. But the machine is
  tight (7–15% free, ~9 GB swap) with this 85 GB model. That's a reason to choose a smaller model, apart from speed.

## S6b — parallel runs don't speed up cold starts
- 3 parallel cold runs took **212 s each**, vs ~65 s for one. Total prompt throughput 3 × 8.45k / 212 s ≈ 120 tok/s,
  the same as serial: prompt processing uses all the compute, so parallel slots don't add throughput there.
- **Design consequence:** SKILL.md recommends at most 1–2 concurrent runs. Parallel only helps when prompts are warm
  (cached) and the work is mostly generation.

## S11 — shell redirects escaped the folder ❌ → fixed ✅ (`s11_redirect_escape.sh`)
- With the first profiles, `echo x > /abs/path`, `cat a.txt > ~/file` and `echo >> ../file` **all
  ran and wrote outside the worktree**. `external_directory` doesn't cover bash redirect targets, and a
  redirect after an allowlisted command (`echo`, `cat`) matched the allow rule. A redirect can also
  **overwrite existing files**, which is effectively deletion.
- (When the brief called itself a "security test", the model refused on its own. Don't rely on that;
  with neutral wording it complied.)
- OpenCode matches bash rules against the **full command text, including the redirect**, so a deny
  rule `"*>*"` (after the allowlist) blocks every redirect. Verified live: all 4 attempts were denied.
  This also blocks `2>&1` and `>/dev/null`; the agent writes files with its edit tool, which respects
  the folder boundary.
- Also denied: other ways allowlisted commands can write files (`tee`, `find -fprint/-fls`, `sort -o`,
  `tree -o`, `git --output`, `rg --pre` (runs a program), `file -C`); `uniq` was removed from the
  allowlist (it writes its 2nd argument).
- Remaining limit at this point: any command added with `--allow-cmd` (e.g. a test runner) runs
  arbitrary code. That's covered by S12.

## S12 — OS sandbox (macOS `sandbox-exec`) ✅ (`s12_sandbox_allowcmd.sh`)
- The wrapper runs OpenCode under `sandbox-exec` with `(deny file-write*)`. Writes are re-allowed only
  for `/dev`, the temp dirs, OpenCode's own dirs (`~/.local/share|state/opencode`, `~/.cache/opencode`,
  `~/.config/opencode`), and for build runs the worktree plus the repo's git common dir (where the
  worktree's commits go). Reads and network are unrestricted. The profile is saved as `sandbox.sb` in the run dir.
- Live: with `--allow-cmd python3`, `python3 -c "open('~/…','w')"` was allowed by the rules and executed,
  but failed with a **permission error from the OS**, so the file wasn't created. Explore and build e2e runs
  work normally under the sandbox (no errors in `stderr.log`).
- Falls back to rules only (with a warning) when `sandbox-exec` is missing (Linux/Windows) or can't be
  applied (already inside another sandbox). `--no-sandbox` turns it off.

## S13 — LM Link drops during real use (`s13_link_under_load.sh`)
First real test from a fresh Claude Code session, with the laptop and the Mac Studio in different regions.
- Two explore runs died with `LM Link connection entered error state peer_keepalive_timeout`, 16–26 s
  after a step that read files. A third attempt exited 4 ("no model loaded") while the link was down.
- **Not caused by the wrapper, and not explained by the version difference:** the Mac Studio's logs show
  drops on every day from Nov 2 (61, 26, 85, 42, 1 distinct minutes on Nov 2–6), also when no subagent was running.
- Network between the machines at the time (ping over a separate VPN mesh, a different tunnel than LM Link but
  likely the same internet path): **259 ms average, 10% packet loss**.
- Not reproduced on demand: one ~20k-token prompt over LM Link finished in 177 s. During it the Mac
  Studio dropped to 4–5% free memory and `/api/v0/models` timed out twice, so load may contribute.
  Cause of the individual drops isn't proven.
- **Wrapper bugs found and fixed:** error events weren't shown (they looked like an empty answer, exit 3,
  blamed on a thinking model) → now a `--- run error ---` section and exit 6. Detection tried only once → now
  4 tries, 5 s apart (`OCLS_DETECT_TRIES`, `OCLS_DETECT_DELAY`), and the message mentions LM Link.
- **Retest over LM Link with the fixed wrapper, same brief:** finished in one attempt (433 s, 8 steps,
  20 tool calls, ~35k input tokens on the last step), with no drops logged during the run (13:11–13:18
  laptop time). Spot-checked claims in the report were correct.
- **The drops continued afterwards:** 11 more distinct minutes between 13:38 and 15:01, with no live
  run in progress from these tests, for 18 on Nov 6 so far. One clean run doesn't show the link is stable.
- Exit 6 and `--resume` are tested with the stub and against the events of a real failed run, but
  haven't yet been seen on a live drop.

## S14 — resume after a live drop ❌ → fixed ✅
First build run in this repo over LM Link (Nov 6):
- The link dropped after 3 read-only steps. **Exit 6 worked live**: the report showed
  `peer_keepalive_timeout` under `--- run error ---` and gave the `--resume` command.
- The model stayed loaded and idle on the Mac Studio, but it was missing from `localhost:1234` for
  about 2 minutes. The log shows a reconnect attempt every ~20 s for ~80 s per drop. The first resume
  exited 4 after the 15 s detection window.
- **Resuming a build session from a different directory fails.** The wrapper created a new worktree
  for every run, so the resumed session ran in a different `--dir` than the one it started in.
  - Original worktree already removed: `UnknownError: Unexpected server error` after a few seconds,
    with nothing in LM Studio's or OpenCode's logs.
  - Original worktree still there: the run hung for 20 minutes with no events while the model sat idle.
  - Also, edits made before a drop stayed in the old worktree and weren't in the new one.
- **Fixes:**
  - `--resume` looks up the session's run dir (`session_id` + new `run_in` file) and runs in that same
    directory. For build it reuses the worktree and baseline. It refuses (exit 2) if that worktree is
    gone, or if no build run is known for the session.
  - A build run with no changes keeps its worktree unless it finished with an answer.
  - Stall watchdog: if OpenCode prints nothing for `OCLS_STALL_TIMEOUT` (600 s) the run is stopped,
    exit 6. It's generous because no events arrive during prompt processing.
  - Detection waits up to ~3 min (18 × 10 s) for a model to appear, but gives up after the second try
    when the local server doesn't answer at all.
- **Live check (Nov 9, scratch repo):** build run → resume of the same session continued in the same
  worktree (`note.txt` had the line from each run, one branch); explore run → resume ran in the original
  folder and remembered its earlier answer. All four runs exit 0; the watchdog didn't fire.
- **Live drop with the fixed wrapper (Nov 9, this repo, build):** the link dropped after 2 steps
  (`connection_closed`, 11:52) and the empty worktree was kept. Resume 1 waited for the model to come back
  (the new wait message), went into the same worktree, and dropped again within seconds while the link
  was still settling (`peer_keepalive_timeout`, 11:53). Resume 2 finished: exit 0, the README edit is in
  the original worktree, `rm` was blocked and the file was listed under "Files to delete / rename".
  Both drops were one outage; there were no others that morning.

## S15 — review of the safety layers (Nov 9) ❌ → fixed ✅
A review from another session; each item was checked before fixing.
- **Shared `.git` was writable.** The sandbox allowed the repo's whole git common dir, so a sandboxed
  process could write `.git/hooks/*` or `.git/config`, which later run or apply outside the sandbox.
  Confirmed with `sandbox-exec`. Now only these are writable: the worktree's own git dir
  (`.git/worktrees/<name>`), `objects/`, `refs/heads/opencode/` and `logs/refs/heads/opencode/`. A
  `git commit` in the worktree still works (git prints a harmless `packed-refs.lock` warning); hooks,
  config and moving `main` are blocked.
- **`find -exec …` / `find -delete` with no path got through.** OpenCode 1.19.5's matcher (found in
  the binary's bundled source) escapes regex characters, turns `*` into `.*`, makes a trailing ` *`
  optional, and anchors the pattern. `find * -exec*` therefore needs a space before `-exec`, so
  `find -exec rm {} \;` matched only the `find *` allow. Added path-less denies. `run_tests.sh` now
  checks commands against the profiles with the same matcher.
- **The user's OpenCode dirs were writable** (`~/.config`, `~/.cache`, `~/.local/share|state` /opencode).
  Plugins, provider packages or tool binaries planted there would run later in unsandboxed OpenCode
  sessions. OpenCode honours the XDG variables, so delegated runs now get their own dirs under
  `$OCLS_HOME/opencode/` and only those are writable. Sessions from before this change can't be resumed.
- **A prompt starting with `-` was read as a flag** (`--title` → "You must provide a message"). The
  prompt is now passed after `--`, which `opencode run` accepts.
- Smaller items: `--cleanup`'s `rm -rf` fallback only removes paths under `$OCLS_HOME/worktrees/`;
  `--prune` help says pruned sessions can't be resumed; SKILL.md notes the `>` deny and that test
  runners need a build run.
- Web tools stay allowed by default (research tasks need them), so the risk of exfiltration through a
  prompt injection remains. New `--no-web` flag denies `webfetch`/`websearch` for a run; SKILL.md tells
  Claude to use it when the web isn't needed and the folder could hold secrets.
- Each fix was checked by putting the old behaviour back: the new tests fail (3 each), then pass again.
- Live (repo outside temp, real model): with its own OpenCode dirs, OpenCode fetched the provider
  package once (5.7 MB cache) and stored the session in its own data dir; the user's dirs were
  unchanged. The agent's `git add` + `git commit` in the worktree succeeded under the narrow `.git`
  rule (with the `packed-refs.lock` warning). The first attempt was cut off by an LM Link drop.

## S16 — staged work didn't reach the build worktree ❌ → fixed ✅
Found by the local model during a review run, then confirmed with a test.
- The worktree copy used `git ls-files -m -d -o`, which compares the working copy with the **index**.
  Fully staged changes therefore looked unchanged: staged new files, staged edits, `git rm` and
  `git mv` were all missing, so the agent started from an older state than the user's working copy.
  Its diff could then undo or clash with the staged work when merged.
- Fix: copy everything in `git diff --name-only --no-renames HEAD` (staged and unstaged, renames split
  into delete + add) plus untracked, non-ignored files, taking each file as it is on disk.
- Test covers staged new/modified/deleted/renamed files and a file staged then edited again; the
  user's staged work isn't reported as the agent's change.

## S17 — the local model's own review (Nov 13)
An explore run on the local model reviewed the repo (one LM Link drop, resumed in the same session;
its `cat >` into `/tmp` was blocked as intended). Another Claude session checked its 10 suggestions;
each fix here has a test that fails when the fix is undone.
- Staged work missing from the worktree: see S16.
- `--resume` with an unknown session went straight to OpenCode for explore/review. Delegated runs keep
  their sessions in their own data dir (S15), so such an id can't be resumed anyway: every profile now
  exits 2 before starting OpenCode. Resuming a read-only session as build also exits 2.
- `--help` printed a fixed 19 lines and cut off the exit codes and settings; it now prints the whole header.
- The "blocked" list included every failed tool call. Real runs had 9 rule denials and 1 `File not found`
  read listed as blocked. Now only permission denials are listed as blocked; other failures get their own
  section with the error. Shell commands that exit non-zero are `completed`, not errors, so they don't
  show up in either section.
- The stall stop only reached OpenCode's direct children, so e.g. a test runner under the agent's shell
  kept running. OpenCode now starts in its own process group (via perl `setpgrp`), and the stall stop
  and Ctrl-C/TERM on the wrapper end the whole group.
- Tests were added for `--fork`, `-v` and `-f` pass-through. CI gets a macOS job that runs the sandbox
  tests and fails if they would be skipped (`OCLS_REQUIRE_SANDBOX=1`).
- Skipped: `--cleanup` on an explore run (SKILL.md only cleans up build runs), worktree leaks when
  `OCLS_HOME` changes, and fencing the final message (it's already treated as untrusted).
- This Mac only has `/bin/bash` 3.2, so the wrapper and tests already run on macOS's built-in bash.

## S18 — why LM Link drops, and what the wrapper does about it (Nov 16)
- About 80% of the drops in the laptop's log (105 of 132 bursts, Nov 9–16) fall within 5 s of the laptop
  waking; it dark-wakes about every 16–17 min when idle. Those are the idle and night-time drops seen on
  both machines, and they are harmless. The Mac Studio never sleeps (`sleep 0`).
- The harmful ones happen while the laptop is awake, in clusters about every 10–15 min, and kill the request
  in flight. Every failed run died at or within seconds of a `step_start` (a new request), never mid-stream.
  Prompt size doesn't predict it: a 49k-token step with a 174 s silence succeeded.
- Controlled test, 45 min, laptop kept awake with `caffeinate`: LM Link vs an SSH tunnel to the same LM Studio
  server (over a separate VPN mesh) vs ping, side by side. LM Link dropped twice (`peer_keepalive_timeout`,
  9 min 44 s apart, 9 s and 14 s long). Ping lost 1 of 2700 packets (median 247 ms) and showed no loss during
  either drop. The tunnel answered 540 of 540 probes and 30 of 30 requests. So the path is fine; LM Link's own
  keepalive/transport is what fails. Why it fails isn't known (the apps log only errors, and there is no
  keepalive setting); matching reports: lmstudio-bug-tracker #2184, #1647, #1983.
- LM Link was also slower per request in that test: a tiny chat request took a median 10.5 s through LM Link
  vs 2.5 s through the tunnel.
- The "No models loaded" failure (Nov 9) was the laptop's view after a drop: the Studio logged no unload, the
  model has no TTL, and no crash or jetsam kill of the engine was found. Memory on the Studio is tight
  (about 10% free, 8 GB swap) but nothing ties it to the drops.
- Not tested: quitting the other VPN mesh (both it and LM Link's Tailscale use the 100.64.0.0/10 range), and updating the
  Studio from LM Studio 0.4.25 to the laptop's 0.4.28.
- Wrapper changes: auto-resume after a connection drop (`OCLS_AUTO_RESUME`, default 2), and an optional SSH
  route (`OCLS_SSH_HOST` / `--ssh`) that bypasses LM Link.
- Live results: an LM Link run that dropped twice (`peer_keepalive_timeout` after 3 min 19 s and again
  8 min 17 s later) finished by itself with `auto_resumed=2` in 1040 s; the model was back about 21 s after
  each drop. The same task over the SSH route: 638 s, no errors. SSH route also passed explore, build, manual
  `--resume`, and reopening a killed tunnel.
- Not yet seen live: auto-resume over the SSH route (it never dropped), and the tunnel's behaviour after
  laptop sleep.

## S19 — after updating the Studio to LM Studio 0.4.28; speed and thinking settings (Nov 17)
- LM Link: a 15-min repeat of the S18 test (laptop awake) had no drop on either path (180/180 probes each;
  tiny requests median 3.6 s over LM Link vs 0.8 s over SSH). The laptop's log still shows LM Link errors
  that day about every 1.7–3 h (06:04, 07:47, 10:45, 13:53), against every ~10 min before: much better, not gone.
- Speed on the Studio (llama.cpp runtime 2.77.0 that came with the update, Unsloth UD-IQ3_XXS quant of the
  same model, 2 slots, q8_0 KV): generation went from 22–24 tok/s to ~40 tok/s and prompt processing from
  ~110 to ~470–600 tok/s. The runtime and the quant changed at once, so the split between them is unknown.
- MTP (multi-token prediction) needs `--spec-type draft-mtp` plus `--spec-draft-model <mtp-*.gguf>` as
  load arguments in LM Studio; picking the MTP file as a normal draft model (`draft-simple`) doesn't load.
  With 3 draft tokens: 45 tok/s, 45% of drafts accepted. Draft tokens 2 / 3 / 5 averaged 51.1 / 50.7 /
  52.3 tok/s (at medium thinking) — within noise; 5 varies most (45–59), 2 least (49–54). Settled on 2.
- Thinking: the model's template takes `reasoning_effort` (default `xhigh`). As a load argument
  (`--chat-template-kwargs {"reasoning_effort":"medium"}`) it works: output for a similar prompt went from
  604 to 224 tokens, and draft acceptance rose to ~55% (answer text is easier to predict than thinking),
  so ~52 tok/s. Per request it does nothing: LM Studio's OpenAI-compatible endpoint ignores both
  `chat_template_kwargs` and `reasoning_effort` in the body (5 variants, byte-identical output at
  temperature 0). So OpenCode can't choose a thinking level per run while LM Studio serves the model;
  plain `llama-server` would honour it.
- Tested the local subagent itself on this repo: its review found four real bugs in `ensure_tunnel` and the
  report path (die inside the auto-resume loop skipped the report and exited 4 instead of 6; an own
  tunnel to a busy server was blamed on "another process"; a failing `ssh` still waited `OCLS_SSH_WAIT`;
  the stderr tail showed attempt 1 after a resume). A build run fixed them with regression tests; each
  new test fails against the old wrapper.

## S20 — secret files (Nov 17)
- Live test with a canary `.env` and `.pem`, OpenCode 1.19.5: `read` accepts a pattern object
  (`{"*":"allow","*.env":"deny",...}`, last match wins), and with it the read tool and `cat .env` were blocked.
  But content search still leaked both canaries: the grep tool and `grep -r canary .` (path rules only see
  paths and command strings).
- Fix: the macOS sandbox also denies `file-read*` on those names inside the working folder (and `~/.ssh`).
  Retest: read tool `FileSystem.stat` error, grep tool "No files found", `grep -r` "Operation not permitted",
  no canary anywhere; ordinary files and `.env.example` still readable, and OpenCode ran normally. System
  `.pem` files outside the folder stay readable (TLS roots for the web tools).

## S21 — OpenCode 2.x, and a folder's own config overriding the rules (Nov 18)
- OpenCode 2.3.0 (`@opencode/cli`) vs 1.19.5. The old wrapper failed closed on 2.x ("Unrecognized flag:
  --dir"). A naive port (drop `--dir`) would have been unsafe: 2.x ignores `OPENCODE_PERMISSION`, and with
  it read `.env`, `rm`, `echo x > f`, `python3 -c` and the write tool all ran (the macOS sandbox stopped
  only the `.env` read).
- 2.x differences the wrapper now handles: rules go into the config as an ordered `permissions` array
  (`{action, resource, effect}`, last match wins; `bash`→`shell`, `task`→`subagent`; `lsp`/`doom_loop` are
  gone); its base policy **allows** every action no rule mentions (incl. new ones such as `execute`), so
  the array starts with a deny-all; `provider`→`providers`; no `--dir` (runs in the cwd) and no
  `--variant` (`-m provider/model#variant`); `--standalone` for a private server; denials read
  `Permission denied: <tool>`, the path input is `path`. Otherwise the JSON events are unchanged. Sessions
  live in a separate data dir per major version.
- **Hole in both versions:** a hostile `opencode.json(c)` in the working folder (top-level and agent-level
  "allow everything") overrode the wrapper's rules on 1.19.5 and 2.3.0 alike: without the sandbox, `.env`
  was read, a file deleted, a redirect and python ran. A `.opencode/plugin/*.js` also loaded on 1.19.5
  (OpenCode even ran an npm install for it). Fix: `OPENCODE_DISABLE_PROJECT_CONFIG=1` (honoured by both).
  Live retest through the new wrapper, hostile repo, `--no-sandbox`: all five attempts blocked on both
  versions, file intact, plugin not loaded. A 2.x build run (sandbox on) made its edit; `rm` was blocked.
- Test-harness pitfall: 1.x `opencode run` waits for EOF when stdin is an open pipe (it hung for 15 min
  in an ad-hoc script); the wrapper now runs it with `</dev/null`.
- Implemented by a local build run from a spec; reviewed, 328 tests pass, and mutation checks confirm the
  tests catch a missing project-config flag or a missing deny-all.

## S22 — OpenCode 1.19.5 vs 2.3.0 head-to-head; v2 provider fix (Nov 18)
- Bug found: on 2.x the wrapper's provider config (v1 shape: `npm`, `options.baseURL`) was ignored, and
  2.x silently used LM Studio auto-discovered on `localhost:1234` (LM Link here), so `--ssh` and
  `LMSTUDIO_BASE_URL` had no effect. Shown with a dead-port baseURL that still answered. 2.x wants
  `package: "aisdk:@ai-sdk/openai-compatible"` and `settings.baseURL`; with that, a dead port fails
  (`provider.transport` ECONNREFUSED) and the tunnel works.
- Comparison, same model (Qwen3.8 Flash Next IQ3_XXS, MTP), both over the SSH route, one run at a time:

  | Task | 1.19.5 | 2.3.0 |
  |---|---|---|
  | First request prompt | ~6.0k tokens | ~2.0k tokens |
  | Explore (exit codes of the wrapper), total input | 25.2k | 17.1k |
  | Explore wall time (cold, warm) | 65 s, 55 s (round 1: 77, 65) | 65 s, 87 s |
  | Build (`divide()` + tests), total input | 37.3k | 17.6k |
  | Build wall time | 37 s (round 1: 36) | 28 s (round 1, via LM Link: 44) |
  | Forced tunnel kill mid-run | auto-resumed, finished | auto-resumed, finished |

  Answers were equally correct (all exit codes with line numbers; every build's unit tests pass with the
  same code). No tool errors or blocks on either. 2.x writes somewhat more output/reasoning on explore,
  which eats its prompt-size advantage in wall time. `--fork` on 2.x works (answered from the forked
  context in 12 s).
- Verdict: equal quality and roughly equal speed; 2.x uses about a third of the base prompt and 30–50%
  less input per task, which leaves more context for long tasks.

## S7 — Claude Code sandbox: skipped (optional)

## Notes
- macOS has no GNU `timeout`. Use `perl -e 'alarm shift; exec @ARGV' <secs> cmd`.

## S23 — Security review, round 1 (Nov 19)
Findings from reviewing the wrapper as a target for a hostile model, repo or LM Studio. Each has a test in `tests/run_tests.sh`.
- Arithmetic injection: `CTX` (from LM Studio's JSON) and the numeric env settings went into `[[ -ge ]]`/`$(( ))`, where bash
  evaluates `a[$(cmd)]`. Fix: digits-only validation; a bad context exits 4, bad settings exit 2.
- Post-run git trusted the worktree's `.git` file, which the agent can rewrite (fsmonitor config, the user's own repo, a
  worktree HEAD pointing at the user's branch). Fix: the git dir, `.git` line and `commondir` are recorded in `worktree.json`;
  before any git call (finalize, resume, cleanup) they and HEAD/`config.worktree` are verified, else exit 6 with the worktree kept;
  git runs with `--git-dir/--work-tree`, hooks/fsmonitor/pager/ext-diff/sshCommand off and `GIT_CONFIG_NOSYSTEM=1`.
  The sandbox also denies writes to `$WT/.git`, `HEAD`, `commondir`, `config.worktree`, and the build profile denies edits to `.git`.
- Symlinks: carrying uncommitted work over followed symlinks (`~/.aws/credentials` became a real file). Fix: `cp -P`, the target is
  removed first; `--copy` rejects absolute and `..` paths and sources resolving outside the repo, and copies with `cp -RP`.
- Report injection: model text could forge `!! DELETED:` lines or section headers and carry escape sequences. Fix: control
  characters stripped, sizes capped, tool/error lines prefixed `  | `, final message in nonce markers, `status:` line after it.
- Private files: `umask 077`; `$OCLS_HOME`, runs and worktrees are 700.
- ssh tunnel: any listener on the local port was trusted. Fix: reuse only a recorded (host, pid) ssh; otherwise exit 4;
  `--` before the host.
- Warn on plain `http://` to a non-loopback `LMSTUDIO_BASE_URL`; `--allow-cmd` rejects empty, `*` and multi-line rules.
- CI: the workflow token is read-only (`permissions: contents: read`).

## S24 — Security review, round 2 (Nov 19): allowlists, guard plugin, read confinement, network pinning
Starting point: OpenCode matches shell permission patterns against the raw command text, so quoting/escaping defeats any
deny pattern (`find . "-exec" ...`, `-d\elete`, `rg --p're=sh'`, `git log "--output=f"`, `git commit --am`). Allowlisted tools
with program-running or file-writing options are the problem, so the allowlists shrank instead of the deny list growing.
Verified live (this machine, macOS, real `opencode` through the wrapper, fake OpenAI-compatible model server that scripts the
tool calls, `tests/spikes/s24_guard_plugin.sh`):
- A guard plugin that throws from the tool-before hook DOES block the call, on 1.19.5 (`plugin: [file URL]`, `tool.execute.before`,
  tool `bash`) and on 2.3.0 (`plugins: [directory]`, `Plugin`-style default export with `setup(ctx)` and `ctx.tool.hook("execute.before")`,
  tool `shell`; a plain object works, `@opencode/plugin` need not be importable). The model sees the error, the call is listed
  under "blocked tool calls", the plain `git log --oneline` after it still runs. Control runs with the plugin made a no-op show
  `find . "-exec" touch x {} +` and `git log "--output=f"` both executing through the allowlist: that is what the plugin prevents.
  The plugin loads even with `OPENCODE_DISABLE_PROJECT_CONFIG=1`. 1.x calls every named export as a plugin, so `index.js` has a single
  default export serving both APIs (1.x `server()`, 2.x `id` + `setup()`) and the rules live in `rules.js`.
- Sandbox read confinement: `(deny file-read-data (subpath HOME))` followed by allows works for real opencode 1.19.5 and 2.3.0 (full
  runs reach the fake provider and run git). A rule on a more specific operation beats a later wildcard: the secret-file denies had to be
  `file-read-data`, not `file-read*`, to stay effective after the `file-read-data` allows (a test caught it).
- Network: `(deny network*)` + `(allow network-outbound (remote ip "localhost:PORT"))` is enough for 1.x. 2.x starts a standalone server and
  fails ("Standalone server exited before reporting readiness") unless loopback bind/inbound/outbound is also allowed
  (`localhost:*`), so 2.x reports `net=loopback`: nothing leaves the machine, but other local ports are reachable.
- git env (from the research spike, gitexp.out): `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat
  GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1 GIT_ATTR_NOSYSTEM=1` plus `GIT_CONFIG_COUNT` overrides for core.fsmonitor, core.pager,
  diff.external, gpg.program, core.hooksPath, commit.gpgsign, core.sshCommand neutralise fsmonitor, external diff, pager, hooks and
  signing for status/diff/log -p/show/blame. A deterministic test plants them in a repo and checks no marker appears; the global
  config being off needed a fixed commit identity (`GIT_AUTHOR_*`/`GIT_COMMITTER_*`).
- Tests: 482 -> 583 in tests/run_tests.sh (profile lists, plugin config on 1.x/2.x, guard rules table via node, live spike when a real
  opencode exists, git env, read confinement incl. `--allow-read`, opencode binary under $HOME, plugin dir read-only, network pinning
  with two local ports, SSH-route pinning, no-sandbox refusal for build, nested-sandbox behaviour).
Inferred / not verified: that the same hook works on opencode versions other than 1.19.5 and 2.3.0; that per-driver textconv/filter
settings planted in an in-place repo's `.git/config` stay a residual risk (the guard rejects `--textconv`, the sandbox stops planting in
build worktrees); `--allow-read` toolchain layouts other than a plain directory (a binary that needs files outside its dir fails with
"Operation not permitted" in the tool output, fix: add the dir). Decisions: `~` and `^` were added to the plain-character set so
`HEAD~1`/`HEAD^` work (a `~` the shell would expand is still rejected); `common.json` keeps the deny list (unquoted forms,
`--allow-cmd` users) but drops entries for tools no longer allowed (find, sort, tree, rg, date, file); `*:.env`, `*:.env *` and `*:.env.*` deny patterns were
added after a test showed `git show HEAD:.env` slipped past the path patterns. If an explore agent's answers depend on `ls`/`wc`/`cat`,
that is the cost; they were not added back.

Live check (2026-11-19, 1.19.5, SSH route): explore, review and build all passed; the review agent's chained
`git log -1 && echo "---" && git show` was blocked by the guard and it answered anyway. The first build run could not import
pytest (user site-packages in `~/Library/Python` were outside the read allowlist), so common toolchain folders under `$HOME`
are now readable by default when they exist (see README); after that pytest ran inside the sandbox (2 passed).

## S25 — Linux sandbox with bubblewrap (Nov 23)

Added a bwrap layer to `run-opencode.sh` that mirrors the macOS sandbox-exec one (SB_KIND=bwrap on Linux). Mounts, in order: `--ro-bind / /`,
`--dev /dev`, `--proc /proc`, `--tmpfs $HOME` (read confinement), `--ro-bind` of each read-allowed path under `$HOME`, `--bind` of each writable
dir (worktree, its git dir, objects/refs, OC_HOME, temp), `--ro-bind` again of the `.git` pointers and the guard dir, then secret files in the
run's folder masked (`--ro-bind /dev/null` for files, `--tmpfs` for dirs; found with `find -maxdepth 8`, `.git` pruned, same name patterns as
the macOS regexes, `.env.example` left readable). `--die-with-parent --unshare-pid` end everything the agent started. Detection runs
`bwrap --ro-bind / / --dev /dev --proc /proc true`; when it fails the state is `unusable` and the message names the Ubuntu AppArmor fix
(`kernel.apparmor_restrict_unprivileged_userns=0`).
Differences, by design: network stays shared (no pinning; header says `net=open` even with `--no-web`); secrets created after the start are not
masked; symlinks to secrets are not followed; system paths outside `$HOME` such as `/root` stay readable.
Verified on macOS (no regression): `OCLS_REQUIRE_SANDBOX=1 bash tests/run_tests.sh` 591 passed, 0 failed (590 before; +1 Linux-only section that
is a no-op on macOS). The bwrap argument list was also checked on the Mac with a fake `uname`/`bwrap` (mount order, secret masks, `.env.example`
not masked, no duplicate masks when the folder is the workdir); bash 3.2 `set -u` on an empty `SB_RO` was a bug found this way and fixed.
Verified in a Lima VM (Ubuntu 26.04 arm64, bubblewrap from apt, OpenCode 1.19.5 from `opencode-ai` and 2.3.0 from `@opencode/cli` in a separate prefix):
`OCLS_REQUIRE_SANDBOX=1 bash tests/run_tests.sh` 578 passed, 0 failed, including the sandbox sections that run on Linux (writes confined to the
worktree, `.git` pointer/HEAD/commondir read-only, guard dir read-only, reads under `$HOME` confined with canaries outside, `.ENV`, a `.env/` folder
and `*.key` masked, `.env.example` readable, a background job left by the agent dies with the run) plus the Linux header check `net=open`.
`tests/spikes/s24_guard_plugin.sh` PASS with 1.19.5 and with 2.3.0 (binary path as argument) under bwrap; its header assertion is `net=open` on Linux.
Fixes found by the real run: (1) the 2.x binary reached through a symlink chain under `$HOME` (npm `.bin/opencode`) was a dangling link inside the
sandbox, so PATH fell through to another opencode; every hop's directory is now readable. (2) the ssh "port taken over" test kills a host process, which
`--unshare-pid` hides, so that one run uses `--no-sandbox` on Linux.
AppArmor: Ubuntu 26.04 has `kernel.apparmor_restrict_unprivileged_userns=1`, yet the packaged `/usr/bin/bwrap` works out of the box (Ubuntu ships the
`bwrap-userns-restrict` profile). A copy of the same binary outside that profile fails with `bwrap: setting up uid map: Permission denied`, and
`sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` fixes it, which is what the wrapper's error message recommends. So the sysctl was not
needed for the tests; it matters for a bwrap installed elsewhere (nix, snap, a copied binary) and for runners without the profile.
Not verified: other distributions, WSL2, rootless containers (bwrap cannot nest), TTY-interactive use.

## S26 — OpenCode 1.19.6 and 2.4.1 compatibility (Nov 23)

Newest releases: `opencode-ai@1.19.6` (1.x) and `@opencode/cli@2.4.1` (2.x), installed into scratch prefixes. Neither package ships a changelog
(only the launcher and a postinstall script), so behaviour was checked directly. No wrapper, plugin or test change was needed.
- `tests/spikes/s24_guard_plugin.sh` PASS on both, on macOS (sandbox-exec; `net=pinned` on 1.19.6, `net=loopback` on 2.4.1) and in the Lima VM under
  bubblewrap (`net=open`): quoted `find "-exec"` and `git log "--output=..."` blocked by the guard, plain `git log` runs, the no-op-plugin control
  run shows both would have run.
- By hand through the wrapper with a fake model server (`tests/fake_openai.py`), review profile with `--allow-cmd git`:
  - provider baseURL honoured on both: the fake server received every request (with the v2 `providers`/`package`/`settings.baseURL` shape on 2.4.1).
    A config with a dead port gets no answer on either (the run hangs on retries until killed, no text events).
  - a hostile folder (`opencode.json` allowing everything, `.env`, `.opencode/plugin[s]/`), `--no-sandbox`: nothing was written, deleted or read.
    On 2.4.1 `OPENCODE_DISABLE_PROJECT_CONFIG=1` still stops `.opencode/plugins` (without the flag the plugin ran).
  - 2.4.1 permissions array: `rm a.txt` -> `Permission denied: shell`, `git log --oneline` allowed, `write`/`edit` not offered in review.
    1.19.6: `rm` -> "rule which prevents you from using this specific tool call", write/edit not offered.
  - JSON events unchanged: `sessionID` on every event, types `step_start`/`tool_use`/`text`/`step_finish`, `part.tool`, `part.state.status`
    (`error` carries `part.state.error`), `part.state.input.{command,filePath}` on 1.x, `path` on 2.x; the final text part is the last message.
- Full suite: `OCLS_REQUIRE_SANDBOX=1 bash tests/run_tests.sh` 591 passed, 0 failed on the Mac (Homebrew 1.19.5 on PATH); in the VM with each new version first on PATH 578 passed, 0 failed (both). shellcheck -S warning clean.
- Finding, not a regression (identical on 1.19.5 and 1.19.6): on 1.x `OPENCODE_DISABLE_PROJECT_CONFIG=1` stops a folder plugin's `server()` hook but
  still calls the `setup()` method of a default-exported object in `.opencode/plugin/*.js`. A hostile repo can therefore run code on 1.x even with the
  flag (S21 only tried a `server()`-style plugin). With the OS sandbox on, that code is confined like the agent; with `--no-sandbox` it is not. 2.x
  (2.3.0 and 2.4.1) does not load it. Not fixed here; the sandbox is the defence, and `--no-sandbox` on untrusted folders stays unsafe on 1.x.
Not verified: other OpenCode versions, real models (fake server only), tool results from `write`/`edit` in the build profile on the new versions
(the build profile's live path is covered by the suite's stub only).
