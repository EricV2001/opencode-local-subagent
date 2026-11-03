#!/usr/bin/env bash
# Spike S3: what does a headless run do when a tool hits an `ask` rule (no --auto)?
set -u
source "$(dirname "$0")/common.sh"
OUT=$(mktemp -d); W=$(mktemp -d); echo hello > "$W/a.txt"
echo "model=$MODEL out=$OUT"

start=$(date +%s)
rc=$(OPENCODE_PERMISSION='{"bash":"ask","edit":"ask"}' \
     run_oc "$OUT/ask" 240 "$W" "Use the bash tool to run: ls -la . Then create a file b.txt containing hi. Report what happened.")
end=$(date +%s)
echo "rc=$rc seconds=$((end-start))  (rc 142 = killed by 240s alarm => hang)"
echo "--- tool events ---"
grep '^{' "$OUT/ask" | jq -c 'select(.type=="tool_use") | {tool:.part.tool, status:.part.state.status, err:(.part.state.error // null)}' | head
echo "--- final text ---"; last_text "$OUT/ask" | tail -5
echo "--- stderr ---"; tail -5 "$OUT/ask.err"
[[ -f "$W/b.txt" ]] && echo "b.txt CREATED" || echo "b.txt not created"
