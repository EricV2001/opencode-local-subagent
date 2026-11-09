#!/usr/bin/env bash
# Spike S9d: capture LM Studio's server log and queue state during one trivial opencode run.
set -u
source "$(dirname "$0")/common.sh"
OUT=$(mktemp -d); W=$(mktemp -d)
echo "out=$OUT"
lms log stream >"$OUT/lms.log" 2>&1 &
LOGPID=$!
( for i in $(seq 1 30); do
    printf '%s ' "$(date +%T)"; lms ps --json 2>/dev/null | jq -c '[.[] | {status, queued}]'
    sleep 5
  done ) >"$OUT/ps.log" &
PSPID=$!
sleep 1
t0=$(date +%T)
( cd "$W" && OPENCODE_CONFIG_CONTENT="$CONFIG" opencode run --format json \
    -m "lmstudio/$MODEL" "Reply with exactly the word: PONG" >"$OUT/raw" 2>&1 )
t1=$(date +%T)
kill "$LOGPID" "$PSPID" 2>/dev/null
echo "run: $t0 -> $t1"
echo "--- lms ps over time (status/queued) ---"; cat "$OUT/ps.log"
echo "--- lms log: request-related lines ---"
grep -iE 'request|POST|completion|prompt|token|title|generat|queue|slot' "$OUT/lms.log" | cut -c1-220 | head -60
echo "--- lms log size: $(wc -l < "$OUT/lms.log") lines ---"
