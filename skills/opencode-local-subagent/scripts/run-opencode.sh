#!/usr/bin/env bash
# run-opencode.sh: delegate a task to OpenCode running on whatever model LM Studio has loaded.
#
# Usage:
#   run-opencode.sh [-C dir] [--profile explore|review|build] [-l label] [-m model]
#                   [--allow-cmd "<cmd>"]... [--copy <path>]... [--keep] [--no-sandbox] [--no-web]
#                   [--resume <session-id>] [--fork] [-f <file>]... [-v variant] [--ssh <host>]
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
#      OCLS_STALL_TIMEOUT (stop a run with no output for this many seconds; default 600, 0 = off),
#      OCLS_AUTO_RESUME (how often to continue the session by itself after a connection drop; default 2, 0 = off).
# SSH route (bypasses LM Link): --ssh <host> or OCLS_SSH_HOST points OpenCode at the
#      LM Studio server on <host> through an ssh forward (OCLS_SSH_LOCAL_PORT default 11234, OCLS_SSH_REMOTE_PORT default 1234,
#      OCLS_SSH_WAIT seconds to wait for the tunnel, default 20). The tunnel stays up after the run and is
#      reused. Not combinable with LMSTUDIO_BASE_URL.
# Exit: 0 ok | 2 usage | 3 empty answer | 4 LM Studio/model problem | 5 build needs a git repo
#       | 6 run stopped on an error (e.g. LM Link dropped, after the automatic resumes) | otherwise opencode's own exit code.
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
SSH_HOST="${OCLS_SSH_HOST:-}"
SSH_LOCAL_PORT="${OCLS_SSH_LOCAL_PORT:-11234}"; SSH_REMOTE_PORT="${OCLS_SSH_REMOTE_PORT:-1234}"
SSH_WAIT="${OCLS_SSH_WAIT:-20}"
AUTO_RESUME="${OCLS_AUTO_RESUME:-2}"
VARIANT=""; RESUME=""; FORK=0; KEEP=0; NO_SANDBOX=0; NO_WEB=0
declare -a FILES=() ALLOW_CMDS=() COPIES=()

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }  # the whole header
die()  { echo "run-opencode.sh: $1" >&2; exit "${2:-2}"; }
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
    --ssh)         SSH_HOST="$2"; shift 2 ;;
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
if [[ -n "$SSH_HOST" ]]; then
  [[ -z "${LMSTUDIO_BASE_URL:-}" ]] || die "OCLS_SSH_HOST/--ssh and LMSTUDIO_BASE_URL are mutually exclusive"
  [[ "$SSH_HOST" != -* ]] || die "ssh host '$SSH_HOST' must not start with '-'"
  need ssh
  BASE="http://127.0.0.1:$SSH_LOCAL_PORT"
fi
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
  elif [[ -z "$PREV_RUN" ]]; then
    # delegated runs keep OpenCode's sessions in their own data dir, so a session unknown here can't be resumed
    die "no run with session $RESUME was found in $RUNS_ROOT (pruned, or not started by this wrapper). Start a new run."
  elif [[ "$USE_WT" == "true" ]]; then
    die "can't resume $RESUME as a build run: it started as a read-only run, with no worktree. Start a new build run."
  fi
  if [[ -n "$PREV_RUN" ]]; then
    [[ -d "$(cat "$PREV_RUN/run_in")" ]] || die "the session's directory $(cat "$PREV_RUN/run_in") no longer exists"
  fi
fi

# ------------------------------------------------------------------ LM Studio model detection
# Retried: a remote model disappears from this list while LM Link reconnects (~1.5–2 min), and the
# list can time out while the serving machine is busy (docs/findings.md S13/S14). If the local
# server doesn't answer at all, waiting won't help, so give up after the second try.
detect_models() { # sets reachable, LOADED, n_loaded
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
return 0
}

# SSH route: a local forward to the LM Studio server on $SSH_HOST. An answering port is reused as is.
# The tunnel (ssh -f) is deliberately left running after the run; later runs reuse it.
ssh_probe() { curl -sf --max-time 5 "$BASE/api/v0/models" >/dev/null; }
# Never dies or exits: the auto-resume loop needs to fall through to the report instead.
# Returns 0 = tunnel works, 1 = couldn't be established, 2 = local port held but LM Studio doesn't answer through it.
ensure_tunnel() {
  local i
  ssh_probe && return 0
  if (exec 3<>"/dev/tcp/127.0.0.1/$SSH_LOCAL_PORT") 2>/dev/null; then
    # something listens there but didn't answer as LM Studio: the server may just be busy, so retry before blaming another process
    for ((i = 0; i < SSH_WAIT; i++)); do ssh_probe && return 0; sleep 1; done
    return 2   # still no answer: ssh would fail to bind (or we'd talk to the wrong thing)
  fi
  ssh -f -N -L "127.0.0.1:$SSH_LOCAL_PORT:127.0.0.1:$SSH_REMOTE_PORT" -o ServerAliveInterval=15 -o ServerAliveCountMax=8 \
    -o ExitOnForwardFailure=yes -o BatchMode=yes "$SSH_HOST" \
    || (exec 3<>"/dev/tcp/127.0.0.1/$SSH_LOCAL_PORT") 2>/dev/null \
    || return 1   # ssh failed and nothing listens (host down, auth): polling won't help. If the port listens, a parallel run won the race to open the tunnel: wait for it.
  for ((i = 0; i < SSH_WAIT; i++)); do ssh_probe && return 0; sleep 1; done
  return 1
}
if [[ -n "$SSH_HOST" ]]; then
  tunnel_rc=0; ensure_tunnel || tunnel_rc=$?
  case $tunnel_rc in
    2) die "local port $SSH_LOCAL_PORT is in use by something else (not LM Studio). Set OCLS_SSH_LOCAL_PORT to a free port." 4 ;;
    1) die "cannot reach LM Studio on $SSH_HOST through an ssh forward (localhost:$SSH_LOCAL_PORT). Check that 'ssh $SSH_HOST' works without a password and that LM Studio's server is running there ('lms server start')." 4 ;;
  esac
fi
detect_models
[[ $reachable -eq 1 ]] \
  || die "cannot reach LM Studio at $BASE. Start LM Studio (or 'lms server start'); for remote models check that LM Link is enabled and the serving machine is online." 4
MODEL="${MODEL#lmstudio/}"

if [[ -z "$MODEL" ]]; then
  [[ "$n_loaded" -gt 0 || -z "$SSH_HOST" ]] || die "no model loaded in LM Studio on $SSH_HOST after $DETECT_TRIES tries. Load one there." 4
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
if [[ -n "$SSH_HOST" ]]; then DEVICE="ssh:$SSH_HOST"
elif command -v lms >/dev/null; then # best effort: DEVICE column of `lms ps`
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
  # carry over uncommitted work as it is on disk: everything that differs from HEAD (staged or not)
  # plus untracked, non-ignored files
  while IFS= read -r -d '' f; do
    if [[ -e "$REPO/$f" || -L "$REPO/$f" ]]; then mkdir -p "$WT/$(dirname "$f")"; cp -p "$REPO/$f" "$WT/$f"
    else rm -f "$WT/$f"; fi
  done < <(git -C "$REPO" diff -z --name-only --no-renames HEAD   # vs HEAD: staged and unstaged, incl. deletions/renames
           git -C "$REPO" ls-files -z -o --exclude-standard)      # untracked, not ignored
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
SANDBOX="off"; PREFIX=()   # PREFIX: the sandbox-exec words, also used for auto-resume attempts
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
  PREFIX=("${sb[@]}")
  args=("${PREFIX[@]}" "${args[@]}")
  SANDBOX="on"
fi

echo "RUN_DIR=$RUN_DIR"
WEB=on; [[ $NO_WEB -eq 1 ]] && WEB=off
echo "profile=$PROFILE model=$MODEL context=$CTX${DEVICE:+ device=$DEVICE} sandbox=$SANDBOX web=$WEB workdir=$WORKDIR${RESUME:+ resume=$RESUME}"
[[ "$USE_WT" == "true" ]] && echo "worktree=$RUN_IN branch=$BRANCH baseline=${BASELINE:0:12}"

printf '%s\n' "$RUN_IN" >"$RUN_DIR/run_in"   # where this session lives; --resume goes back here

set +e
mkdir -p "$OC_HOME"/{config,data,cache,state}
# Own process group (pgid = its pid), so a stall stop or an interrupt also ends what it started,
# e.g. a test runner. perl's setpgrp is the portable way; without perl only direct children go.
PGRP=0; command -v perl >/dev/null && PGRP=1
stop_run() {
  if [[ $PGRP -eq 1 ]]; then kill -TERM -- "-$oc_pid" 2>/dev/null; fi
  pkill -TERM -P "$oc_pid" 2>/dev/null; kill -TERM "$oc_pid" 2>/dev/null
}
run_once() { # $1 = attempt number; $2... = the command. Output goes to raw[.N].log / stderr[.N].log
  local n="$1" raw="$RUN_DIR/raw.log" err="$RUN_DIR/stderr.log"; shift
  if [[ $n -gt 1 ]]; then raw="$RUN_DIR/raw.$n.log"; err="$RUN_DIR/stderr.$n.log"; fi
  if [[ $PGRP -eq 1 ]]; then set -- perl -e 'setpgrp(0, 0); exec @ARGV or die "exec: $!"' "$@"; fi
  ( cd "$RUN_IN" && export OPENCODE_CONFIG_CONTENT="$CONFIG" OPENCODE_PERMISSION="$PERMISSION" \
      XDG_CONFIG_HOME="$OC_HOME/config" XDG_DATA_HOME="$OC_HOME/data" \
      XDG_CACHE_HOME="$OC_HOME/cache" XDG_STATE_HOME="$OC_HOME/state" && exec "$@" ) \
    >"$raw" 2>"$err" &
  oc_pid=$!
  trap 'stop_run' INT TERM   # in its own group it no longer gets the terminal's Ctrl-C, so pass it on
  STALLED=0
  if [[ "$STALL_TIMEOUT" -gt 0 ]]; then  # stop the run if OpenCode prints nothing for STALL_TIMEOUT s
    local last_size=-1 idle=0 size
    while kill -0 "$oc_pid" 2>/dev/null; do
      sleep 1
      size=$(wc -c <"$raw")
      if [[ "$size" -ne "$last_size" ]]; then last_size=$size; idle=0; else idle=$((idle + 1)); fi
      if [[ $idle -ge $STALL_TIMEOUT ]]; then
        STALLED=1
        stop_run
        break
      fi
    done
  fi
  wait "$oc_pid"
  status=$?
  while kill -0 "$oc_pid" 2>/dev/null; do wait "$oc_pid"; status=$?; done   # a trap interrupts wait early
  trap - INT TERM
  # events.jsonl = all attempts together; the run error is the last attempt's alone
  grep '^{' "$raw" >>"$RUN_DIR/events.jsonl"
  grep '^{' "$raw" >"$RUN_DIR/last_attempt.jsonl"   # the final message comes from this attempt alone
  grep '^{' "$raw" | run_error >"$RUN_DIR/error.txt"
  if [[ $STALLED -eq 1 ]]; then
    echo "no output from OpenCode for ${STALL_TIMEOUT}s; run stopped (stall timeout). If the model was just slow, raise OCLS_STALL_TIMEOUT." >"$RUN_DIR/error.txt"
  fi
}
# run-level error of the events on stdin; OpenCode wraps the provider's message as a JSON string
run_error() {
  jq -r 'select(.type=="error")
         | (.error.data.message // .error.message // .error.name // .message // "unknown error") as $m
         | ((try ($m | fromjson | .message) catch null) // $m)' 2>/dev/null | tail -1
}
is_drop() { # does error text $1 look like a lost connection to the model?
  case "$(tr '[:upper:]' '[:lower:]' <<<"$1")" in
    *"lm link"*|*peer_keepalive_timeout*|*connection_closed*|*"channel error"*|*econnreset*|*econnrefused*|\
    *"socket hang up"*|*"fetch failed"*|*"no models loaded"*) return 0 ;;
  esac
  return 1
}
CONT_PROMPT="The connection dropped while you were working. Continue the task from where you stopped and give the full answer in the required report format."
EV="$RUN_DIR/events.jsonl"; : >"$EV"
AUTO_RESUMED=0; attempt=1
while :; do
  if [[ $attempt -eq 1 ]]; then run_once 1 "${args[@]}"
  else
    PREV_ERR=$(cat "$RUN_DIR/error.txt")
    rargs=("${PREFIX[@]+"${PREFIX[@]}"}" opencode run --format json --auto --dir "$RUN_IN" --title "$LABEL" -m "lmstudio/$MODEL")
    [[ -n "$VARIANT" ]] && rargs+=(--variant "$VARIANT")
    run_once "$attempt" "${rargs[@]}" -s "$SID" -- "$CONT_PROMPT"
  fi
  # continue the same session after a connection drop, if one was captured
  SID=$(jq -r 'select(.sessionID) | .sessionID' "$EV" 2>/dev/null | head -1)
  [[ $AUTO_RESUMED -lt $AUTO_RESUME && $STALLED -eq 0 && -n "$SID" ]] && is_drop "$(cat "$RUN_DIR/error.txt")" || break
  warn "connection to the model dropped ($(cat "$RUN_DIR/error.txt")); waiting for it, then continuing session $SID (automatic resume $((AUTO_RESUMED + 1)) of $AUTO_RESUME)"
  if [[ -n "$SSH_HOST" ]]; then ensure_tunnel || { warn "ssh tunnel to $SSH_HOST is down"; break; }; fi
  detect_models
  if [[ $reachable -ne 1 || $n_loaded -eq 0 ]] || ! jq -e --arg m "$MODEL" 'map(select(.id==$m)) | length > 0' <<<"$LOADED" >/dev/null; then
    warn "model '$MODEL' did not come back; not resuming automatically"
    break
  fi
  AUTO_RESUMED=$((AUTO_RESUMED + 1)); attempt=$((attempt + 1))
done
set -e
# a resumed attempt that printed nothing must not leave the earlier attempt's text looking like an answer
if [[ $attempt -gt 1 && ! -s "$RUN_DIR/last_attempt.jsonl" && -z "$(cat "$RUN_DIR/error.txt")" ]]; then
  printf '%s (the resumed attempt produced no output)\n' "$PREV_ERR" >"$RUN_DIR/error.txt"
fi

# ------------------------------------------------------------------ parse events
jq -r 'select(.sessionID) | .sessionID' "$EV" 2>/dev/null | head -1 >"$RUN_DIR/session_id" || true
[[ -s "$RUN_DIR/session_id" ]] || echo unknown >"$RUN_DIR/session_id"
# final message = text parts after the last tool call of the last attempt (OpenCode >=1.19 puts text in .part.text)
jq -js '(map(.type=="tool_use") | rindex(true) // -1) as $t
        | to_entries | map(select(.key > $t and .value.type=="text") | (.value.part.text // .value.text // empty))
        | join("\n")' "$RUN_DIR/last_attempt.jsonl" >"$RUN_DIR/last_message.txt" 2>/dev/null || : >"$RUN_DIR/last_message.txt"
# blocked = refused by a permission rule; other tool errors (e.g. "File not found") are listed apart
TOOL_ERR='select(.type=="tool_use" and .part.state.status=="error")
  | (.part.state.error // "" | tostring | test("rule which prevents|rejected permission")) as $denied'
TOOL_LINE='"\(.part.tool): \(.part.state.input.command // .part.state.input.filePath // .part.state.input.url // (.part.state.input|tostring))"'
jq -r "$TOOL_ERR | select(\$denied) | $TOOL_LINE" "$EV" >"$RUN_DIR/blocked.txt" 2>/dev/null || : >"$RUN_DIR/blocked.txt"
jq -r "$TOOL_ERR | select(\$denied | not) | $TOOL_LINE + \" -> \" + (.part.state.error | tostring | .[0:120])" \
  "$EV" >"$RUN_DIR/tool_errors.txt" 2>/dev/null || : >"$RUN_DIR/tool_errors.txt"
jq -c 'select(.type=="error" or .type=="step_finish")' "$EV" 2>/dev/null | tail -1 >"$RUN_DIR/meta.json" || true
RUN_ERROR="$(cat "$RUN_DIR/error.txt")"
SESSION_ID="$(cat "$RUN_DIR/session_id")"

echo "exit_code=$status"
echo "session_id=$SESSION_ID"
[[ $AUTO_RESUMED -eq 0 ]] || echo "auto_resumed=$AUTO_RESUMED"

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
if [[ -s "$RUN_DIR/tool_errors.txt" ]]; then
  echo "--- tool calls that failed (not blocked) ---"
  cat "$RUN_DIR/tool_errors.txt"
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
  ERRLOG="$RUN_DIR/stderr.log"; [[ $attempt -eq 1 ]] || ERRLOG="$RUN_DIR/stderr.$attempt.log"
  tail -20 "$ERRLOG" 2>/dev/null || true
  if [[ $status -eq 0 ]]; then
    echo "run-opencode.sh: empty answer. A thinking model may have spent its budget reasoning, or the agent stopped after blocked tool calls. Check $EV; consider --resume $SESSION_ID with a nudge." >&2
    exit 3
  fi
fi

if [[ -n "$RUN_ERROR" ]]; then
  AR_NOTE=""; [[ $AUTO_RESUMED -eq 0 ]] || AR_NOTE=" (automatic resumes tried: $AUTO_RESUMED)"
  if [[ -n "$SSH_HOST" && $STALLED -eq 0 ]] && is_drop "$RUN_ERROR"; then
    echo "run-opencode.sh: the connection to $SSH_HOST dropped mid-run$AR_NOTE. Check that 'ssh $SSH_HOST' works and LM Studio's server is running there, then continue with --resume $SESSION_ID (finished steps are kept)." >&2
  elif [[ "$RUN_ERROR" == *"LM Link"* ]]; then
    echo "run-opencode.sh: the connection to the model dropped mid-run$AR_NOTE. Check 'lms link status', then continue with --resume $SESSION_ID (finished steps are kept)." >&2
  else
    echo "run-opencode.sh: the run stopped on an error$AR_NOTE. Finished steps are kept; continue with --resume $SESSION_ID once the cause is fixed." >&2
  fi
  exit 6
fi
exit "$status"
