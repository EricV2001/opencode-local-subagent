#!/usr/bin/env bash
# Spike S1: a new `opencode run` must not remember a previous run; `-s <id>` must.
set -u
source "$(dirname "$0")/common.sh"
OUT=$(mktemp -d); W=$(mktemp -d)
echo "model=$MODEL out=$OUT"

rc=$(run_oc "$OUT/r1" 300 "$W" "Remember this secret word: BANANA42. Reply only: OK")
s1=$(session_of "$OUT/r1"); echo "run1 rc=$rc session=$s1 text=$(last_text "$OUT/r1")"

rc=$(run_oc "$OUT/r2" 300 "$W" "Did I tell you a secret word earlier in this conversation? Reply with the word, or NONE if not.")
s2=$(session_of "$OUT/r2"); t2=$(last_text "$OUT/r2"); echo "run2 rc=$rc session=$s2 text=$t2"

rc=$(run_oc "$OUT/r3" 300 "$W" -s "$s1" "What secret word did I tell you? Reply with only the word.")
t3=$(last_text "$OUT/r3"); echo "run3(resume) rc=$rc text=$t3"

[[ "$s1" != "$s2" ]] && echo "PASS new session id" || echo "FAIL same session id"
grep -q BANANA42 <<<"$t2" && echo "FAIL fresh run knew the word" || echo "PASS fresh run did not know the word"
grep -q BANANA42 <<<"$t3" && echo "PASS resume kept context" || echo "FAIL resume lost context"
