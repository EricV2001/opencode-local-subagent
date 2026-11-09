#!/usr/bin/env bash
# Install the skill for Claude Code by symlinking it into ~/.claude/skills (idempotent).
# Alternative: install as a plugin, see README.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills/opencode-local-subagent"
DEST_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
DEST="$DEST_DIR/opencode-local-subagent"

mkdir -p "$DEST_DIR"
if [[ -L "$DEST" ]]; then
  ln -sfn "$SRC" "$DEST"
elif [[ -e "$DEST" ]]; then
  echo "error: $DEST exists and is not a symlink; move it away first" >&2; exit 1
else
  ln -s "$SRC" "$DEST"
fi
echo "installed: $DEST -> $SRC"

echo; echo "checking requirements:"
missing=0
for c in opencode jq git curl; do
  if command -v "$c" >/dev/null; then echo "  ok      $c"; else echo "  MISSING $c"; missing=1; fi
done
command -v lms >/dev/null && echo "  ok      lms (optional: device name in reports)" || echo "  -       lms not on PATH (optional)"
BASE="${LMSTUDIO_BASE_URL:-http://127.0.0.1:1234}"
if curl -sf --max-time 5 "$BASE/api/v0/models" >/dev/null; then
  echo "  ok      LM Studio server at $BASE"
else
  echo "  -       LM Studio server not reachable at $BASE (start LM Studio / 'lms server start')"
fi
[[ $missing -eq 0 ]] || { echo; echo "install the missing tools before use (opencode: https://opencode.ai)"; exit 1; }
