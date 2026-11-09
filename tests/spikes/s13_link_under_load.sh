#!/usr/bin/env bash
# Spike S13: does LM Link drop (peer_keepalive_timeout) while the remote machine processes a big prompt?
# Sends one cold prompt straight to LM Studio (no OpenCode) and samples link + remote memory meanwhile.
# Usage: s13_link_under_load.sh [approx_tokens]   (default 12000)
set -u
source "$(dirname "$0")/common.sh"
TOKENS="${1:-12000}"
LMS="$HOME/.lmstudio/bin/lms"
OUT=$(mktemp -d); echo "out=$OUT model=$MODEL tokens~$TOKENS"
ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }

sample() {
  while true; do
    v=$(curl -s -m 4 "$BASE/api/v0/models" | jq -c '[.data[]|select(.state=="loaded")|.id]|length' 2>/dev/null)
    l=$("$LMS" link status 2>/dev/null | awk '/Status:/{s=$2} END{print s}')
    m=$(ssh -o ConnectTimeout=3 -o BatchMode=yes macstudio 'memory_pressure | awk -F": " "/free percentage/{print \$2}"; sysctl -n vm.swapusage | awk "{print \$6}"' 2>/dev/null | tr '\n' ' ')
    echo "$(date +%T) visible_models=${v:-?} peer_status=${l:-?} studio_free/swap=${m:-unreachable}"
    sleep 4
  done
}
sample >"$OUT/samples.log" 2>&1 &
SAMPLER=$!

filler=$(perl -e 'print join(" ", map { "alpha$_ beta gamma delta." } 1..int($ARGV[0]/5))' "$TOKENS")
jq -nc --arg m "$MODEL" --arg p "RUN-$RANDOM-$$ $filler Reply with OK." \
  '{model:$m, stream:true, max_tokens:8, messages:[{role:"user",content:$p}]}' >"$OUT/body.json"

t0=$(ms); echo "start $(date +%T)"
curl -sN -m 400 "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d @"$OUT/body.json" >"$OUT/resp.txt" 2>"$OUT/curl.err"
rc=$?
t1=$(ms)
kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
echo "end $(date +%T) curl_rc=$rc elapsed=$(( (t1-t0)/1000 ))s"
echo "--- response (head/tail)"; head -c 300 "$OUT/resp.txt"; echo; tail -c 300 "$OUT/resp.txt"; echo
echo "--- samples"; cat "$OUT/samples.log"
