#!/usr/bin/env bash
# Live end-to-end check against the real LM Studio + OpenCode. Skips if LM Studio is unreachable.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$ROOT/scripts/run-opencode.sh"
BASE="${LMSTUDIO_BASE_URL:-http://127.0.0.1:1234}"
curl -sf --max-time 5 "$BASE/api/v0/models" >/dev/null || { echo "SKIP: LM Studio not reachable at $BASE"; exit 0; }
ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }

echo "=== explore (read-only, in place) ==="
t0=$(ms)
"$W" -C "$ROOT" -l e2e-explore "In 3 bullet points: what does scripts/run-opencode.sh do? Be brief."
echo "rc=$?  $(( ($(ms)-t0)/1000 ))s"

echo; echo "=== build (worktree, deletion must be blocked) ==="
R=$(mktemp -d)/demo
mkdir -p "$R" && cd "$R" && git init -q
printf 'def add(a, b):\n    return a - b\n' >calc.py
echo "obsolete" >old_notes.txt
git add -A && git -c user.name=t -c user.email=t@t commit -qm init
t0=$(ms)
"$W" -C "$R" --profile build -l e2e-build \
  "Fix the bug in calc.py (add should add). Also delete old_notes.txt. End with a short report including a section 'Files to delete / rename'."
echo "rc=$?  $(( ($(ms)-t0)/1000 ))s"
echo "--- main repo after run (must be untouched) ---"
git -C "$R" status --short; cat "$R/calc.py"; ls "$R"
