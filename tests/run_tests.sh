#!/usr/bin/env bash
# Deterministic tests for scripts/run-opencode.sh. No LM Studio or real opencode needed:
# a stub opencode/lms sit first on PATH and LM Studio's API is served from file:// fixtures.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$ROOT/skills/opencode-local-subagent/scripts/run-opencode.sh"
PASS=0; FAIL=0; FAILED=()

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$CUR: $*"); echo "  FAIL: $*"; }
assert_eq()       { [[ "$1" == "$2" ]] && ok || bad "$3 (expected '$2', got '$1')"; }
assert_contains() { [[ "$1" == *"$2"* ]] && ok || bad "$3 (missing '$2')"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] && ok || bad "$3 (unexpected '$2')"; }
assert_file()     { [[ -e "$1" ]] && ok || bad "$2 (missing file $1)"; }
assert_no_file()  { [[ ! -e "$1" ]] && ok || bad "$2 (file should not exist: $1)"; }

models_json() { # args: id:state:type:ctx:caps ...
  local items=() id st ty ctx caps
  for spec in "$@"; do
    IFS=: read -r id st ty ctx caps <<<"$spec"
    items+=("$(jq -nc --arg id "$id" --arg st "$st" --arg ty "$ty" --argjson ctx "$ctx" --arg caps "$caps" \
      '{id:$id,state:$st,type:$ty,loaded_context_length:$ctx,max_context_length:262144,capabilities:($caps|split(",")|map(select(length>0)))}')")
  done
  printf '%s\n' "${items[@]}" | jq -sc '{object:"list",data:.}'
}

setup() { # $1 = test name
  CUR="$1"; echo "- $1"
  T=$(mktemp -d)
  mkdir -p "$T/fix/api/v0" "$T/home"
  export LMSTUDIO_BASE_URL="file://$T/fix"
  export OCLS_HOME="$T/home"
  export STUB_LOG="$T/calls.jsonl"
  export PATH="$ROOT/tests/stub:$ORIG_PATH"
  export OCLS_DETECT_DELAY=0
  export OCLS_STALL_TIMEOUT=0   # watchdog off unless a test turns it on (it polls every second)
  unset OPENCODE_LOCAL_MODEL OPENCODE_ROUTER_RUNS OCLS_DETECT_TRIES STUB_TEXT STUB_ACTIONS STUB_BLOCKED STUB_ERROR STUB_EXIT STUB_SLEEP STUB_EVENTS STUB_LMS_PS_JSON STUB_LMS_PS_TEXT
  unset STUB_ERROR_TIMES STUB_SILENT_AFTER OCLS_SSH_HOST OCLS_SSH_LOCAL_PORT OCLS_SSH_REMOTE_PORT STUB_SSH_SERVE STUB_STDERR STUB_SSH_EXIT
  export OCLS_AUTO_RESUME=0     # auto-resume off unless a test turns it on
  export STUB_COUNTER="$T/count" STUB_SSH_LOG="$T/ssh.log" STUB_SSH_PID="$T/ssh.pid" OCLS_SSH_WAIT=3
  models_json "m-one:loaded:llm:65536:tool_use" >"$T/fix/api/v0/models"
}
run() { OUT=$("$WRAPPER" "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
call() { jq -c "$1" <(tail -1 "$STUB_LOG"); }
mkrepo() { # $1 dir
  mkdir -p "$1"; git -C "$1" init -q
  git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  echo base >"$1/tracked.txt"; echo keep >"$1/doomed.txt"
  git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t commit -q -m files
}
ORIG_PATH="$PATH"

# ---------------------------------------------------------------- model detection
setup "detects the single loaded model and injects provider config"
run -C "$T" "hello"
assert_eq "$RC" "0" "exit code"
assert_eq "$(call '.args | index("-m") as $i | .[$i+1]')" '"lmstudio/m-one"' "model arg"
cfg=$(call '.config | fromjson')
assert_eq "$(jq -r '.provider.lmstudio.npm' <<<"$cfg")" "@ai-sdk/openai-compatible" "provider npm"
assert_eq "$(jq -r '.provider.lmstudio.options.baseURL' <<<"$cfg")" "file://$T/fix/v1" "baseURL"
assert_eq "$(jq -r '.provider.lmstudio.models["m-one"].limit.context' <<<"$cfg")" "65536" "context limit"
assert_contains "$OUT" "model=m-one" "report shows model"

setup "report shows the serving device from 'lms ps' (LM Link)"
printf '\nIDENTIFIER    MODEL    STATUS    SIZE        CONTEXT    PARALLEL    DEVICE                    TTL\nm-one         m-one    IDLE      84.65 GB    65536      2           gpu-box.local    \n\n' >"$T/ps.txt"
export STUB_LMS_PS_TEXT="$T/ps.txt"
run -C "$T" "hello"
assert_contains "$OUT" "device=gpu-box.local" "device shown"

setup "ignores unloaded models and embeddings; picks most recently used of several"
models_json "emb:loaded:embeddings:2048:" "old:loaded:llm:65536:tool_use" "new:loaded:vlm:65536:tool_use" "dl:not-loaded:llm:65536:" >"$T/fix/api/v0/models"
echo '[{"identifier":"old","lastUsedTime":100},{"identifier":"new","lastUsedTime":200}]' >"$T/ps.json"
export STUB_LMS_PS_JSON="$T/ps.json"
run -C "$T" "hello"
assert_eq "$(call '.args | index("-m") as $i | .[$i+1]')" '"lmstudio/new"' "most recent model chosen"
assert_contains "$ERR$OUT" "2 models loaded" "mentions multiple models"

setup "no loaded model -> exit 4"
models_json "dl:not-loaded:llm:65536:" >"$T/fix/api/v0/models"
run -C "$T" "hello"
assert_eq "$RC" "4" "exit code"
assert_contains "$ERR" "no model loaded" "message"
assert_contains "$ERR" "LM Link" "mentions the link, which can also hide a loaded model"

setup "a brief link drop during detection is retried"
models_json "dl:not-loaded:llm:65536:" >"$T/fix/api/v0/models"
export OCLS_DETECT_DELAY=1 OCLS_DETECT_TRIES=5
( sleep 1; models_json "m-back:loaded:llm:65536:tool_use" >"$T/fix/api/v0/models.new"; mv "$T/fix/api/v0/models.new" "$T/fix/api/v0/models" ) &
FIXPID=$!
run -C "$T" "hello"
wait "$FIXPID"
assert_eq "$RC" "0" "recovers once the model is visible again"
assert_contains "$OUT" "model=m-back" "uses the model that came back"
assert_contains "$ERR" "waiting up to" "says it is waiting"

setup "LM Studio unreachable -> exit 4 with LM Link hint, without the long wait"
export LMSTUDIO_BASE_URL="file://$T/nowhere" OCLS_DETECT_DELAY=1 OCLS_DETECT_TRIES=18
t0=$SECONDS
run -C "$T" "hello"
assert_eq "$RC" "4" "exit code"
assert_contains "$ERR" "LM Link" "hint"
[[ $((SECONDS - t0)) -lt 5 ]] && ok || bad "gave up after $((SECONDS - t0))s; expected after the 2nd try"

setup "context too small -> exit 4; smallish -> warning"
models_json "tiny:loaded:llm:10752:tool_use" >"$T/fix/api/v0/models"
run -C "$T" "hello"
assert_eq "$RC" "4" "exit code for tiny context"
assert_contains "$ERR" "context" "message"
models_json "mid:loaded:llm:24000:" >"$T/fix/api/v0/models"
run -C "$T" "hello"
assert_eq "$RC" "0" "smallish context still runs"
assert_contains "$ERR" "warning: context" "context warning"
assert_contains "$ERR" "warning: model does not advertise tool_use" "tool_use warning"

setup "-m flag and OPENCODE_LOCAL_MODEL override detection"
models_json "a:loaded:llm:65536:tool_use" "b:loaded:llm:65536:tool_use" >"$T/fix/api/v0/models"
run -C "$T" -m b "hello"
assert_eq "$(call '.args | index("-m") as $i | .[$i+1]')" '"lmstudio/b"' "-m wins"
OPENCODE_LOCAL_MODEL=lmstudio/b run -C "$T" "hello"
assert_eq "$(call '.args | index("-m") as $i | .[$i+1]')" '"lmstudio/b"' "env wins (prefix stripped)"
run -C "$T" -m zzz "hello"
assert_eq "$RC" "4" "unknown model -> exit 4"

# ---------------------------------------------------------------- permissions / profiles
setup "explore profile: read-only permissions, runs in place"
run -C "$T" "hello"
perm=$(call '.permission | fromjson')
assert_eq "$(jq -r '.edit' <<<"$perm")" "deny" "edit denied"
assert_eq "$(jq -r '.skill' <<<"$perm")" "deny" "skills hidden"
assert_eq "$(jq -r '.task' <<<"$perm")" "deny" "no nested agents"
assert_eq "$(jq -r '.webfetch' <<<"$perm")" "allow" "web allowed"
assert_not_contains "$perm" '"ask"' "no ask values"
assert_eq "$(jq -r '.bash | keys_unsorted[0]' <<<"$perm")" "*" "catch-all first"
assert_eq "$(jq -r '.bash["*"]' <<<"$perm")" "deny" "bash deny by default"
assert_eq "$(jq -r '.bash["ls *"]' <<<"$perm")" "allow" "ls allowed"
assert_eq "$(jq -r '.bash["rm *"]' <<<"$perm")" "deny" "rm denied"
order=$(jq -r '.bash | keys_unsorted | (index("find *") < index("find * -delete*"))' <<<"$perm")
assert_eq "$order" "true" "deny after allow (last match wins)"
assert_eq "$(call '.args | index("--dir") as $i | .[$i+1]')" "\"$T\"" "runs in place"
assert_contains "$(call '.args')" '"--auto"' "auto on"

setup "redirects and write-capable flags are denied after the allowlist (S11)"
run -C "$T" "hello"
perm=$(call '.permission | fromjson')
for p in '*>*' '*tee *' 'find * -fprint*' 'sort *-o*' 'rg *--pre*' 'git * --output*'; do
  assert_eq "$(jq -r --arg p "$p" '.bash[$p]' <<<"$perm")" "deny" "deny $p"
done
assert_eq "$(jq -r '.bash | keys_unsorted | (index("echo *") < index("*>*"))' <<<"$perm")" "true" "redirect deny wins over echo allow"
assert_eq "$(jq -r '.bash["uniq *"] // "absent"' <<<"$perm")" "absent" "uniq not allowlisted (writes 2nd arg)"

setup "bash rules decide as OpenCode would (its wildcard matcher, last match wins)"
run -C "$T" "hello"
perm=$(call '.permission | fromjson')
# OpenCode 1.19.5: escape regex chars, * -> .*, ? -> ., a trailing " *" is optional, anchored
decide() {
  jq -r --arg cmd "$1" '
    def wc($p): ($p | gsub("(?<c>[.+^${}()|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) as $r
      | (if ($r | endswith(" .*")) then $r[:-3] + "( .*)?" else $r end) as $r
      | test("^" + $r + "$");
    [.bash | to_entries[] | select(.key as $k | $cmd | wc($k)) | .value] | last // "none"' <<<"$perm"
}
for c in "find -exec rm {} ;" "find -delete" "find -fprint out" "find . -name x -exec cat {} ;" \
         "rm a.txt" "echo hi > out.txt" "git push" "python3 x.py" "sort -o f a"; do
  assert_eq "$(decide "$c")" "deny" "denied: $c"
done
for c in "find . -name x" "ls" "ls -la" "grep -rn foo ." "git status" "cat README.md"; do
  assert_eq "$(decide "$c")" "allow" "allowed: $c"
done

setup "--allow-cmd adds an allow rule before the deny rules"
run -C "$T" --allow-cmd "pytest" "hello"
perm=$(call '.permission | fromjson')
assert_eq "$(jq -r '.bash["pytest *"]' <<<"$perm")" "allow" "pytest allowed"
order=$(jq -r '.bash | keys_unsorted | (index("pytest *") < index("rm *"))' <<<"$perm")
assert_eq "$order" "true" "extra allow before denies"

setup "--no-web denies the web tools; the default allows them"
run -C "$T" "hello"
assert_contains "$OUT" "web=on" "report: web on by default"
mkrepo "$T/repo"
run -C "$T/repo" --profile build --no-web "hello"
perm=$(call '.permission | fromjson')
assert_eq "$(jq -r '.webfetch + "," + .websearch' <<<"$perm")" "deny,deny" "both web tools denied"
assert_eq "$(jq -r '.edit' <<<"$perm")" "allow" "rest of the build profile unchanged"
assert_contains "$OUT" "web=off" "report: web off"

setup "unknown profile -> exit 2"
run -C "$T" --profile nope "hello"
assert_eq "$RC" "2" "exit code"

# ---------------------------------------------------------------- build / worktree
setup "build outside a git repo -> exit 5"
mkdir -p "$T/plain"
run -C "$T/plain" --profile build "hello"
assert_eq "$RC" "5" "exit code"
assert_contains "$ERR" "git" "message"

setup "build: worktree with WIP, isolated edits, deletion flagged, kept for merge"
mkrepo "$T/repo"
echo wip >>"$T/repo/tracked.txt"; echo new >"$T/repo/untracked.txt"
cat >"$T/actions.sh" <<'EOF'
echo agent >>tracked.txt
echo created >created.txt
rm doomed.txt
EOF
export STUB_ACTIONS="$T/actions.sh"
run -C "$T/repo" --profile build -l feat "do it"
assert_eq "$RC" "0" "exit code"
wt=$(call '.args | index("--dir") as $i | .[$i+1]' | jq -r .)
assert_contains "$wt" "$OCLS_HOME/worktrees/" "runs in worktree"
assert_eq "$(cat "$wt/untracked.txt" 2>/dev/null)" "new" "untracked WIP copied"
assert_eq "$(head -2 "$wt/tracked.txt" | tail -1)" "wip" "modified WIP copied"
assert_file "$T/repo/doomed.txt" "main repo untouched by agent delete"
assert_no_file "$T/repo/created.txt" "main repo untouched by agent create"
assert_eq "$(tail -1 "$T/repo/tracked.txt")" "wip" "main repo WIP intact"
assert_contains "$OUT" "DELETED: doomed.txt" "deletion flagged"
assert_contains "$OUT" "A	created.txt" "addition listed"
assert_contains "$OUT" "M	tracked.txt" "modification listed"
assert_not_contains "$OUT" "untracked.txt" "WIP not in agent diff (baseline)"
br=$(git -C "$T/repo" branch --list 'opencode/*' | tr -d ' *')
assert_contains "$br" "opencode/feat-" "branch exists"
rd=$(grep '^RUN_DIR=' <<<"$OUT" | cut -d= -f2)
assert_file "$rd/worktree.json" "worktree metadata"
base=$(jq -r .baseline "$rd/worktree.json")
assert_eq "$(git -C "$wt" diff --name-only "$base"..HEAD | sort | tr '\n' ' ')" "created.txt doomed.txt tracked.txt " "diff vs baseline"

setup "build: staged work (new, modified, deleted, renamed) reaches the worktree too"
mkrepo "$T/repo"
( cd "$T/repo" && echo extra >extra.txt && git add extra.txt \
  && git -c user.name=t -c user.email=t@t commit -qm extra \
  && echo staged-new >staged_new.txt && git add staged_new.txt \
  && echo staged-mod >>tracked.txt && git add tracked.txt \
  && git rm -q doomed.txt \
  && git mv extra.txt renamed.txt \
  && echo both >both.txt && git add both.txt && echo more >>both.txt )
run -C "$T/repo" --profile build --keep -l staged "x"
wt=$(call '.args | index("--dir") as $i | .[$i+1]' | jq -r .)
assert_file "$wt/tracked.txt" "worktree kept for inspection"
assert_eq "$(cat "$wt/staged_new.txt" 2>/dev/null)" "staged-new" "staged new file copied"
assert_eq "$(tail -1 "$wt/tracked.txt")" "staged-mod" "staged modification copied"
assert_no_file "$wt/doomed.txt" "staged deletion applied"
assert_no_file "$wt/extra.txt" "rename: old name gone"
assert_eq "$(cat "$wt/renamed.txt" 2>/dev/null)" "extra" "rename: new name present"
assert_eq "$(tail -1 "$wt/both.txt" 2>/dev/null)" "more" "staged then edited: working copy wins"
assert_contains "$OUT" "no changes" "user's staged work isn't reported as the agent's"

setup "OS sandbox (macOS): writes outside the worktree fail, inside succeed; --no-sandbox turns it off"
if command -v sandbox-exec >/dev/null && sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then
  mkrepo "$T/repo"
  ESC="$HOME/.ocls-sandbox-test-$$"
  printf 'echo in >inside.txt\necho out >%q\n' "$ESC" >"$T/actions.sh"; export STUB_ACTIONS="$T/actions.sh"
  run -C "$T/repo" --profile build -l sbx "x"
  assert_contains "$OUT" "sandbox=on" "sandbox reported on"
  assert_contains "$OUT" "A	inside.txt" "write inside worktree allowed"
  assert_no_file "$ESC" "write to \$HOME blocked by sandbox"
  rm -f "$ESC"
  # the agent can commit on its branch, but not plant hooks/config in the shared .git or touch the
  # user's own OpenCode dirs. The repo lives outside $TMPDIR, which the sandbox allows as a whole.
  R2="$HOME/.ocls-sandbox-repo-$$"; mkrepo "$R2"
  OCF="$HOME/.config/opencode/.ocls-sandbox-test-$$"
  printf 'echo in >inside.txt\ngit add -A && git -c user.name=a -c user.email=a@a commit -qm agent-commit\necho evil >%q\necho x >>%q\necho x >%q\n' \
    "$R2/.git/hooks/planted" "$R2/.git/config" "$OCF" >"$T/actions.sh"
  run -C "$R2" --profile build -l sbx2 "x"
  assert_no_file "$R2/.git/hooks/planted" "no hook planted in the shared .git"
  assert_eq "$(git -C "$R2" config --get core.bare)" "false" ".git/config intact"
  /usr/bin/grep -q '^x$' "$R2/.git/config" && bad ".git/config was appended to" || ok
  assert_no_file "$OCF" "user's ~/.config/opencode not writable"
  br=$(git -C "$R2" for-each-ref --format='%(refname:short)' refs/heads/opencode/)
  assert_contains "$(git -C "$R2" log --format=%s "$br")" "agent-commit" "agent's own commit on its branch works"
  rm -rf "$R2" "$OCF"
  # the sandbox also applies to an automatic resume after a drop
  mkrepo "$T/repo3"
  ESC3="$HOME/.ocls-sandbox-resume-$$"
  printf 'echo in >inside.txt\necho out >%q\n' "$ESC3" >"$T/actions.sh"
  export STUB_ACTIONS="$T/actions.sh" STUB_ERROR="DROPX LM Link peer_keepalive_timeout" STUB_ERROR_TIMES=1 OCLS_AUTO_RESUME=1
  # attempt 1 drops before any write; the resumed attempt writes
  run -C "$T/repo3" --profile build -l sbx3 "x"
  assert_contains "$OUT" "auto_resumed=1" "attempt was resumed"
  assert_contains "$OUT" "A	inside.txt" "resumed attempt: write inside worktree allowed"
  assert_no_file "$ESC3" "resumed attempt: write to \$HOME blocked by sandbox"
  rm -f "$ESC3"
  unset STUB_ERROR STUB_ERROR_TIMES
  export OCLS_AUTO_RESUME=0
  unset STUB_ACTIONS
  run -C "$T" --no-sandbox "x"
  assert_contains "$OUT" "sandbox=off" "--no-sandbox reported"
  assert_contains "$ERR" "OS sandbox disabled" "--no-sandbox warns"
else
  # CI's macOS job sets this, so a runner without a usable sandbox fails instead of skipping
  [[ -z "${OCLS_REQUIRE_SANDBOX:-}" ]] && ok || bad "sandbox tests skipped although OCLS_REQUIRE_SANDBOX is set"
  run -C "$T" "x"
  assert_contains "$OUT" "sandbox=off" "no sandbox-exec -> off"
  assert_contains "$ERR" "relying on" "fallback warning"
fi

setup "--cleanup removes worktree and branch"
mkrepo "$T/repo"
echo 'echo x >new.txt' >"$T/actions.sh"; export STUB_ACTIONS="$T/actions.sh"
run -C "$T/repo" --profile build -l c "do it"
rd=$(grep '^RUN_DIR=' <<<"$OUT" | cut -d= -f2); wt=$(jq -r .worktree "$rd/worktree.json")
run --cleanup "$rd"
assert_eq "$RC" "0" "cleanup exit"
assert_no_file "$wt" "worktree removed"
assert_eq "$(git -C "$T/repo" branch --list 'opencode/*' | wc -l | tr -d ' ')" "0" "branch removed"

setup "build with no changes -> worktree auto-removed"
mkrepo "$T/repo"
run -C "$T/repo" --profile build -l nochange "look only"
assert_contains "$OUT" "no changes" "reported"
assert_eq "$(git -C "$T/repo" worktree list | wc -l | tr -d ' ')" "1" "only main worktree left"
assert_eq "$(git -C "$T/repo" branch --list 'opencode/*' | wc -l | tr -d ' ')" "0" "branch removed"

setup "build in a repo subdirectory runs in the same subdirectory of the worktree"
mkrepo "$T/repo"; mkdir -p "$T/repo/sub"; echo s >"$T/repo/sub/s.txt"
git -C "$T/repo" add -A; git -C "$T/repo" -c user.name=t -c user.email=t@t commit -q -m sub
run -C "$T/repo/sub" --profile build -l sub "x"
dir=$(call '.args | index("--dir") as $i | .[$i+1]' | jq -r .)
assert_contains "$dir" "/sub" "subdir preserved"

# ---------------------------------------------------------------- report / output
setup "final message = text after the last tool call; empty -> exit 3"
mkrepo "$T/repo"; echo 'echo y >y.txt' >"$T/actions.sh"; export STUB_ACTIONS="$T/actions.sh"
export STUB_TEXT="All done."
run -C "$T/repo" --profile build "x"
fm=$(sed -n '/^--- final message ---$/,$p' <<<"$OUT")
assert_contains "$fm" "All done." "final text"
assert_not_contains "$fm" "Let me look around." "intermediate narration excluded"
export STUB_TEXT=""; unset STUB_ACTIONS
run -C "$T" "x"
assert_eq "$RC" "3" "empty answer exit code"
assert_contains "$ERR$OUT" "thinking" "empty-answer hint"

setup "an error event is reported, exits 6, and isn't blamed on a thinking model"
export STUB_ERROR="LM Link connection entered error state peer_keepalive_timeout"
run -C "$T" "x"
assert_eq "$RC" "6" "exit code"
assert_contains "$OUT" "--- run error ---" "error section"
assert_contains "$OUT" "peer_keepalive_timeout" "real error text, unwrapped"
assert_not_contains "$OUT" '{"message"' "inner JSON unwrapped"
assert_contains "$ERR" "--resume" "resume hint"
assert_contains "$ERR" "lms link status" "link hint"
assert_not_contains "$ERR$OUT" "thinking" "not blamed on a thinking model"

setup "a run error after partial build work still reports the changes"
mkrepo "$T/repo"; echo 'echo y >partial.txt' >"$T/actions.sh"; export STUB_ACTIONS="$T/actions.sh"
export STUB_ERROR="fetch failed"
run -C "$T/repo" --profile build "x"
assert_eq "$RC" "6" "exit code"
assert_contains "$OUT" "A	partial.txt" "partial work listed"
assert_contains "$OUT" "fetch failed" "error shown"
assert_not_contains "$ERR" "lms link status" "no link hint for other errors"

setup "blocked tool calls are reported"
export STUB_BLOCKED="rm -rf build"
run -C "$T" "x"
assert_contains "$OUT" "--- blocked tool calls ---" "section"
assert_contains "$OUT" "bash: rm -rf build" "blocked command listed"

setup "opencode failure exit code is passed through"
export STUB_EXIT=7
run -C "$T" "x"
assert_eq "$RC" "7" "exit code"

setup "--resume passes -s; stdin prompt with -"
run -C "$T" "first"
sid=$(sed -n 's/^session_id=//p' <<<"$OUT")
run -C "$T" --resume "$sid" "follow up"
assert_eq "$(call '.args | index("-s") as $i | .[$i+1]')" "\"$sid\"" "-s passed"
OUT=$(printf 'line one\nline two\n' | "$WRAPPER" -C "$T" - 2>/dev/null)
assert_contains "$(call '.args[-1]')" 'line two' "stdin prompt"
assert_eq "$(call '.args[-2]')" '"--"' "-- before the prompt"
OUT=$(printf -- '- starts with a dash\n' | "$WRAPPER" -C "$T" - 2>/dev/null)
assert_contains "$(call '.args[-1]')" '- starts with a dash' "dash prompt passed as the message"

setup "--fork, -v and -f are passed through to opencode"
echo note >"$T/note.txt"
run -C "$T" "first"
sid=$(sed -n 's/^session_id=//p' <<<"$OUT")
run -C "$T" --resume "$sid" --fork -v high -f "$T/note.txt" "branch off"
args=$(call '.args')
assert_eq "$(jq -r 'index("--fork") != null' <<<"$args")" "true" "--fork passed"
assert_eq "$(jq -r 'index("--variant") as $i | .[$i+1]' <<<"$args")" "high" "-v -> --variant"
assert_eq "$(jq -r 'index("-f") as $i | .[$i+1]' <<<"$args")" "$T/note.txt" "-f file passed"
assert_eq "$(jq -r '(index("-f") < index("--"))' <<<"$args")" "true" "-f before -- (not part of the prompt)"

setup "report: permission blocks and other tool errors are listed apart"
cat >"$T/ev.jsonl" <<'EOF'
{"type":"tool_use","part":{"tool":"bash","state":{"status":"error","input":{"command":"rm x"},"error":"The user has specified a rule which prevents you from using this specific tool call."}}}
{"type":"tool_use","part":{"tool":"read","state":{"status":"error","input":{"filePath":"/nope.txt"},"error":"File not found: /nope.txt"}}}
EOF
export STUB_EVENTS="$T/ev.jsonl"
run -C "$T" "x"
blk=$(sed -n '/^--- blocked tool calls ---$/,/^---/p' <<<"$OUT")
assert_contains "$blk" "bash: rm x" "denial listed as blocked"
assert_not_contains "$blk" "nope.txt" "file-not-found not listed as blocked"
assert_contains "$OUT" "--- tool calls that failed (not blocked) ---" "failed section"
assert_contains "$OUT" "read: /nope.txt -> File not found" "failure listed with its error"

setup "--help prints the whole header, including exit codes and settings"
run --help
assert_contains "$OUT" "OCLS_STALL_TIMEOUT" "settings shown"
assert_contains "$OUT" "Exit: 0 ok" "exit codes shown"
assert_contains "$OUT" "Adapted from luckeyfaraday" "up to the end of the header"
assert_not_contains "$OUT" "set -euo" "no code"

setup "OpenCode runs with its own config/data/cache/state dirs, not the user's"
run -C "$T" "hello"
assert_eq "$(call '.xdg_config' | jq -r .)" "$OCLS_HOME/opencode/config" "XDG_CONFIG_HOME"

setup "cleanup never rm -rf's a path outside our worktrees dir"
mkdir -p "$T/rd" "$T/victim"; echo keep >"$T/victim/f"
jq -n --arg r "$T/nowhere" --arg w "$T/victim" '{repo:$r, worktree:$w, branch:"x", baseline:"y"}' >"$T/rd/worktree.json"
run --cleanup "$T/rd"
assert_file "$T/victim/f" "directory outside \$OCLS_HOME/worktrees left alone"

setup "explore --resume runs in the session's own directory"
mkdir -p "$T/a" "$T/b"
run -C "$T/a" "first"
sid=$(sed -n 's/^session_id=//p' <<<"$OUT")
run -C "$T/b" --resume "$sid" "follow up"
assert_eq "$RC" "0" "exit code"
assert_eq "$(call '.args | index("--dir") as $i | .[$i+1]' | jq -r .)" "$T/a" "original directory used"
assert_contains "$ERR" "session's own directory" "says so"

setup "build: a failed run keeps its worktree; --resume continues there with the edits so far"
mkrepo "$T/repo"
echo 'echo one >first.txt' >"$T/actions.sh"; export STUB_ACTIONS="$T/actions.sh"
export STUB_ERROR="LM Link connection entered error state peer_keepalive_timeout"
run -C "$T/repo" --profile build -l drop "x"
assert_eq "$RC" "6" "first run stops on the drop"
sid=$(sed -n 's/^session_id=//p' <<<"$OUT")
rd=$(grep '^RUN_DIR=' <<<"$OUT" | cut -d= -f2); wt=$(jq -r .worktree "$rd/worktree.json")
assert_file "$wt/first.txt" "partial edit kept"
unset STUB_ERROR
echo 'echo two >second.txt' >"$T/actions.sh"
run -C "$T/repo" --profile build -l drop-resume --resume "$sid" "continue"
assert_eq "$RC" "0" "resume exit code"
assert_eq "$(call '.args | index("--dir") as $i | .[$i+1]' | jq -r .)" "$wt" "same worktree"
assert_contains "$OUT" "A	first.txt" "edit from before the drop in the diff"
assert_contains "$OUT" "A	second.txt" "edit after resuming in the diff"
assert_eq "$(git -C "$T/repo" branch --list 'opencode/*' | wc -l | tr -d ' ')" "1" "no second worktree branch"

setup "build: no changes but an error or empty answer -> worktree kept; resume after removal -> exit 2"
mkrepo "$T/repo"
export STUB_ERROR="fetch failed"
run -C "$T/repo" --profile build -l err "x"
assert_contains "$OUT" "worktree kept so the session can be resumed" "kept after error"
rd=$(grep '^RUN_DIR=' <<<"$OUT" | cut -d= -f2); sid=$(sed -n 's/^session_id=//p' <<<"$OUT")
unset STUB_ERROR; export STUB_TEXT=""
run -C "$T/repo" --profile build -l empty "x"
assert_contains "$OUT" "worktree kept so the session can be resumed" "kept after empty answer"
assert_eq "$(git -C "$T/repo" worktree list | wc -l | tr -d ' ')" "3" "both worktrees still there"
run --cleanup "$rd"
unset STUB_TEXT
run -C "$T/repo" --profile build --resume "$sid" "continue"
assert_eq "$RC" "2" "exit code"
assert_contains "$ERR" "has been removed" "message"

setup "build --resume with an unknown session -> exit 2"
mkrepo "$T/repo"
run -C "$T/repo" --profile build --resume ses_unknown "continue"
assert_eq "$RC" "2" "exit code"
assert_contains "$ERR" "no run with session ses_unknown" "message"
run -C "$T/repo" --resume ses_unknown "continue"
assert_eq "$RC" "2" "explore: unknown session rejected too"
[[ ! -s "$STUB_LOG" ]] && ok || bad "opencode was started for an unknown session"
run -C "$T" "first"
sid=$(sed -n 's/^session_id=//p' <<<"$OUT")
mkrepo "$T/repo2"
run -C "$T/repo2" --profile build --resume "$sid" "continue"
assert_eq "$RC" "2" "read-only session can't be resumed as build"
assert_contains "$ERR" "read-only run" "message"

setup "a run with no output is stopped after OCLS_STALL_TIMEOUT -> exit 6"
export STUB_SLEEP=4747 OCLS_STALL_TIMEOUT=2
t0=$SECONDS
run -C "$T" "x"
assert_eq "$RC" "6" "exit code"
assert_contains "$OUT" "stall timeout" "reason shown"
[[ $((SECONDS - t0)) -lt 15 ]] && ok || bad "stall stop took $((SECONDS - t0))s"
sleep 1
if /usr/bin/pgrep -f 'sleep 4747' >/dev/null; then bad "grandchild still running after the stall stop"; /usr/bin/pkill -f 'sleep 4747'; else ok; fi

# ---------------------------------------------------------------- auto-resume after a connection drop
ncalls() { wc -l <"$STUB_LOG" | tr -d ' '; }
DROP="LM Link connection entered error state peer_keepalive_timeout"

setup "auto-resume: drop once, then the same session is continued and finishes"
unset OCLS_AUTO_RESUME   # the default (2)
export STUB_ERROR="$DROP" STUB_ERROR_TIMES=1
run -C "$T" "x"
assert_eq "$RC" "0" "exit code"
assert_contains "$OUT" "auto_resumed=1" "report line"
assert_eq "$(ncalls)" "2" "opencode called twice"
sid=$(sed -n 's/^session_id=//p' <<<"$OUT")
assert_eq "$(call '.args | index("-s") as $i | .[$i+1]' | jq -r .)" "$sid" "second call continues the session"
assert_contains "$(call '.args | last')" "The connection dropped while you were working. Continue the task from where you stopped and give the full answer in the required report format." "continuation prompt"
assert_contains "$OUT" "stub done" "final message present"
assert_not_contains "$OUT" "--- run error ---" "no run error"
rd=$(grep '^RUN_DIR=' <<<"$OUT" | cut -d= -f2)
assert_file "$rd/raw.2.log" "second attempt kept apart"
assert_eq "$(/usr/bin/grep -A1 '^session_id=' <<<"$OUT" | tail -1)" "auto_resumed=1" "line right after session_id"

setup "auto-resume: still dropping after OCLS_AUTO_RESUME attempts -> exit 6 with a hint"
export STUB_ERROR="$DROP" OCLS_AUTO_RESUME=2
run -C "$T" "x"
assert_eq "$RC" "6" "exit code"
assert_eq "$(ncalls)" "3" "1 + 2 calls"
assert_contains "$OUT" "auto_resumed=2" "report line"
assert_contains "$OUT" "--- run error ---" "error shown"
assert_contains "$ERR" "automatic resumes tried: 2" "hint mentions the resumes"

setup "auto-resume: OCLS_AUTO_RESUME=0 -> one call, exit 6"
export STUB_ERROR="$DROP"
run -C "$T" "x"
assert_eq "$RC" "6" "exit code"
assert_eq "$(ncalls)" "1" "one call"
assert_not_contains "$OUT" "auto_resumed" "no report line"
assert_not_contains "$ERR" "automatic" "no resume note"

setup "auto-resume: other errors and a stall timeout are not resumed"
export OCLS_AUTO_RESUME=2 STUB_ERROR="some other failure"
run -C "$T" "x"
assert_eq "$RC" "6" "other error: exit code"
assert_eq "$(ncalls)" "1" "other error: one call"
unset STUB_ERROR
export STUB_SLEEP=4747 OCLS_STALL_TIMEOUT=2
: >"$STUB_LOG"
run -C "$T" "x"
assert_eq "$RC" "6" "stall: exit code"
assert_eq "$(ncalls)" "1" "stall: one call"
sleep 1
/usr/bin/pkill -f 'sleep 4747' || true

setup "auto-resume: model gone after the drop -> exit 6 report, not exit 4"
export STUB_ERROR="$DROP" OCLS_AUTO_RESUME=2 OCLS_DETECT_TRIES=2
cat >"$T/hide.sh" <<EOF
echo '{"data":[]}' >"$T/fix/api/v0/models"
EOF
export STUB_ACTIONS="$T/hide.sh"
run -C "$T" "x"
assert_eq "$RC" "6" "exit code"
assert_eq "$(ncalls)" "1" "no resume without a model"

setup "auto-resume: a build run that drops after a partial edit finishes in the same worktree"
mkrepo "$T/repo"
cat >"$T/actions.sh" <<'EOF'
if [[ -e first.txt ]]; then echo two >second.txt; else echo one >first.txt; fi
EOF
export STUB_ACTIONS="$T/actions.sh" STUB_ERROR="$DROP" STUB_ERROR_TIMES=1 OCLS_AUTO_RESUME=2
run -C "$T/repo" --profile build -l ar "x"
assert_eq "$RC" "0" "exit code"
assert_contains "$OUT" "A	first.txt" "edit before the drop"
assert_contains "$OUT" "A	second.txt" "edit after the resume"
assert_eq "$(/usr/bin/grep -c '^--- changes' <<<"$OUT")" "1" "worktree result once"
assert_eq "$(git -C "$T/repo" branch --list 'opencode/*' | wc -l | tr -d ' ')" "1" "one branch"
assert_eq "$(git -C "$T/repo" worktree list | wc -l | tr -d ' ')" "2" "one worktree"

setup "auto-resume: the resumed attempt prints nothing -> the old answer is not reported, run error says so"
printf '%s\n' '{"type":"text","timestamp":0,"sessionID":"ses_x","part":{"type":"text","text":"stale pre-drop text"}}' >"$T/ev.jsonl"
export STUB_EVENTS="$T/ev.jsonl" STUB_ERROR="$DROP" STUB_ERROR_TIMES=1 STUB_SILENT_AFTER=1 OCLS_AUTO_RESUME=1
run -C "$T" "x"
assert_eq "$RC" "6" "exit code"
assert_eq "$(ncalls)" "2" "two calls"
assert_not_contains "$OUT" "stale pre-drop text" "no stale answer"
assert_not_contains "$OUT" "--- final message ---" "no final message"
assert_contains "$OUT" "--- run error ---" "run error shown"
assert_contains "$OUT" "peer_keepalive_timeout (the resumed attempt produced no output)" "error text with note"
assert_contains "$ERR" "continue with --resume" "usual hint"

setup "report: the stderr tail shows the last attempt's stderr, not attempt 1's"
printf 'attempt-one-noise\n' >"$T/s1"; printf 'attempt-two-noise\n' >"$T/s2"; cp "$T/s1" "$T/stderr_src"
cat >"$T/actions.sh" <<EOF
cp "$T/s2" "$T/stderr_src"
EOF
export STUB_ACTIONS="$T/actions.sh" STUB_STDERR="$T/stderr_src" STUB_ERROR="$DROP" STUB_ERROR_TIMES=1 OCLS_AUTO_RESUME=1 STUB_TEXT=""
run -C "$T" "x"
assert_eq "$RC" "3" "exit code (empty answer)"
tailsec=$(sed -n '/^--- no final message/,$p' <<<"$OUT")
assert_contains "$tailsec" "attempt-two-noise" "tails the resumed attempt's stderr"
assert_not_contains "$tailsec" "attempt-one-noise" "not attempt 1's stderr"

# ---------------------------------------------------------------- SSH route
stop_server() { # kill the python server a test started
  if [[ -f "$T/ssh.pid" ]]; then kill "$(cat "$T/ssh.pid")" 2>/dev/null; fi
  if [[ -n "${SRV:-}" ]]; then kill "$SRV" 2>/dev/null; SRV=""; fi
  wait 2>/dev/null
}

setup "ssh: tunnel already up -> no ssh started, config points at the forwarded port"
unset LMSTUDIO_BASE_URL
python3 -m http.server 18734 --bind 127.0.0.1 --directory "$T/fix" >/dev/null 2>&1 </dev/null &
SRV=$!
sleep 1
export OCLS_SSH_HOST=gpu-box OCLS_SSH_LOCAL_PORT=18734
run -C "$T" "x"
stop_server
assert_eq "$RC" "0" "exit code"
assert_no_file "$T/ssh.log" "ssh not started"
assert_eq "$(call '.config | fromjson | .provider.lmstudio.options.baseURL')" '"http://127.0.0.1:18734/v1"' "baseURL"
assert_contains "$OUT" "device=ssh:gpu-box" "device field"

setup "ssh: --ssh flag and tunnel not up -> ssh is started with the forward"
unset LMSTUDIO_BASE_URL
export OCLS_SSH_LOCAL_PORT=18735 OCLS_SSH_REMOTE_PORT=4321 STUB_SSH_SERVE="$T/fix"
run -C "$T" --ssh gpu-box "x"
stop_server
assert_eq "$RC" "0" "exit code"
sshcmd=$(cat "$T/ssh.log")
assert_contains "$sshcmd" "-f -N -L 127.0.0.1:18735:127.0.0.1:4321" "forward"
assert_contains "$sshcmd" "-o ServerAliveInterval=15" "keepalive"
assert_contains "$sshcmd" "-o ServerAliveCountMax=8" "keepalive count"
assert_contains "$sshcmd" "-o ExitOnForwardFailure=yes" "fail on forward error"
assert_contains "$sshcmd" "-o BatchMode=yes" "no password prompt"
assert_contains "$sshcmd" "gpu-box" "host"
assert_eq "$(call '.config | fromjson | .provider.lmstudio.options.baseURL')" '"http://127.0.0.1:18735/v1"' "baseURL"

setup "ssh: tunnel can't be established -> exit 4 naming the host"
unset LMSTUDIO_BASE_URL
export OCLS_SSH_HOST=gpu-box OCLS_SSH_LOCAL_PORT=18736
run -C "$T" "x"
assert_eq "$RC" "4" "exit code"
assert_contains "$ERR" "gpu-box" "host in message"
assert_contains "$ERR" "lms server start" "hint"
assert_eq "${ERR: -1}" "." "die doesn't print its exit code"
assert_file "$T/ssh.log" "ssh was tried"
[[ ! -s "$STUB_LOG" ]] && ok || bad "opencode was started without a tunnel"

setup "ssh: a listener on the local port that isn't LM Studio -> exit 4, ssh not started"
unset LMSTUDIO_BASE_URL
mkdir "$T/empty"
python3 -m http.server 18738 --bind 127.0.0.1 --directory "$T/empty" >/dev/null 2>&1 </dev/null &
SRV=$!
sleep 1
export OCLS_SSH_HOST=gpu-box OCLS_SSH_LOCAL_PORT=18738 STUB_SSH_SERVE="$T/fix"
run -C "$T" "x"
stop_server
assert_eq "$RC" "4" "exit code"
assert_contains "$ERR" "in use by something else" "message"
assert_contains "$ERR" "OCLS_SSH_LOCAL_PORT" "names the setting"
assert_no_file "$T/ssh.log" "ssh not started"

setup "ssh: a host starting with '-' is rejected"
unset LMSTUDIO_BASE_URL
run -C "$T" --ssh "-oProxyCommand=x" "x"
assert_eq "$RC" "2" "--ssh: exit code"
assert_contains "$ERR" "must not start with '-'" "--ssh: message"
export OCLS_SSH_HOST="-oProxyCommand=x"
run -C "$T" "x"
assert_eq "$RC" "2" "env: exit code"
assert_no_file "$T/ssh.log" "ssh not started"

setup "ssh: OCLS_SSH_HOST together with LMSTUDIO_BASE_URL -> exit 2"
export OCLS_SSH_HOST=gpu-box
run -C "$T" "x"
assert_eq "$RC" "2" "exit code"
assert_contains "$ERR" "LMSTUDIO_BASE_URL" "message"

setup "ssh: a drop is resumed after re-checking the tunnel; hints don't mention lms link"
unset LMSTUDIO_BASE_URL
python3 -m http.server 18737 --bind 127.0.0.1 --directory "$T/fix" >/dev/null 2>&1 </dev/null &
SRV=$!
sleep 1
export OCLS_SSH_HOST=gpu-box OCLS_SSH_LOCAL_PORT=18737 OCLS_AUTO_RESUME=1 STUB_ERROR="$DROP" STUB_ERROR_TIMES=1
run -C "$T" "x"
assert_eq "$RC" "0" "resumed exit code"
assert_eq "$(ncalls)" "2" "two calls"
unset STUB_ERROR_TIMES
: >"$STUB_LOG"
run -C "$T" "x"
stop_server
assert_eq "$RC" "6" "exit code"
assert_contains "$ERR" "connection to gpu-box dropped" "ssh wording"
assert_not_contains "$ERR" "lms link" "no lms link hint"

setup "ssh auto-resume: port taken over by a non-LM-Studio listener -> exit 6 with the report, not exit 4"
unset LMSTUDIO_BASE_URL
mkdir "$T/empty"
python3 -m http.server 18739 --bind 127.0.0.1 --directory "$T/fix" >/dev/null 2>&1 </dev/null &
SRV=$!
disown "$SRV"   # the hijack script kills it mid-run; don't let bash report that as job noise
echo $SRV >"$T/srv.pid"
sleep 1
cat >"$T/hijack.sh" <<EOF
kill "\$(cat "$T/srv.pid")" 2>/dev/null || true
sleep 1
python3 -m http.server 18739 --bind 127.0.0.1 --directory "$T/empty" >/dev/null 2>&1 </dev/null &
echo \$! >"$T/hijack.pid"
sleep 1
EOF
export STUB_ACTIONS="$T/hijack.sh" STUB_ERROR="$DROP" STUB_ERROR_TIMES=1 OCLS_AUTO_RESUME=1 \
      OCLS_SSH_HOST=gpu-box OCLS_SSH_LOCAL_PORT=18739 OCLS_SSH_WAIT=2
run -C "$T" "x"
[[ -f "$T/hijack.pid" ]] && kill "$(cat "$T/hijack.pid")" 2>/dev/null || true
stop_server
assert_eq "$RC" "6" "exit code: report path, not die(4)"
assert_contains "$OUT" "session_id=" "report ran to the end"
assert_contains "$OUT" "--- run error ---" "run error shown"
assert_no_file "$T/ssh.log" "port held -> no ssh started"

setup "ssh: ssh itself exits non-zero -> exit 4 immediately, without waiting OCLS_SSH_WAIT"
unset LMSTUDIO_BASE_URL
export OCLS_SSH_HOST=gpu-box OCLS_SSH_LOCAL_PORT=18740 OCLS_SSH_WAIT=10 STUB_SSH_EXIT=255
t0=$SECONDS
run -C "$T" "x"
assert_eq "$RC" "4" "exit code"
[[ $((SECONDS - t0)) -lt 5 ]] && ok || bad "waited $((SECONDS - t0))s; expected an immediate give-up"
assert_contains "$ERR" "cannot reach LM Studio" "message"

setup "--prune removes run dirs older than N days"
mkdir -p "$OCLS_HOME/runs/old-run" "$OCLS_HOME/runs/new-run"
touch -t 202001010000 "$OCLS_HOME/runs/old-run"
run --prune 7
assert_eq "$RC" "0" "prune exit"
assert_no_file "$OCLS_HOME/runs/old-run" "old run pruned"
assert_file "$OCLS_HOME/runs/new-run" "new run kept"

# ----------------------------------------------------------------
echo
echo "passed: $PASS  failed: $FAIL"
for f in "${FAILED[@]+"${FAILED[@]}"}"; do echo "  - $f"; done
[[ $FAIL -eq 0 ]]
