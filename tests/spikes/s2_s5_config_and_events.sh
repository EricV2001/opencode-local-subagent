#!/usr/bin/env bash
# Spike S2 + S5: inject LM Studio provider via OPENCODE_CONFIG_CONTENT, record raw JSON events.
set -uo pipefail
BASE="${LMSTUDIO_BASE_URL:-http://127.0.0.1:1234}"
OUT="${1:-${TMPDIR:-/tmp}/ocls-spike-s2s5}"
mkdir -p "$OUT"

MODEL=$(curl -sf "$BASE/api/v0/models" | jq -r '[.data[] | select(.state=="loaded" and (.type=="llm" or .type=="vlm"))][0].id')
echo "model=$MODEL"

CONFIG=$(jq -nc --arg url "$BASE/v1" --arg m "$MODEL" '{
  "$schema":"https://opencode.ai/config.json",
  provider:{lmstudio:{npm:"@ai-sdk/openai-compatible",name:"LM Studio",options:{baseURL:$url},models:{($m):{}}}}
}')

WORK=$(mktemp -d)
cd "$WORK"
OPENCODE_CONFIG_CONTENT="$CONFIG" opencode run --format json -m "lmstudio/$MODEL" \
  "Reply with exactly the word: PONG" >"$OUT/raw.log" 2>"$OUT/stderr.log" || echo "exit=$?"

echo "--- event types ---"
grep '^{' "$OUT/raw.log" | jq -r '.type' | sort | uniq -c
echo "--- first event ---"
grep '^{' "$OUT/raw.log" | head -1 | jq -c .
echo "--- text events ---"
grep '^{' "$OUT/raw.log" | jq -c 'select(.type=="text")' | head -3
echo "--- stderr tail ---"
tail -5 "$OUT/stderr.log"
