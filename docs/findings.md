# Spike findings

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
  (`lms ps --json` → `deviceIdentifier 161bb5…`, which matches the remote device in `lms ls`).
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
First real test from a fresh Claude Code session, with the laptop at UTC−3 and the Mac Studio at CET.
- Two explore runs died with `LM Link connection entered error state peer_keepalive_timeout`, 16–26 s
  after a step that read files. A third attempt exited 4 ("no model loaded") while the link was down.
- **Not caused by the wrapper, and not explained by the version difference:** the Mac Studio's logs show
  drops on every day from Nov 2 (61, 26, 85, 42, 1 distinct minutes on Nov 2–6), also when no subagent was running.
- Network between the machines at the time (ping over Meshnet, a different tunnel than LM Link but
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

## S7 — Claude Code sandbox: skipped (optional)

## Notes
- macOS has no GNU `timeout`. Use `perl -e 'alarm shift; exec @ARGV' <secs> cmd`.
