#!/usr/bin/env bash
# S24 spike: does the guard plugin really stop a shell command in a real `opencode run`?
# No model involved: tests/fake_openai.py plays LM Studio and answers with scripted shell tool calls
# (a quoted `find "-exec"` and a quoted `git log "--output=..."`, both of which the permission patterns
# miss). Runs the real opencode through the wrapper (review profile, --allow-cmd find, --no-web, so the
# sandbox and the network pinning are in play too), then a control run with the plugin made a no-op.
#   tests/spikes/s24_guard_plugin.sh [path-to-opencode]     (default: opencode on PATH)
# Exit 0 = the guard blocked both calls and the control run shows they would have run.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/opencode-local-subagent"
T=$(mktemp -d); SRV=""
cleanup() { [[ -z "$SRV" ]] || kill "$SRV" 2>/dev/null; rm -rf "$T"; }
[[ -n "${KEEP:-}" ]] || trap cleanup EXIT
if [[ $# -ge 1 ]]; then mkdir -p "$T/bin"; ln -s "$1" "$T/bin/opencode"; export PATH="$T/bin:$PATH"; fi
command -v opencode >/dev/null || { echo "no opencode on PATH"; exit 2; }
MAJOR=$(opencode --version | grep -oE '[0-9]+' | head -1)
TOOL=bash; [[ "$MAJOR" == "2" ]] && TOOL=shell
unset OCLS_SSH_HOST OPENCODE_LOCAL_MODEL OPENCODE_PERMISSION OPENCODE_CONFIG_CONTENT
FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1 (expected '$3', got '$2')"; FAIL=1; fi; }

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
mkrepo() { mkdir -p "$1"; git -C "$1" init -q; echo a >"$1/a.txt"; git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t commit -qm init; }

one_run() { # $1 = skill dir whose wrapper to use, $2 = name
  local name="$2" repo="$T/$2-repo"
  mkrepo "$repo"
  jq -n --arg t "$TOOL" '[
    {tool:$t, args:{command:"find . \"-exec\" touch pwned1 {} +", description:"x"}},
    {tool:$t, args:{command:"git log \"--output=pwned3\"", description:"x"}},
    {tool:$t, args:{command:"git log --oneline", description:"x"}}]' >"$T/$name-script.json"
  python3 "$ROOT/tests/fake_openai.py" "$PORT" "$T/$name-script.json" "$T/$name-server.jsonl" &
  SRV=$!
  for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/api/v0/models" >/dev/null && break; sleep 0.1; done
  LMSTUDIO_BASE_URL="http://127.0.0.1:$PORT" OCLS_HOME="$T/$name-home" OCLS_STALL_TIMEOUT=90 OCLS_DETECT_TRIES=2 \
    "$1/scripts/run-opencode.sh" -C "$repo" --profile review --allow-cmd find --no-web -l "$name" "list files" >"$T/$name-out.txt" 2>"$T/$name-err.txt"
  kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
}

echo "opencode $(opencode --version | head -1); shell tool name: $TOOL"
one_run "$SKILL" guarded
echo "--- guarded run report"; grep -E 'profile=|^status:|blocked|pwned|git log|find' "$T/guarded-out.txt" | head -12
check "quoted find -exec did not run (no pwned1)" "$([[ -e $T/guarded-repo/pwned1 ]] && echo created || echo absent)" absent
check "quoted git log --output did not write (no pwned3)" "$([[ -e $T/guarded-repo/pwned3 ]] && echo created || echo absent)" absent
if [[ "$(uname -s)" == Linux ]]; then   # bubblewrap: no network pinning
  check "report header says sandbox=on net=open (Linux)" "$(grep -c -E "sandbox=on .*net=open" "$T/guarded-out.txt")" 1
else
  check "report header says net=pinned (1.x) or net=loopback (2.x)" "$(grep -c -E "net=(pinned|loopback)" "$T/guarded-out.txt")" 1
fi
check "both calls listed as blocked" "$(sed -n '/^--- blocked tool calls ---$/,/^---/p' "$T/guarded-out.txt" | grep -c -E '"-exec"|--output=pwned3')" 2
check "a plain git log still works (3rd call got a result)" "$(grep -c 'tool_result' "$T/guarded-server.jsonl")" 3
grep -m1 -h -o 'blocked by the opencode-local-subagent guard[^"]*' "$T/guarded-server.jsonl" || true

# control: same run, plugin replaced by a no-op -> the quoted forms get through the permission patterns
cp -R "$SKILL" "$T/ctl"
printf 'export default { id: "noop", async setup() {}, async server() { return {} } }\n' >"$T/ctl/plugin/guard/index.js"
one_run "$T/ctl" control
echo "--- control run (plugin disabled)"; grep -E 'blocked|pwned' "$T/control-out.txt" | head -5
check "control: quoted find -exec ran (pwned1 created)" "$([[ -e $T/control-repo/pwned1 ]] && echo created || echo absent)" created
check "control: quoted git log --output wrote (pwned3 created)" "$([[ -e $T/control-repo/pwned3 ]] && echo created || echo absent)" created
[[ $FAIL -eq 0 ]] && echo "S24 spike: PASS" || echo "S24 spike: FAIL"
exit $FAIL
