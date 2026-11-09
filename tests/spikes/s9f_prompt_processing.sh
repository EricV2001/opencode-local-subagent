#!/usr/bin/env bash
# Spike S9f: measure raw prompt-processing speed of the loaded model (no OpenCode involved).
# Sends a ~14k-token prompt with max_tokens=1, then the identical prompt again (prefix cache),
# then a prompt that differs at the very start (cache miss).
set -u
source "$(dirname "$0")/common.sh"
ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
filler=$(perl -e 'print join(" ", map { "alpha$_ beta gamma delta." } 1..2800)')
send() { # $1 label, $2 prefix
  local body t0 t1 usage
  body=$(jq -nc --arg m "$MODEL" --arg p "$2 $filler Reply with OK." \
    '{model:$m, max_tokens:1, messages:[{role:"user",content:$p}]}')
  t0=$(ms)
  usage=$(curl -s "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "$body" | jq -c '.usage | {prompt_tokens, cached:(.prompt_tokens_details.cached_tokens // null)}')
  t1=$(ms)
  local secs=$(( (t1-t0) ))
  local pt; pt=$(jq -r .prompt_tokens <<<"$usage")
  echo "$1: ${secs}ms usage=$usage  => $(( pt * 1000 / (secs>0?secs:1) )) tok/s"
}
send "cold      " "RUN-$RANDOM-A"
send "same again" "RUN-SAME"
send "same again" "RUN-SAME"
