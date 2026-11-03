#!/usr/bin/env bash
# Shared helpers for spikes. Source this file.
BASE="${LMSTUDIO_BASE_URL:-http://127.0.0.1:1234}"

detect_model() {
  curl -sf "$BASE/api/v0/models" \
    | jq -r '[.data[] | select(.state=="loaded" and (.type=="llm" or .type=="vlm"))][0].id'
}

make_config() { # $1 = model id
  jq -nc --arg url "$BASE/v1" --arg m "$1" '{
    "$schema":"https://opencode.ai/config.json",
    provider:{lmstudio:{npm:"@ai-sdk/openai-compatible",name:"LM Studio",options:{baseURL:$url},models:{($m):{}}}}
  }'
}

# run_oc <outfile> <timeout_s> <dir> [extra opencode args...] -- prompt is last arg
run_oc() {
  local out="$1" secs="$2" dir="$3"; shift 3
  ( cd "$dir" && OPENCODE_CONFIG_CONTENT="$CONFIG" \
      perl -e 'alarm shift; exec @ARGV' "$secs" \
      opencode run --format json -m "lmstudio/$MODEL" "$@" >"$out" 2>"$out.err" )
  echo $?
}

last_text() { # $1 = raw log
  grep '^{' "$1" | jq -r 'select(.type=="text") | (.part.text // .text // empty)'
}

session_of() {
  grep '^{' "$1" | jq -r '.sessionID // empty' | head -1
}

MODEL="${MODEL:-$(detect_model)}"
CONFIG="$(make_config "$MODEL")"
export MODEL CONFIG
