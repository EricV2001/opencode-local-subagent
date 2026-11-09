#!/usr/bin/env bash
# run-opencode.sh: delegate a task to OpenCode running on whatever model LM Studio has loaded.
#
# Usage:
#   run-opencode.sh [-C dir] [--profile explore|review|build] [-l label] [-m model]
#                   [--allow-cmd "<cmd>"]... [--copy <path>]... [--keep] [--no-sandbox] [--no-web]
#                   [--resume <session-id>] [--fork] [-f <file>]... [-v variant]
#                   <prompt | ->
#   run-opencode.sh --cleanup <run-dir>     remove a build run's worktree + branch
#   run-opencode.sh --prune <days>          delete runs (and their worktrees) older than N days;
#                                           their sessions can't be resumed afterwards
#
# Profiles: explore (default, read-only, in place) | review (read-only) |
#           build (edits allowed in a throwaway git worktree; deletions/renames blocked).
# On macOS the run is wrapped in sandbox-exec: writes only to the worktree, OpenCode's own dirs and temp.
# --no-web denies webfetch/websearch, so nothing the agent reads can be sent out through them.
# Prompt: one argument, or "-" to read it from stdin (preferred for multi-line briefs).
# --resume continues a session in the directory it started in (for build: the same worktree).
# Env: LMSTUDIO_BASE_URL (default http://127.0.0.1:1234), OPENCODE_LOCAL_MODEL,
#      OCLS_HOME (default ~/.cache/opencode-local-subagent), OPENCODE_ROUTER_RUNS,
#      OCLS_DETECT_TRIES/OCLS_DETECT_DELAY (wait for a model: default 18 x 10 s),
#      OCLS_STALL_TIMEOUT (stop a run with no output for this many seconds; default 600, 0 = off).
# Exit: 0 ok | 2 usage | 3 empty answer | 4 LM Studio/model problem | 5 build needs a git repo
#       | 6 run stopped on an error (e.g. LM Link dropped) | otherwise opencode's own exit code.
#
# Adapted from luckeyfaraday/delegate-to-opencode (MIT).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="$SCRIPT_DIR/../profiles"
BASE="${LMSTUDIO_BASE_URL:-http://127.0.0.1:1234}"; BASE="${BASE%/}"
OCLS_HOME="${OCLS_HOME:-$HOME/.cache/opencode-local-subagent}"
RUNS_ROOT="${OPENCODE_ROUTER_RUNS:-$OCLS_HOME/runs}"
# OpenCode's own config/data/cache/state for delegated runs, apart from the user's: the sandbox has to
# allow writes there, and code planted in the user's dirs (plugins, provider packages, tool binaries)
# would later run outside the sandbox.
OC_HOME="$OCLS_HOME/opencode"
MIN_CTX=12288    # OpenCode's own prompt is ~8.5k tokens (docs/findings.md S9/S10)
WARN_CTX=32768
# A link drop hides the remote model for ~1.5–2 min (docs/findings.md S14), so wait ~3 min.
DETECT_TRIES="${OCLS_DETECT_TRIES:-18}"
DETECT_DELAY="${OCLS_DETECT_DELAY:-10}"
# No events arrive while a prompt is processed (a cold ~20k-token prompt took ~3 min), so be generous.
STALL_TIMEOUT="${OCLS_STALL_TIMEOUT:-600}"

WORKDIR="$PWD"; PROFILE="explore"; LABEL="run"; MODEL="${OPENCODE_LOCAL_MODEL:-}"
VARIANT=""; RESUME=""; FORK=0; KEEP=0; NO_SANDBOX=0; NO_WEB=0
declare -a FILES=() ALLOW_CMDS=() COPIES=()

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }
die()  { echo "run-opencode.sh: $*" >&2; exit "${2:-2}"; }
warn() { echo "warning: $*" >&2; }
need() { command -v "$1" >/dev/null || die "$1 not found${2:+ ($2)}"; }

# ------------------------------------------------------------------ maintenance commands
remove_worktree() { # $1 = worktree.json
  local repo wt br
  repo=$(jq -r .repo "$1"); wt=$(jq -r .worktree "$1"); br=$(jq -r .branch "$1")
  # rm -rf only as a fallback, and only for a path that really is one of our worktrees
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null \
    || { [[ "$wt" == "$OCLS_HOME/worktrees/"?* && "$wt" != *..* ]] && rm -rf "$wt"; } || true
  git -C "$repo" worktree prune 2>/dev/null || true
  git -C "$repo" branch -D "$br" >/dev/null 2>&1 || true
}

if [[ "${1:-}" == "--cleanup" ]]; then
  [[ -f "${2:-}/worktree.json" ]] || die "no worktree.json in run dir: ${2:-<missing>}"
  remove_worktree "$2/worktree.json"
  echo "removed worktree $(jq -r .worktree "$2/worktree.json") and branch $(jq -r .branch "$2/worktree.json")"
  exit 0
fi
if [[ "${1:-}" == "--prune" ]]; then
  [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--prune needs a number of days"
  [[ -d "$RUNS_ROOT" ]] || exit 0
  while IFS= read -r d; do
    [[ -f "$d/worktree.json" ]] && remove_worktree "$d/worktree.json"
    rm -rf "$d"; echo "pruned $d"
  done < <(find "$RUNS_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+$2")
  exit 0
fi

# ------------------------------------------------------------------ arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--cd)       WORKDIR="$2"; shift 2 ;;
    -p|--profile)  PROFILE="$2"; shift 2 ;;
    -l|--label)    LABEL="$2"; shift 2 ;;
    -m|--model)    MODEL="$2"; shift 2 ;;
    -v|--variant)  VARIANT="$2"; shift 2 ;;
    --allow-cmd)   ALLOW_CMDS+=("$2"); shift 2 ;;
    --copy)        COPIES+=("$2"); shift 2 ;;
    --keep)        KEEP=1; shift ;;
    --no-sandbox)  NO_SANDBOX=1; shift ;;
    --no-web)      NO_WEB=1; shift ;;
    --resume)      RESUME="$2"; shift 2 ;;
    --fork)        FORK=1; shift ;;
    -f|--file)     FILES+=(-f "$2"); shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    --)            shift; break ;;
    -)             break ;;
    -*)            echo "run-opencode.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)             break ;;
  esac
done

[[ $# -ge 1 ]] || die "missing prompt (use '-' for stdin)"
[[ -f "$PROFILES_DIR/$PROFILE.json" && "$PROFILE" != common ]] || die "unknown profile: $PROFILE (explore|review|build)"
need jq; need git; need curl; need opencode "install: https://opencode.ai"
[[ -d "$WORKDIR" ]] || die "working directory does not exist: $WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"
LABEL="$(tr -c 'A-Za-z0-9._-' '-' <<<"$LABEL" | sed 's/-*$//')"
[[ -n "$LABEL" ]] || LABEL=run
PROMPT_ARG="$1"
USE_WT=$(jq -r '.worktree' "$PROFILES_DIR/$PROFILE.json")

# ------------------------------------------------------------------ resume: find the session's run
# OpenCode can't continue a session from a different directory (S14: it errored or hung), so a
# resume runs where the session started; for build that is the original worktree, edits included.
find_run() { # most recent run dir whose session_id is $1 (run dirs sort by time)
  local f last=""
  for f in "$RUNS_ROOT"/*/session_id; do
    [[ -f "$f" && -f "${f%/session_id}/run_in" && "$(cat "$f")" == "$1" ]] && last="${f%/session_id}"
  done
  printf '%s' "$last"
}
PREV_RUN=""; PREV_WT=""
if [[ -n "$RESUME" ]]; then
  PREV_RUN=$(find_run "$RESUME")
  if [[ -n "$PREV_RUN" && -f "$PREV_RUN/worktree.json" ]]; then
    PREV_WT=$(jq -r .worktree "$PREV_RUN/worktree.json")
    [[ -d "$PREV_WT" ]] || die "session $RESUME ran in worktree $PREV_WT, which has been removed. Start a new run instead of resuming."
  elif [[ "$USE_WT" == "true" ]]; then
    die "can't resume $RESUME as a build run: no build run with that session was found in $RUNS_ROOT. Start a new build run."
  fi
  if [[ -n "$PREV_RUN" ]]; then
    [[ -d "$(cat "$PREV_RUN/run_in")" ]] || die "the session's directory $(cat "$PREV_RUN/run_in") no longer exists"
  fi
fi

# ------------------------------------------------------------------ LM Studio model detection
# Retried: a remote model disappears from this list while LM Link reconnects (~1.5–2 min), and the
# list can time out while the serving machine is busy (docs/findings.md S13/S14). If the local
# server doesn't answer at all, waiting won't help, so give up after the second try.
reachable=0; LOADED='[]'; n_loaded=0; waited=0
for ((try = 1; try <= DETECT_TRIES; try++)); do
  if MODELS_JSON=$(curl -sf --max-time 10 "$BASE/api/v0/models"); then
    reachable=1
    LOADED=$(jq -c '[.data[] | select(.state=="loaded" and (.type=="llm" or .type=="vlm"))]' <<<"$MODELS_JSON")
    n_loaded=$(jq length <<<"$LOADED")
    if [[ "$n_loaded" -gt 0 ]]; then break; fi
  elif [[ $reachable -eq 0 && $try -ge 2 ]]; then
    break
  fi
  if [[ $try -lt $DETECT_TRIES ]]; then
    if [[ $reachable -eq 1 && $waited -eq 0 ]]; then
      warn "no model visible yet; waiting up to $(( (DETECT_TRIES - 1) * DETECT_DELAY ))s (LM Link may be reconnecting)"
      waited=1
    fi
    sleep "$DETECT_DELAY"
  fi
done
[[ $reachable -eq 1 ]] \
  || die "cannot reach LM Studio at $BASE. Start LM Studio (or 'lms server start'); for remote models check that LM Link is enabled and the serving machine is online." 4
MODEL="${MODEL#lmstudio/}"

if [[ -z "$MODEL" ]]; then
  [[ "$n_loaded" -gt 0 ]] || die "no model loaded in LM Studio after $DETECT_TRIES tries. Load one, or if it runs on a linked device, LM Link may be down: check 'lms link status'." 4
  if [[ "$n_loaded" -gt 1 ]]; then
    recent=""
    if command -v lms >/dev/null; then
      recent=$(lms ps --json 2>/dev/null | jq -r --argjson l "$LOADED" \
        '[.[] | select(.identifier as $i | $l | map(.id) | index($i))] | max_by(.lastUsedTime // 0) | .identifier // empty' 2>/dev/null || true)
    fi
    MODEL="${recent:-$(jq -r '.[0].id' <<<"$LOADED")}"
    warn "$n_loaded models loaded; using '$MODEL' (override with -m or OPENCODE_LOCAL_MODEL)"
  else
    MODEL=$(jq -r '.[0].id' <<<"$LOADED")
  fi
fi
MINFO=$(jq -c --arg m "$MODEL" 'map(select(.id==$m)) | .[0] // empty' <<<"$LOADED")
[[ -n "$MINFO" ]] || die "model '$MODEL' is not loaded in LM Studio (loaded: $(jq -r 'map(.id) | join(", ")' <<<"$LOADED"))" 4
CTX=$(jq -r '.loaded_context_length // .max_context_length // 0' <<<"$MINFO")
[[ "$CTX" -ge "$MIN_CTX" ]] || die "model context is $CTX tokens; OpenCode needs at least $MIN_CTX (its own prompt is ~8.5k). Increase the context length in LM Studio." 4
[[ "$CTX" -ge "$WARN_CTX" ]] || warn "context is only $CTX tokens; keep the task small"
jq -e '(.capabilities // []) | index("tool_use")' <<<"$MINFO" >/dev/null || warn "model does not advertise tool_use; tool calls may fail"

DEVICE=""
if command -v lms >/dev/null; then # best effort: DEVICE column of `lms ps`
  DEVICE=$(lms ps 2>/dev/null | awk -v m="$MODEL" -F'  +' '
    !c && /IDENTIFIER/ { for (i=1;i<=NF;i++) if ($i=="DEVICE") c=i; next }
    c && $1==m { print $c; exit }' || true)
fi

OUTPUT_LIMIT=$(( CTX / 4 < 32768 ? CTX / 4 : 32768 ))
CONFIG=$(jq -nc --arg url "$BASE/v1" --arg m "$MODEL" --argjson ctx "$CTX" --argjson out "$OUTPUT_LIMIT" '{
  "$schema": "https://opencode.ai/config.json",
  provider: { lmstudio: { npm: "@ai-sdk/openai-compatible", name: "LM Studio",
    options: { baseURL: $url },
    models: { ($m): { name: $m, limit: { context: $ctx, output: $out } } } } } }')

# ------------------------------------------------------------------ permissions
extra=$(printf '%s\n' "${ALLOW_CMDS[@]+"${ALLOW_CMDS[@]}"}" | jq -Rsc 'split("\n") | map(select(length>0))')
PERMISSION=$(jq -nc --slurpfile c "$PROFILES_DIR/common.json" --slurpfile p "$PROFILES_DIR/$PROFILE.json" --argjson extra "$extra" '
  ($c[0]) as $c | ($p[0]) as $p
  | ($c.bash_allow + $p.bash_allow + $extra | map(., . + " *") | unique) as $allow
  | ($c.permission + $p.permission)
    + { bash: ([{key:"*", value:"deny"}]
               + ($allow | map({key:., value:"allow"}))
               + ($c.bash_deny | map({key:., value:"deny"})) | from_entries) }')
if [[ $NO_WEB -eq 1 ]]; then PERMISSION=$(jq -c '.webfetch = "deny" | .websearch = "deny"' <<<"$PERMISSION"); fi

# ------------------------------------------------------------------ run dir + prompt
TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RUNS_ROOT/$TS-$LABEL-$$"
mkdir -p "$RUN_DIR"
if [[ "$PROMPT_ARG" == "-" ]]; then cat >"$RUN_DIR/prompt.md"; else printf '%s\n' "$PROMPT_ARG" >"$RUN_DIR/prompt.md"; fi
[[ -s "$RUN_DIR/prompt.md" ]] || die "empty prompt"
printf '%s\n' "$PERMISSION" >"$RUN_DIR/permission.json"

# ------------------------------------------------------------------ worktree (build)
RUN_IN="$WORKDIR"
if [[ -n "$PREV_RUN" ]]; then
  RUN_IN="$(cat "$PREV_RUN/run_in")"
  [[ "$RUN_IN" == "$WORKDIR" || -n "$PREV_WT" ]] || warn "resuming in the session's own directory $RUN_IN (not $WORKDIR)"
fi
G=(git -c user.name=opencode-local-subagent -c user.email=opencode-local-subagent@localhost -c commit.gpgsign=false)
if [[ -n "$PREV_WT" ]]; then
  # continue in the session's worktree: same baseline, the edits made so far stay in place
  [[ ${#COPIES[@]} -eq 0 ]] || warn "--copy ignored when resuming (the worktree already exists)"
  cp "$PREV_RUN/worktree.json" "$RUN_DIR/worktree.json"
  WT="$PREV_WT"; BRANCH=$(jq -r .branch "$RUN_DIR/worktree.json"); BASELINE=$(jq -r .baseline "$RUN_DIR/worktree.json")
elif [[ "$USE_WT" == "true" ]]; then
  REPO=$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null) || die "profile '$PROFILE' needs a git repository; $WORKDIR is not inside one" 5
  git -C "$REPO" rev-parse --verify -q HEAD >/dev/null || die "git repo has no commits yet; commit once before using '$PROFILE'" 5
  REL=$(git -C "$WORKDIR" rev-parse --show-prefix); REL="${REL%/}"
  WT="$OCLS_HOME/worktrees/$(basename "$REPO")-$LABEL-$TS-$$"
  BRANCH="opencode/$LABEL-$TS-$$"
  mkdir -p "$OCLS_HOME/worktrees"
  git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" HEAD
  # carry over uncommitted work (modified/deleted tracked + untracked non-ignored files)
  while IFS= read -r -d '' f; do
    if [[ -e "$REPO/$f" || -L "$REPO/$f" ]]; then mkdir -p "$WT/$(dirname "$f")"; cp -p "$REPO/$f" "$WT/$f"
    else rm -f "$WT/$f"; fi
  done < <(git -C "$REPO" ls-files -z -m -d -o --exclude-standard)
  for c in "${COPIES[@]+"${COPIES[@]}"}"; do   # opt-in gitignored needs; real copies, never symlinks
    src="$REPO/${c#/}"; [[ -e "$src" ]] || die "--copy path not found: $c"
    mkdir -p "$WT/$(dirname "${c#/}")"; cp -RL "$src" "$WT/${c#/}"
  done
  "${G[@]}" -C "$WT" add -A
  "${G[@]}" -C "$WT" commit -q --allow-empty --no-verify -m "opencode baseline (user's working state)"
  BASELINE=$(git -C "$WT" rev-parse HEAD)
  jq -n --arg repo "$REPO" --arg wt "$WT" --arg br "$BRANCH" --arg base "$BASELINE" \
    '{repo:$repo, worktree:$wt, branch:$br, baseline:$base}' >"$RUN_DIR/worktree.json"
  RUN_IN="$WT${REL:+/$REL}"
fi

# ------------------------------------------------------------------ run opencode
args=(opencode run --format json --auto --dir "$RUN_IN" --title "$LABEL" -m "lmstudio/$MODEL")
[[ -n "$VARIANT" ]] && args+=(--variant "$VARIANT")
[[ -n "$RESUME" ]]  && args+=(-s "$RESUME")
[[ $FORK -eq 1 ]]   && args+=(--fork)
[[ ${#FILES[@]} -gt 0 ]] && args+=("${FILES[@]}")
args+=(-- "$(cat "$RUN_DIR/prompt.md")")   # -- so a prompt starting with "-" isn't read as a flag

# ------------------------------------------------------------------ OS sandbox (macOS sandbox-exec)
# Writes are limited to: the worktree and the parts of the repo's .git that a commit on its branch
# needs, OpenCode's dirs for delegated runs ($OC_HOME), and temp dirs. Reads and network stay open.
# Paths are passed as -D params, so no SBPL quoting issues.
SANDBOX="off"
real() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
if [[ $NO_SANDBOX -eq 1 ]]; then
  warn "OS sandbox disabled (--no-sandbox); relying on permission rules only"
elif ! command -v sandbox-exec >/dev/null; then
  warn "sandbox-exec not available on this OS; relying on permission rules only"
elif ! sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then
  warn "cannot apply a sandbox here (already inside one?); relying on the outer sandbox + permission rules"
else
  mkdir -p "$OC_HOME"
  SB_DIRS=("$(real "${TMPDIR:-/tmp}")" /private/tmp /private/var/tmp "$(real "$OC_HOME")")
  if [[ "$USE_WT" == "true" ]]; then
    # Not the whole shared .git: hooks/ and config there would later run or apply outside the
    # sandbox. A commit on the worktree's branch only needs these (docs/findings.md S15).
    GC=$(cd "$WT" && real "$(git rev-parse --git-common-dir)")
    SB_DIRS+=("$(real "$WT")" "$(cd "$WT" && real "$(git rev-parse --git-dir)")"
              "$GC/objects" "$GC/refs/heads/opencode" "$GC/logs/refs/heads/opencode")
  fi
  {
    echo '(version 1)'
    echo '(allow default)'
    echo '(deny file-write*)'
    echo '(allow file-write* (subpath "/dev"))'
    for i in "${!SB_DIRS[@]}"; do echo "(allow file-write* (subpath (param \"P$i\")))"; done
  } >"$RUN_DIR/sandbox.sb"
  sb=(sandbox-exec -f "$RUN_DIR/sandbox.sb")
  for i in "${!SB_DIRS[@]}"; do sb+=(-D "P$i=${SB_DIRS[$i]}"); done
  args=("${sb[@]}" "${args[@]}")
  SANDBOX="on"
fi

echo "RUN_DIR=$RUN_DIR"
WEB=on; [[ $NO_WEB -eq 1 ]] && WEB=off
echo "profile=$PROFILE model=$MODEL context=$CTX${DEVICE:+ device=$DEVICE} sandbox=$SANDBOX web=$WEB workdir=$WORKDIR${RESUME:+ resume=$RESUME}"
[[ "$USE_WT" == "true" ]] && echo "worktree=$RUN_IN branch=$BRANCH baseline=${BASELINE:0:12}"

printf '%s\n' "$RUN_IN" >"$RUN_DIR/run_in"   # where this session lives; --resume goes back here

set +e
mkdir -p "$OC_HOME"/{config,data,cache,state}
( cd "$RUN_IN" && export OPENCODE_CONFIG_CONTENT="$CONFIG" OPENCODE_PERMISSION="$PERMISSION" \
    XDG_CONFIG_HOME="$OC_HOME/config" XDG_DATA_HOME="$OC_HOME/data" \
    XDG_CACHE_HOME="$OC_HOME/cache" XDG_STATE_HOME="$OC_HOME/state" && exec "${args[@]}" ) \
  >"$RUN_DIR/raw.log" 2>"$RUN_DIR/stderr.log" &
oc_pid=$!
STALLED=0
if [[ "$STALL_TIMEOUT" -gt 0 ]]; then  # stop the run if OpenCode prints nothing for STALL_TIMEOUT s
  last_size=-1; idle=0
  while kill -0 "$oc_pid" 2>/dev/null; do
    sleep 1
    size=$(wc -c <"$RUN_DIR/raw.log")
    if [[ "$size" -ne "$last_size" ]]; then last_size=$size; idle=0; else idle=$((idle + 1)); fi
    if [[ $idle -ge $STALL_TIMEOUT ]]; then
      STALLED=1
      pkill -TERM -P "$oc_pid" 2>/dev/null; kill -TERM "$oc_pid" 2>/dev/null
      break
    fi
  done
fi
wait "$oc_pid"
status=$?
set -e

# ------------------------------------------------------------------ parse events
grep '^{' "$RUN_DIR/raw.log" >"$RUN_DIR/events.jsonl" || true
EV="$RUN_DIR/events.jsonl"
jq -r 'select(.sessionID) | .sessionID' "$EV" 2>/dev/null | head -1 >"$RUN_DIR/session_id" || true
[[ -s "$RUN_DIR/session_id" ]] || echo unknown >"$RUN_DIR/session_id"
# final message = text parts after the last tool call (OpenCode >=1.19 puts text in .part.text)
jq -js '(map(.type=="tool_use") | rindex(true) // -1) as $t
        | to_entries | map(select(.key > $t and .value.type=="text") | (.value.part.text // .value.text // empty))
        | join("\n")' "$EV" >"$RUN_DIR/last_message.txt" 2>/dev/null || : >"$RUN_DIR/last_message.txt"
jq -r 'select(.type=="tool_use" and .part.state.status=="error")
       | "\(.part.tool): \(.part.state.input.command // .part.state.input.filePath // .part.state.input.url // (.part.state.input|tostring))"' \
  "$EV" >"$RUN_DIR/blocked.txt" 2>/dev/null || : >"$RUN_DIR/blocked.txt"
jq -c 'select(.type=="error" or .type=="step_finish")' "$EV" 2>/dev/null | tail -1 >"$RUN_DIR/meta.json" || true
# run-level error; OpenCode wraps the provider's message as a JSON string
jq -r 'select(.type=="error")
       | (.error.data.message // .error.message // .error.name // .message // "unknown error") as $m
       | ((try ($m | fromjson | .message) catch null) // $m)' \
  "$EV" 2>/dev/null | tail -1 >"$RUN_DIR/error.txt" || : >"$RUN_DIR/error.txt"
if [[ $STALLED -eq 1 ]]; then
  echo "no output from OpenCode for ${STALL_TIMEOUT}s; run stopped (stall timeout). If the model was just slow, raise OCLS_STALL_TIMEOUT." >"$RUN_DIR/error.txt"
fi
RUN_ERROR="$(cat "$RUN_DIR/error.txt")"
SESSION_ID="$(cat "$RUN_DIR/session_id")"

echo "exit_code=$status"
echo "session_id=$SESSION_ID"

# ------------------------------------------------------------------ worktree result
if [[ "$USE_WT" == "true" ]]; then
  "${G[@]}" -C "$WT" add -A
  "${G[@]}" -C "$WT" diff --cached --quiet || "${G[@]}" -C "$WT" commit -q --no-verify -m "opencode result: $LABEL"
  CHANGES=$(git -C "$WT" diff --name-status "$BASELINE"..HEAD)
  echo "--- changes (baseline..$BRANCH) ---"
  if [[ -z "$CHANGES" ]]; then
    # only a finished run's worktree goes; after an error or an empty answer it stays for --resume
    if [[ $KEEP -eq 1 ]]; then echo "no changes (worktree kept: --keep)"
    elif [[ $status -ne 0 || -n "$RUN_ERROR" || ! -s "$RUN_DIR/last_message.txt" ]]; then
      echo "no changes yet; worktree kept so the session can be resumed (remove it with: $0 --cleanup $RUN_DIR)"
    else remove_worktree "$RUN_DIR/worktree.json"; echo "no changes; worktree and branch removed"; fi
  else
    awk -F'\t' '$1=="D"{print "!! DELETED: " $2}' <<<"$CHANGES"
    printf '%s\n' "$CHANGES"
    git -C "$WT" diff --shortstat "$BASELINE"..HEAD
    echo "review: git -C $WT diff $BASELINE..HEAD"
    echo "cleanup after merging: $0 --cleanup $RUN_DIR"
  fi
fi

if [[ -s "$RUN_DIR/blocked.txt" ]]; then
  echo "--- blocked tool calls ---"
  cat "$RUN_DIR/blocked.txt"
fi

if [[ -n "$RUN_ERROR" ]]; then
  echo "--- run error ---"
  echo "$RUN_ERROR"
fi

if [[ -s "$RUN_DIR/last_message.txt" ]]; then
  echo "--- final message ---"
  cat "$RUN_DIR/last_message.txt"; echo
elif [[ -z "$RUN_ERROR" ]]; then
  echo "--- no final message; stderr tail ---"
  tail -20 "$RUN_DIR/stderr.log" 2>/dev/null || true
  if [[ $status -eq 0 ]]; then
    echo "run-opencode.sh: empty answer. A thinking model may have spent its budget reasoning, or the agent stopped after blocked tool calls. Check $EV; consider --resume $SESSION_ID with a nudge." >&2
    exit 3
  fi
fi

if [[ -n "$RUN_ERROR" ]]; then
  if [[ "$RUN_ERROR" == *"LM Link"* ]]; then
    echo "run-opencode.sh: the connection to the model dropped mid-run. Check 'lms link status', then continue with --resume $SESSION_ID (finished steps are kept)." >&2
  else
    echo "run-opencode.sh: the run stopped on an error. Finished steps are kept; continue with --resume $SESSION_ID once the cause is fixed." >&2
  fi
  exit 6
fi
exit "$status"
