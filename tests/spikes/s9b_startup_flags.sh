#!/usr/bin/env bash
# Spike S9b: time `opencode run` with network-related features disabled vs default.
set -u
source "$(dirname "$0")/common.sh"
W=$(mktemp -d)
ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
trial() { # label, env assignments...
  local label="$1"; shift
  local t0 t1
  t0=$(ms)
  ( cd "$W" && env "$@" OPENCODE_CONFIG_CONTENT="$CONFIG" opencode run --format json \
      -m "lmstudio/$MODEL" "Reply with exactly the word: PONG" >/dev/null 2>&1 )
  t1=$(ms)
  echo "$label: $(( (t1-t0)/1000 ))s"
}
trial "no-network-flags" OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1
trial "default" X=1
