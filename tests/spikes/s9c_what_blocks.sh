#!/usr/bin/env bash
# Spike S9c: inspect open network connections of `opencode run` during the startup stall.
set -u
source "$(dirname "$0")/common.sh"
W=$(mktemp -d)
( cd "$W" && OPENCODE_CONFIG_CONTENT="$CONFIG" opencode run --format json \
    -m "lmstudio/$MODEL" "Reply with exactly the word: PONG" >/dev/null 2>&1 ) &
sleep 8
for p in $(pgrep -f "opencode run --format json"); do
  echo "=== pid $p: $(ps -o command= -p "$p" | cut -c1-80)"
  lsof -nP -a -p "$p" -i 2>/dev/null
done
echo "--- env proxy vars ---"
env | grep -iE '^(https?|all|no)_proxy=' || echo "(none)"
wait
