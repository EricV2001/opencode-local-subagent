#!/usr/bin/env bash
# Spike S9: where does the time before the first model event go?
set -u
source "$(dirname "$0")/common.sh"
OUT=$(mktemp -d); W=$(mktemp -d)
echo "model=$MODEL out=$OUT"
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
( cd "$W" && OPENCODE_CONFIG_CONTENT="$CONFIG" opencode run --format json --print-logs --log-level DEBUG \
    -m "lmstudio/$MODEL" "Reply with exactly the word: PONG" >"$OUT/raw" 2>"$OUT/log" )
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
first=$(grep '^{' "$OUT/raw" | head -1 | jq .timestamp)
last=$(grep '^{' "$OUT/raw" | tail -1 | jq .timestamp)
echo "wall=$(( (t1-t0)/1000 ))s  before-first-event=$(( (first-t0)/1000 ))s  events=$(( (last-first)/1000 ))s  after-last=$(( (t1-last)/1000 ))s"
echo "--- log lines: count by service ---"
grep -o 'service=[a-z.-]*' "$OUT/log" | sort | uniq -c | sort -rn | head -15
echo "--- LLM / title / install / fetch lines ---"
grep -iE 'title|install|fetch|models\.dev|stream|llm|provider|timeout|error' "$OUT/log" | cut -c1-200 | head -40
echo "log: $OUT/log"
