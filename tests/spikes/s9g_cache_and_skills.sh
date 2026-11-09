#!/usr/bin/env bash
# Spike S9g: (a) do repeated runs in the SAME directory reuse LM Studio's prompt cache?
#            (b) how much smaller is the prompt with skills hidden (skill: deny)?
set -u
source "$(dirname "$0")/common.sh"
D=$(mktemp -d)
ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
trial() { # label, permission-json
  local t0 t1 tok
  t0=$(ms)
  ( cd "$D" && OPENCODE_PERMISSION="$2" OPENCODE_CONFIG_CONTENT="$CONFIG" opencode run --format json \
      --title spike -m "lmstudio/$MODEL" "Reply with exactly the word: PONG" >"$D/.raw" 2>&1 )
  t1=$(ms)
  tok=$(grep '^{' "$D/.raw" | jq -r 'select(.type=="step_finish") | .part.tokens.input' | head -1)
  echo "$1: $(( (t1-t0)/1000 ))s  input_tokens=$tok  text=$(last_text "$D/.raw")"
}
trial "default, run 1 (cold)  " '{}'
trial "default, run 2 same dir" '{}'
trial "skill deny, run 1      " '{"skill":"deny"}'
trial "skill deny, run 2      " '{"skill":"deny"}'
