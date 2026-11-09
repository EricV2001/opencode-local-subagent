#!/usr/bin/env bash
# Spike S6 + S10.
#  S10: prompt size with web/todo tools hidden vs available (all with skill: deny).
#  S6:  Mac Studio memory sampled every 5 s across sequential runs and a 3-way parallel burst.
set -u
source "$(dirname "$0")/common.sh"
OUT=$(mktemp -d); echo "out=$OUT"
ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }

# --- memory sampler on the Mac Studio (runs remotely, streams back) ---
ssh macstudio 'while true; do
  rss=$(ps -axo rss=,comm= | awk "/llama-server/{s+=\$1} END{printf \"%.1f\", s/1048576}")
  free=$(memory_pressure | awk -F": " "/free percentage/{print \$2}")
  swap=$(sysctl -n vm.swapusage | awk "{print \$6}")
  echo "$(date +%T) llama_rss_GB=$rss free=$free swap_used=$swap"
  sleep 5; done' >"$OUT/mem.log" 2>&1 &
SAMPLER=$!
mark() { echo "$(date +%T) MARK $*" >>"$OUT/marks.log"; }

trial() { # label, permission-json, extra-config-json
  local d t0 t1 tok cfg
  d=$(mktemp -d)
  cfg=$(jq -c --argjson x "$3" '. * $x' <<<"$CONFIG")
  mark "start $1"
  t0=$(ms)
  ( cd "$d" && OPENCODE_PERMISSION="$2" OPENCODE_CONFIG_CONTENT="$cfg" opencode run --format json \
      --title spike -m "lmstudio/$MODEL" "Reply with exactly the word: PONG" >"$d/raw" 2>&1 )
  t1=$(ms)
  tok=$(grep '^{' "$d/raw" | jq -r 'select(.type=="step_finish") | .part.tokens.input' | head -1)
  mark "end $1"
  printf '%-34s %4ss  input_tokens=%s  text=%s\n' "$1" "$(( (t1-t0)/1000 ))" "$tok" "$(last_text "$d/raw")"
}

sleep 6
echo "=== S10: tool trimming (cold runs, each in a fresh dir) ==="
trial "A skill deny (baseline)"          '{"skill":"deny"}' '{}'
trial "B + web tools denied"             '{"skill":"deny","webfetch":"deny","websearch":"deny"}' '{}'
trial "C + web + todo denied"            '{"skill":"deny","webfetch":"deny","websearch":"deny","todowrite":"deny"}' '{}'
trial "D tools:false web+todo"           '{"skill":"deny"}' '{"tools":{"webfetch":false,"websearch":false,"todowrite":false}}'

echo "=== S6: 3 parallel runs ==="
mark "parallel start"
PIDS=()
for i in 1 2 3; do trial "P$i parallel" '{"skill":"deny"}' '{}' & PIDS+=($!); done
wait "${PIDS[@]}"   # not a bare `wait`: that would also wait for the endless sampler
mark "parallel end"
sleep 15
kill "$SAMPLER" 2>/dev/null

echo "=== memory timeline (Mac Studio) ==="
sort "$OUT/mem.log" "$OUT/marks.log" | grep -vE '^\s*$'
