#!/usr/bin/env bash
# Spike S9e: is the startup stall the auto-generated session title? Compare with an explicit --title.
set -u
source "$(dirname "$0")/common.sh"
W=$(mktemp -d)
ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
t0=$(ms)
( cd "$W" && OPENCODE_CONFIG_CONTENT="$CONFIG" opencode run --format json --title "spike" \
    -m "lmstudio/$MODEL" "Reply with exactly the word: PONG" >"$W/raw" 2>&1 )
t1=$(ms)
echo "with --title: $(( (t1-t0)/1000 ))s  text=$(last_text "$W/raw")"
grep '^{' "$W/raw" | jq -c 'select(.type=="step_finish") | .part.tokens'
