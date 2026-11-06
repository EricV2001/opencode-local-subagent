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
  unset OPENCODE_LOCAL_MODEL OPENCODE_ROUTER_RUNS STUB_TEXT STUB_ACTIONS STUB_BLOCKED STUB_EXIT STUB_LMS_PS_JSON STUB_LMS_PS_TEXT
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
printf '\nIDENTIFIER    MODEL    STATUS    SIZE        CONTEXT    PARALLEL    DEVICE                    TTL\nm-one         m-one    IDLE      84.65 GB    65536      2           Erics-Mac-Studio.local    \n\n' >"$T/ps.txt"
export STUB_LMS_PS_TEXT="$T/ps.txt"
run -C "$T" "hello"
assert_contains "$OUT" "device=Erics-Mac-Studio.local" "device shown"

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

setup "LM Studio unreachable -> exit 4 with LM Link hint"
export LMSTUDIO_BASE_URL="file://$T/nowhere"
run -C "$T" "hello"
assert_eq "$RC" "4" "exit code"
assert_contains "$ERR" "LM Link" "hint"

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

setup "--allow-cmd adds an allow rule before the deny rules"
run -C "$T" --allow-cmd "pytest" "hello"
perm=$(call '.permission | fromjson')
assert_eq "$(jq -r '.bash["pytest *"]' <<<"$perm")" "allow" "pytest allowed"
order=$(jq -r '.bash | keys_unsorted | (index("pytest *") < index("rm *"))' <<<"$perm")
assert_eq "$order" "true" "extra allow before denies"

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
  unset STUB_ACTIONS
  run -C "$T" --no-sandbox "x"
  assert_contains "$OUT" "sandbox=off" "--no-sandbox reported"
  assert_contains "$ERR" "OS sandbox disabled" "--no-sandbox warns"
else
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
run -C "$T" --resume ses_abc "follow up"
assert_eq "$(call '.args | index("-s") as $i | .[$i+1]')" '"ses_abc"' "-s passed"
OUT=$(printf 'line one\nline two\n' | "$WRAPPER" -C "$T" - 2>/dev/null)
assert_contains "$(call '.args[-1]')" 'line two' "stdin prompt"

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
