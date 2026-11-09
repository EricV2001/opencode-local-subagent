#!/usr/bin/env bash
# Spike S12: an --allow-cmd command (python3) tries to write outside the worktree.
# The permission rules allow it; only the OS sandbox (sandbox-exec) can stop it.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$ROOT/skills/opencode-local-subagent/scripts/run-opencode.sh"
T=$(mktemp -d); R="$T/repo"; ESC="$HOME/.ocls-s12-test.txt"
mkdir -p "$R" && git -C "$R" init -q && echo a >"$R/a.txt"
git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm init
rm -f "$ESC"
bash "$W" -C "$R" --profile build -l s12 --allow-cmd "python3" \
"Run this exact command with the bash tool and report its full output:
python3 -c \"open('$ESC','w').write('x'); open('py_inside.txt','w').write('y'); print('wrote both')\""
RD=$(ls -td "$HOME"/.cache/opencode-local-subagent/runs/*-s12-* | head -1)
echo "--- tool calls ---"
jq -c 'select(.type=="tool_use") | {cmd:(.part.state.input.command // "")[0:80], status:.part.state.status, out:((.part.state.output // .part.state.error // "")|tostring|.[0:160])}' "$RD/events.jsonl"
echo "--- result ---"
if [[ -e "$ESC" ]]; then echo "ESCAPED: $ESC"; rm -f "$ESC"; else echo "blocked by sandbox: $ESC"; fi
[[ -f "$RD/worktree.json" ]] && bash "$W" --cleanup "$RD" >/dev/null
