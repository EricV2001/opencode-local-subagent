#!/usr/bin/env bash
# run-opencode.sh: delegate a task to OpenCode running on whatever model LM Studio has loaded.
#
# Usage:
#   run-opencode.sh [-C dir] [--profile explore|review|build] [-l label] [-m model]
#                   [--allow-cmd "<cmd>"]... [--allow-read <path>]... [--copy <path>]... [--keep]
#                   [--no-sandbox] [--no-web | --web]
#                   [--resume <session-id>] [--fork] [-f <file>]... [-v variant] [--ssh <host>]
#                   <prompt | ->
#   run-opencode.sh --cleanup <run-dir>     remove a build run's worktree + branch
#   run-opencode.sh --prune <days>          delete runs (and their worktrees) older than N days;
#                                           their sessions can't be resumed afterwards
#
# Profiles: explore (default, read-only, in place, no shell) | review (read-only; shell = git status/diff/log/show) |
#           build (edits allowed in a throwaway git worktree; deletions/renames blocked; shell = review's git
#           commands + git add/commit, mkdir, touch, and --allow-cmd).
# A guard plugin (plugin/guard) rejects any shell command that isn't plain words, and git commands with
# -c/-C/--git-dir/--output/--ext-diff/--textconv/--amend and the like. git itself runs with a hardened environment.
# On macOS (sandbox-exec) and Linux/WSL2 (bubblewrap) the run is sandboxed: writes only to the worktree, OpenCode's own dirs and temp;
# reads under $HOME only in the run's folder/worktree, OpenCode's dirs, the skill and what --allow-read adds
# (toolchains in $HOME: pyenv, nvm, ~/.local ...); secret files in the folder (.env, keys) and ~/.ssh can't be read.
# --no-web denies webfetch/websearch and, with the sandbox, pins the network to the LM endpoint
# (macOS only; net=pinned in the report; only when the endpoint is on localhost, e.g. the --ssh route), so nothing the
# agent reads can be sent out. Without a usable OS sandbox (Windows, Linux without bwrap) build refuses to run unless
# --no-sandbox is given, and explore/review run with the web off unless --web is given.
# Supports OpenCode 1.x and 2.x (auto-detected; each major version keeps its own data dir).
# The target folder's own opencode.json(c)/.opencode config and plugins are ignored (OPENCODE_DISABLE_PROJECT_CONFIG; OpenCode 1.x
# still loads a .opencode/plugin from it, so the OS sandbox also makes those unreadable; without a sandbox the report warns, S27).
# Prompt: one argument, or "-" to read it from stdin (preferred for multi-line briefs).
# --resume continues a session in the directory it started in (for build: the same worktree).
# Env: LMSTUDIO_BASE_URL (default http://127.0.0.1:1234), OPENCODE_LOCAL_MODEL,
#      OCLS_HOME (default ~/.cache/opencode-local-subagent), OPENCODE_ROUTER_RUNS,
#      OCLS_DETECT_TRIES/OCLS_DETECT_DELAY (wait for a model: default 18 x 10 s),
#      OCLS_STALL_TIMEOUT (stop a run with no output for this many seconds; default 600, 0 = off),
#      OCLS_AUTO_RESUME (how often to continue the session by itself after a connection drop; default 2, 0 = off).
#      The numeric settings (these and the OCLS_SSH_* ports/wait) must be plain digits, else exit 2.
# SSH route (bypasses LM Link): --ssh <host> or OCLS_SSH_HOST points OpenCode at the
#      LM Studio server on <host> through an ssh forward (OCLS_SSH_LOCAL_PORT default 11234, OCLS_SSH_REMOTE_PORT default 1234,
#      OCLS_SSH_WAIT seconds to wait for the tunnel, default 20). The tunnel stays up after the run and is
#      reused, but only if it is our own ssh to the same host (recorded in $OCLS_HOME/tunnel-<port>; the process
#      name is checked against OCLS_SSH_PROC_NAME, default ssh, a glob); a listener we didn't start is refused.
#      Not combinable with LMSTUDIO_BASE_URL.
# Exit: 0 ok | 2 usage | 3 empty answer | 4 LM Studio/model problem | 5 build needs a git repo
#       | 6 run stopped on an error (e.g. LM Link dropped, after the automatic resumes) | otherwise opencode's own exit code.
#
# Adapted from luckeyfaraday/delegate-to-opencode (MIT).
set -euo pipefail
umask 077   # run dirs, prompts, logs and worktrees are private to this user

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="$SCRIPT_DIR/../profiles"
BASE="${LMSTUDIO_BASE_URL:-http://127.0.0.1:1234}"; BASE="${BASE%/}"
OCLS_HOME="${OCLS_HOME:-$HOME/.cache/opencode-local-subagent}"
RUNS_ROOT="${OPENCODE_ROUTER_RUNS:-$OCLS_HOME/runs}"
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
VARIANT=""; RESUME=""; FORK=0; KEEP=0; NO_SANDBOX=0; NO_WEB=0; WEB_FLAG=0
declare -a FILES=() ALLOW_CMDS=() ALLOW_READS=() COPIES=()

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }  # the whole header
clean() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }   # no control characters except newline and tab
die()  { printf 'run-opencode.sh: %s\n' "$1" | clean >&2; exit "${2:-2}"; }
warn() { printf 'warning: %s\n' "$*" | clean >&2; }
uint() { # $1 = name of a variable holding a setting, $2 = the setting's public name: digits only (it ends up in arithmetic), normalised to base 10
  [[ "${!1}" =~ ^[0-9]{1,9}$ ]] || die "$2 must be a non-negative integer (digits only), got '${!1}'"
  printf -v "$1" '%d' "$((10#${!1}))"
}
real() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
need() { command -v "$1" >/dev/null || die "$1 not found${2:+ ($2)}"; }

# ------------------------------------------------------------------ maintenance commands
# The agent can edit anything in its worktree, including the `.git` pointer file and the worktree's own
# git dir. Before the wrapper runs git on a worktree it checks that what git would trust is still what
# was recorded at creation (worktree.json: gitdir, gitfile, commondir).
wt_tampered() { # $1 = worktree.json. Returns 0 and sets WT_WHY if the worktree can't be trusted
  local wt gd gf cdir br
  wt=$(jq -r .worktree "$1"); gd=$(jq -r '.gitdir // ""' "$1"); gf=$(jq -r '.gitfile // ""' "$1")
  cdir=$(jq -r '.commondir // ""' "$1"); br=$(jq -r .branch "$1"); WT_WHY=""
  if [[ -z "$gd" ]]; then WT_WHY="no git dir was recorded for it (made by an older version)"
  elif [[ ! -f "$wt/.git" || -L "$wt/.git" ]]; then WT_WHY="$wt/.git is no longer a regular file"
  elif [[ "$(cat "$wt/.git")" != "$gf" ]]; then WT_WHY="$wt/.git no longer holds the original gitdir line"
  elif [[ -L "$gd" || ! -d "$gd" ]]; then WT_WHY="the worktree's git dir is gone or replaced"
  elif [[ "$(cat "$gd/commondir" 2>/dev/null)" != "$cdir" ]]; then WT_WHY="the worktree's commondir file was changed"
  elif [[ -e "$gd/config.worktree" ]]; then WT_WHY="a config.worktree appeared in the worktree's git dir"
  elif [[ "$(cat "$gd/HEAD" 2>/dev/null)" != "ref: refs/heads/$br" ]]; then WT_WHY="the worktree's HEAD no longer points at $br"
  fi
  [[ -n "$WT_WHY" ]]
}
remove_worktree() { # $1 = worktree.json
  local repo wt br
  repo=$(jq -r .repo "$1"); wt=$(jq -r .worktree "$1"); br=$(jq -r .branch "$1")
  # rm -rf only as a fallback, and only for a path that really is one of our worktrees. A worktree whose
  # .git can't be trusted is not handed to git at all.
  { ! wt_tampered "$1" && git -C "$repo" worktree remove --force "$wt" 2>/dev/null; } \
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
    --allow-cmd)   # an empty or bare-wildcard rule would allow every command
                   [[ -n "${2//[[:space:]*]/}" && "$2" != *$'\n'* ]] || die "--allow-cmd needs a command, not an empty or '*' rule or one with a newline"
                   ALLOW_CMDS+=("$2"); shift 2 ;;
    --allow-read)  [[ "${2:-}" == /* && "$2" != *$'\n'* ]] || die "--allow-read takes an absolute path: ${2:-<missing>}"
                   ALLOW_READS+=("$2"); shift 2 ;;
    --copy)        c="${2%/}"
                   [[ -n "$c" && "$c" != /* && "/$c/" != *"/../"* ]] || die "--copy takes a path relative to the repo, without '..': $2"
                   COPIES+=("$c"); shift 2 ;;
    --keep)        KEEP=1; shift ;;
    --no-sandbox)  NO_SANDBOX=1; shift ;;
    --no-web)      NO_WEB=1; shift ;;
    --web)         WEB_FLAG=1; shift ;;
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
[[ $NO_WEB -eq 0 || $WEB_FLAG -eq 0 ]] || die "--web and --no-web contradict each other"
# numbers from the environment end up in arithmetic, where bash would run a crafted string as code
for v in DETECT_TRIES DETECT_DELAY STALL_TIMEOUT AUTO_RESUME SSH_LOCAL_PORT SSH_REMOTE_PORT SSH_WAIT; do uint "$v" "OCLS_$v"; done
[[ -f "$PROFILES_DIR/$PROFILE.json" && "$PROFILE" != common ]] || die "unknown profile: $PROFILE (explore|review|build)"
need jq; need git; need curl; need opencode "install: https://opencode.ai"
mkdir -p "$OCLS_HOME" "$RUNS_ROOT"   # under umask 077: private

# OpenCode's own config/data/cache/state for delegated runs, apart from the user's: the sandbox has to
# allow writes there, and code planted in the user's dirs (plugins, provider packages, tool binaries)
# would later run outside the sandbox. Kept per major version: 2.x must not read a 1.x data dir.
OC_RAW="$(opencode --version 2>/dev/null || true)"
OC_VERSION=$(printf '%s' "$OC_RAW" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
OC_MAJOR="${OC_VERSION%%.*}"
[[ "$OC_MAJOR" == "1" || "$OC_MAJOR" == "2" ]] \
  || die "unsupported OpenCode version '$OC_RAW' (supported: 1.x and 2.x)" 2
if [[ "$OC_MAJOR" == "2" ]]; then OC_HOME="$OCLS_HOME/opencode-v2"; else OC_HOME="$OCLS_HOME/opencode"; fi

if [[ -n "$SSH_HOST" ]]; then
  [[ -z "${LMSTUDIO_BASE_URL:-}" ]] || die "OCLS_SSH_HOST/--ssh and LMSTUDIO_BASE_URL are mutually exclusive"
  [[ "$SSH_HOST" != -* ]] || die "ssh host '$SSH_HOST' must not start with '-'"
  need ssh
  BASE="http://127.0.0.1:$SSH_LOCAL_PORT"
fi
# plain http to another machine sends the prompts and replies in the clear
BASE_WARN=""
if [[ "$BASE" == http://* ]]; then
  bh="${BASE#http://}"; bh="${bh%%/*}"; bh="${bh##*@}"
  if [[ "$bh" == \[* ]]; then bh="${bh%%]*}]"; else bh="${bh%%:*}"; fi
  case "$bh" in 127.*|localhost|"[::1]") ;; *)
    BASE_WARN="LMSTUDIO_BASE_URL is plain http to a non-loopback host ($bh): prompts and replies cross the network unencrypted" ;;   # shown once, in the report header
  esac
fi
[[ -d "$WORKDIR" ]] || die "working directory does not exist: $WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"
# the path is printed in the report: a newline or escape code in it could fake report lines
[[ "$WORKDIR" != *[[:cntrl:]]* ]] || die "working directory path contains control characters (newline, tab, escape): refusing"
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
    PREV_MAJOR=$(cat "$PREV_RUN/oc_major" 2>/dev/null || echo 1)   # runs predating this file were 1.x
    [[ "$PREV_MAJOR" == "$OC_MAJOR" ]] \
      || die "session $RESUME was started with OpenCode ${PREV_MAJOR}.x but OpenCode ${OC_MAJOR}.x is installed; start a new run" 2
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

# SSH route: a local forward to the LM Studio server on $SSH_HOST. An existing listener is reused only if
# it is the ssh this wrapper started for the same host (host + pid in $OCLS_HOME/tunnel-<port>, mode 600):
# anything else on that port would receive the prompts and the model's answers.
# The tunnel (ssh -f) is deliberately left running after the run; later runs reuse it.
ssh_probe() { curl -sf --max-time 5 "$BASE/api/v0/models" >/dev/null; }
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$SSH_LOCAL_PORT") 2>/dev/null; }
TUNNEL_REC="$OCLS_HOME/tunnel-$SSH_LOCAL_PORT"
tunnel_ours() { # is the listener on the local port the ssh we started for $SSH_HOST?
  local h="" p="" comm
  { IFS= read -r h && IFS= read -r p; } <"$TUNNEL_REC" 2>/dev/null || true
  [[ "$h" == "$SSH_HOST" && "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null || return 1
  comm=$(ps -p "$p" -o comm= 2>/dev/null | sed 's|.*/||')
  # shellcheck disable=SC2053  # OCLS_SSH_PROC_NAME is a glob on purpose (the tests' fake ssh is a python server)
  [[ "$comm" == ${OCLS_SSH_PROC_NAME:-ssh} ]]
}
# Never dies or exits: the auto-resume loop needs to fall through to the report instead.
# Returns 0 = tunnel works, 1 = couldn't be established, 2 = local port held by something that isn't our tunnel.
ensure_tunnel() {
  local i pid started=0
  if port_open; then
    tunnel_ours || return 2
    for ((i = 0; i < SSH_WAIT; i++)); do ssh_probe && return 0; sleep 1; done
    return 1   # our own ssh is up but LM Studio doesn't answer through it
  fi
  if ssh -f -N -L "127.0.0.1:$SSH_LOCAL_PORT:127.0.0.1:$SSH_REMOTE_PORT" -o ServerAliveInterval=15 -o ServerAliveCountMax=8 \
       -o ExitOnForwardFailure=yes -o BatchMode=yes -- "$SSH_HOST"; then
    started=1
    pid=$(lsof -nP -iTCP:"$SSH_LOCAL_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)
    [[ -z "$pid" ]] || printf '%s\n%s\n' "$SSH_HOST" "$pid" >"$TUNNEL_REC"
  elif ! port_open; then
    return 1   # ssh failed and nothing listens (host down, auth): polling won't help
  fi            # else a parallel run won the race to open the tunnel: wait for it
  for ((i = 0; i < SSH_WAIT; i++)); do ssh_probe && { [[ $started -eq 1 ]] || tunnel_ours; } && return 0; sleep 1; done
  [[ $started -eq 1 ]] || tunnel_ours || return 2
  return 1
}
if [[ -n "$SSH_HOST" ]]; then
  tunnel_rc=0; ensure_tunnel || tunnel_rc=$?
  case $tunnel_rc in
    2) die "local port $SSH_LOCAL_PORT is in use by something else (not an ssh forward to $SSH_HOST started by this wrapper). If it is a tunnel left by an older version of this wrapper, stop it (lsof -nP -iTCP:$SSH_LOCAL_PORT -sTCP:LISTEN shows the pid); otherwise set OCLS_SSH_LOCAL_PORT to a free port." 4 ;;
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
# from the API: used in arithmetic below, so nothing but digits may get through
[[ "$CTX" =~ ^[0-9]{1,12}$ ]] || die "LM Studio reported an unusable context length for the model; refusing to continue" 4
CTX=$((10#$CTX))
[[ "$CTX" -ge "$MIN_CTX" ]] || die "model context is $CTX tokens; OpenCode needs at least $MIN_CTX (its own prompt is ~8.5k). Increase the context length in LM Studio." 4
[[ "$CTX" -ge "$WARN_CTX" ]] || warn "context is only $CTX tokens; keep the task small"
jq -e '(.capabilities // []) | index("tool_use")' <<<"$MINFO" >/dev/null || warn "model does not advertise tool_use; tool calls may fail"

DEVICE=""
if [[ -n "$SSH_HOST" ]]; then DEVICE="ssh:$SSH_HOST"
elif command -v lms >/dev/null; then # best effort: DEVICE column of `lms ps`
  DEVICE=$(lms ps 2>/dev/null | awk -v m="$MODEL" -F'  +' '
    !c && /IDENTIFIER/ { for (i=1;i<=NF;i++) if ($i=="DEVICE") c=i; next }
    c && $1==m { print $c; exit }' | clean || true)
fi
SHOW_MODEL=$(clean <<<"$MODEL")

OUTPUT_LIMIT=$(( CTX / 4 < 32768 ? CTX / 4 : 32768 ))
# The guard plugin (plugin/guard) vets every shell command before OpenCode's own rules see it. It is loaded
# from the skill's own directory, which the sandbox keeps read-only. 1.x takes a file URL under "plugin",
# 2.x a plugin directory under "plugins".
GUARD_DIR="$(real "$SCRIPT_DIR/../plugin/guard")"
[[ -f "$GUARD_DIR/index.js" ]] || die "guard plugin missing: $GUARD_DIR/index.js"
GUARD_URL="file://$(jq -rn --arg p "$GUARD_DIR/index.js" '$p | split("/") | map(@uri) | join("/")')"
CONFIG=$(jq -nc --arg url "$BASE/v1" --arg m "$MODEL" --argjson ctx "$CTX" --argjson out "$OUTPUT_LIMIT" --argjson v2 "$([[ "$OC_MAJOR" == "2" ]] && echo true || echo false)" \
    --arg guard "$GUARD_DIR" --arg guardurl "$GUARD_URL" '
  { name: "LM Studio", models: { ($m): { name: $m, limit: { context: $ctx, output: $out } } } } as $p
  | { "$schema": "https://opencode.ai/config.json" }
  # v2 renamed provider->providers, npm->package ("aisdk:" prefix), options.baseURL->settings.baseURL.
  # With the v1 shape, v2 silently ignores the URL and uses LM Studio auto-discovered on localhost:1234.
  + if $v2 then { providers: { lmstudio: ($p + { package: "aisdk:@ai-sdk/openai-compatible", settings: { baseURL: $url } }) }, plugins: [$guard] }
    else { provider: { lmstudio: ($p + { npm: "@ai-sdk/openai-compatible", options: { baseURL: $url } }) }, plugin: [$guardurl] } end')

# ------------------------------------------------------------------ is there an OS sandbox?
# disabled: --no-sandbox | unsupported: no sandbox tool (Windows; no bwrap on Linux) | unusable: it exists but doesn't work
# | nested: we are already inside a sandbox (e.g. Claude Code's own; the outer one confines the run) | ok
# SB_KIND: sbx = macOS sandbox-exec, bwrap = Linux bubblewrap
SB_STATE="ok"; SB_WHY=""; SB_KIND="sbx"
[[ "$(uname -s)" != Linux ]] || SB_KIND="bwrap"
if [[ $NO_SANDBOX -eq 1 ]]; then SB_STATE="disabled"
elif [[ "$SB_KIND" == bwrap ]]; then
  if ! command -v bwrap >/dev/null; then SB_STATE="unsupported"; SB_WHY="bubblewrap (bwrap) is not installed; install it (e.g. apt install bubblewrap) for the Linux sandbox"
  elif ! bwrap --ro-bind / / --dev /dev --proc /proc true >/dev/null 2>&1; then
    SB_STATE="unusable"
    SB_WHY="bwrap does not work here (unprivileged user namespaces are probably blocked; on Ubuntu 23.10+ run 'sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0' or install an AppArmor profile for bwrap; in a container or another sandbox it cannot nest)"
  fi
elif ! command -v sandbox-exec >/dev/null; then SB_STATE="unsupported"; SB_WHY="sandbox-exec not available on this OS"
elif ! sb_err=$(sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>&1); then
  if [[ "$sb_err" == *"Operation not permitted"* ]]; then SB_STATE="nested"; SB_WHY="already inside a sandbox"
  else SB_STATE="unusable"; SB_WHY="sandbox-exec does not work here"; fi
fi
case "$SB_STATE" in
  unsupported|unusable)
    # build edits files and runs commands: without an OS sandbox only OpenCode's own rules would confine it
    [[ "$USE_WT" != "true" ]] || die "profile 'build' needs the OS sandbox, but $SB_WHY. Without it, edits and shell commands would be limited only by OpenCode's own permission rules. Pass --no-sandbox to run anyway, or use the explore/review profile." 2
    # explore/review: the web tools are the one way out for what the agent reads, so they are off unless asked for
    if [[ $WEB_FLAG -eq 0 && $NO_WEB -eq 0 ]]; then NO_WEB=1; WEB_DEFAULT_NOTE=" (web tools off by default without an OS sandbox; --web turns them on)"; fi ;;
esac

# ------------------------------------------------------------------ permissions
extra=$(printf '%s\n' "${ALLOW_CMDS[@]+"${ALLOW_CMDS[@]}"}" | jq -Rsc 'split("\n") | map(select(length>0))')
PERMISSION=$(jq -nc --slurpfile c "$PROFILES_DIR/common.json" --slurpfile p "$PROFILES_DIR/$PROFILE.json" --argjson extra "$extra" '
  ($c[0]) as $c | ($p[0]) as $p
  | ($p.bash_allow + $extra | map(., . + " *") | unique) as $allow
  | ($c.permission + $p.permission)
    # no allowed command (explore): the shell tool is denied outright, not just filtered by patterns
    + { bash: (if ($allow | length) == 0 then "deny"
               else ([{key:"*", value:"deny"}]
                     + ($allow | map({key:., value:"allow"}))
                     + ($c.bash_deny | map({key:., value:"deny"})) | from_entries) end) }')
if [[ $NO_WEB -eq 1 ]]; then PERMISSION=$(jq -c '.webfetch = "deny" | .websearch = "deny"' <<<"$PERMISSION"); fi

# ------------------------------------------------------------------ run dir + prompt
TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RUNS_ROOT/$TS-$LABEL-$$"
mkdir -p "$RUN_DIR"
if [[ "$PROMPT_ARG" == "-" ]]; then cat >"$RUN_DIR/prompt.md"; else printf '%s\n' "$PROMPT_ARG" >"$RUN_DIR/prompt.md"; fi
[[ -s "$RUN_DIR/prompt.md" ]] || die "empty prompt"
printf '%s\n' "$PERMISSION" >"$RUN_DIR/permission.json"
echo "$OC_MAJOR" >"$RUN_DIR/oc_major"

if [[ "$OC_MAJOR" == "2" ]]; then
  # v2 ignores OPENCODE_PERMISSION: rules go into the config as an ordered array, last match wins.
  # Its base policy allows everything unmentioned, so start with a catch-all deny. bash->shell, task->subagent; lsp/doom_loop are not v2 actions.
  PERMISSION_V2=$(jq -cn --argjson p "$PERMISSION" '
    [{action:"*", resource:"*", effect:"deny"}] + [
      $p | to_entries[]
      | select(.key as $k | ["lsp", "doom_loop"] | index($k) | not)
      | (.key | if . == "bash" then "shell" elif . == "task" then "subagent" else . end) as $a
      | if (.value | type) == "object"
        then .value | to_entries[] | {action:$a, resource:.key, effect:.value}
        else {action:$a, resource:"*", effect:.value}
        end]')
  CONFIG=$(jq -c --argjson perms "$PERMISSION_V2" '. + {permissions: $perms}' <<<"$CONFIG")
  printf '%s\n' "$CONFIG" >"$RUN_DIR/config.json"   # no secrets in it; useful for review
fi

# ------------------------------------------------------------------ worktree (build)
RUN_IN="$WORKDIR"
if [[ -n "$PREV_RUN" ]]; then
  RUN_IN="$(cat "$PREV_RUN/run_in")"
  [[ "$RUN_IN" == "$WORKDIR" || -n "$PREV_WT" ]] || warn "resuming in the session's own directory $RUN_IN (not $WORKDIR)"
fi
# git on a build worktree runs outside the sandbox, after an agent has been editing there. Nothing in the
# worktree decides what runs: the git dir is pinned to the recorded one, and hooks, fsmonitor, pager,
# external diff, ssh command and system config are off. (wt_tampered has vetted the pointers by then.)
wt_git() {
  env -u GIT_EXTERNAL_DIFF -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY -u GIT_COMMON_DIR GIT_CONFIG_NOSYSTEM=1 \
    git -C "$WT" -c user.name=opencode-local-subagent -c user.email=opencode-local-subagent@localhost -c commit.gpgsign=false \
      -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.pager=cat -c diff.external= -c core.sshCommand=false \
      --git-dir="$WT_GITDIR" --work-tree="$WT" "$@"
}
if [[ -n "$PREV_WT" ]]; then
  # continue in the session's worktree: same baseline, the edits made so far stay in place
  [[ ${#COPIES[@]} -eq 0 ]] || warn "--copy ignored when resuming (the worktree already exists)"
  wt_tampered "$PREV_RUN/worktree.json" && die "not resuming in $PREV_WT: $WT_WHY. Inspect it, then remove it with: $0 --cleanup $PREV_RUN" 6
  cp "$PREV_RUN/worktree.json" "$RUN_DIR/worktree.json"
  WT="$PREV_WT"; BRANCH=$(jq -r .branch "$RUN_DIR/worktree.json"); BASELINE=$(jq -r .baseline "$RUN_DIR/worktree.json")
  WT_GITDIR=$(jq -r .gitdir "$RUN_DIR/worktree.json")
elif [[ "$USE_WT" == "true" ]]; then
  REPO=$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null) || die "profile '$PROFILE' needs a git repository; $WORKDIR is not inside one" 5
  git -C "$REPO" rev-parse --verify -q HEAD >/dev/null || die "git repo has no commits yet; commit once before using '$PROFILE'" 5
  REL=$(git -C "$WORKDIR" rev-parse --show-prefix); REL="${REL%/}"
  for c in "${COPIES[@]+"${COPIES[@]}"}"; do   # the resolved source must stay inside the repo
    [[ -e "$REPO/$c" || -L "$REPO/$c" ]] || die "--copy path not found: $c"
    [[ "$(real "$(dirname "$REPO/$c")")/" == "$(real "$REPO")/"* ]] || die "--copy path resolves outside the repo: $c"
  done
  WT="$OCLS_HOME/worktrees/$(basename "$REPO")-$LABEL-$TS-$$"
  BRANCH="opencode/$LABEL-$TS-$$"
  mkdir -p "$OCLS_HOME/worktrees"
  git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" HEAD
  WT_GITDIR=$(git -C "$WT" rev-parse --absolute-git-dir)   # recorded: the agent can't redirect git later
  # carry over uncommitted work as it is on disk: everything that differs from HEAD (staged or not)
  # plus untracked, non-ignored files. Symlinks are copied as symlinks, never followed; the target is
  # removed first so a symlink already in the worktree isn't written through.
  while IFS= read -r -d '' f; do
    if [[ -e "$REPO/$f" || -L "$REPO/$f" ]]; then mkdir -p "$WT/$(dirname "$f")"; rm -f "$WT/$f"; cp -Pp "$REPO/$f" "$WT/$f"
    else rm -f "$WT/$f"; fi
  done < <(git -C "$REPO" diff -z --name-only --no-renames HEAD   # vs HEAD: staged and unstaged, incl. deletions/renames
           git -C "$REPO" ls-files -z -o --exclude-standard)      # untracked, not ignored
  for c in "${COPIES[@]+"${COPIES[@]}"}"; do   # opt-in gitignored needs; copied as they are (symlinks stay symlinks)
    mkdir -p "$WT/$(dirname "$c")"
    [[ "$(real "$WT/$(dirname "$c")")/" == "$(real "$WT")/"* ]] || die "--copy target resolves outside the worktree: $c"
    cp -RP "$REPO/$c" "$WT/$c"
  done
  wt_git add -A
  wt_git commit -q --allow-empty --no-verify -m "opencode baseline (user's working state)"
  BASELINE=$(wt_git rev-parse HEAD)
  jq -n --arg repo "$REPO" --arg wt "$WT" --arg br "$BRANCH" --arg base "$BASELINE" --arg gd "$WT_GITDIR" \
        --arg gf "$(cat "$WT/.git")" --arg cd "$(cat "$WT_GITDIR/commondir")" \
    '{repo:$repo, worktree:$wt, branch:$br, baseline:$base, gitdir:$gd, gitfile:$gf, commondir:$cd}' >"$RUN_DIR/worktree.json"
  RUN_IN="$WT${REL:+/$REL}"
fi

# ------------------------------------------------------------------ run opencode
if [[ "$OC_MAJOR" == "2" ]]; then
  # v2 run has no --dir (it uses the cwd, which run_once sets) and no --variant; the variant goes into the model.
  args=(opencode run --format json --auto --standalone --title "$LABEL")
  if [[ -n "$VARIANT" ]]; then args+=(-m "lmstudio/$MODEL#$VARIANT"); else args+=(-m "lmstudio/$MODEL"); fi
else
  args=(opencode run --format json --auto --dir "$RUN_IN" --title "$LABEL" -m "lmstudio/$MODEL")
  [[ -n "$VARIANT" ]] && args+=(--variant "$VARIANT")
fi
[[ -n "$RESUME" ]]  && args+=(-s "$RESUME")
[[ $FORK -eq 1 ]]   && args+=(--fork)
[[ ${#FILES[@]} -gt 0 ]] && args+=("${FILES[@]}")
args+=(-- "$(cat "$RUN_DIR/prompt.md")")   # -- so a prompt starting with "-" isn't read as a flag

# ------------------------------------------------------------------ OS sandbox (macOS sandbox-exec, Linux bubblewrap)
# Writes are limited to: the worktree and the parts of the repo's .git that a commit on its branch
# needs, OpenCode's dirs for delegated runs ($OC_HOME), and temp dirs; never the skill's own dir (guard plugin).
# Reads under $HOME are limited to: the run's folder/worktree and its git dirs, everything writable above,
# the skill dir, the opencode binary's dir and --allow-read paths; secret files in the folder and ~/.ssh are
# denied on top. With --no-web the network is pinned to the LM endpoint when that is on localhost.
# Paths are passed as -D params, so no SBPL quoting issues.
# OpenCode 1.x reads .opencode/ and opencode.json(c) from the folder and from its parents up to the git root; with
# OPENCODE_DISABLE_PROJECT_CONFIG=1 it still loads a .opencode/plugin/*.js that exports an object with setup()/server()
# (docs/findings.md S27). So the sandbox makes .opencode unreadable in the folder, the workdir and up to the git root.
GTOP=$(git -C "$RUN_IN" rev-parse --show-toplevel 2>/dev/null || true); [[ -z "$GTOP" ]] || GTOP="$(real "$GTOP")"
proj_cfg_dirs() { # prints the directories whose own .opencode/opencode.json(c) OpenCode could pick up (folder, workdir, parents up to the git root)
  local d seen=""
  for d in "$(real "$RUN_IN")" "$(real "$WORKDIR")"; do
    while :; do
      [[ "$seen" == *"|$d|"* ]] || { seen+="|$d|"; printf '%s\n' "$d"; }
      [[ -n "$GTOP" && "$d" != "$GTOP" && "$d" == "$GTOP"/* ]] || break
      d="$(dirname "$d")"
    done
  done
}
SANDBOX="off"; PREFIX=(); NET="open"   # PREFIX: the sandbox-exec words, also used for auto-resume attempts
WT_HERE=0; [[ "$USE_WT" == "true" || -n "$PREV_WT" ]] && WT_HERE=1
case "$SB_STATE" in
  disabled)    warn "OS sandbox disabled (--no-sandbox); relying on permission rules only" ;;
  nested)      warn "cannot apply a sandbox here (already inside one?); relying on the outer sandbox + permission rules" ;;
  unsupported) warn "$SB_WHY; relying on permission rules only${WEB_DEFAULT_NOTE:-}" ;;
  unusable)    warn "$SB_WHY; relying on permission rules only${WEB_DEFAULT_NOTE:-}" ;;
  ok)
  mkdir -p "$OC_HOME"
  SB_RO=(); SB_READ=()
  SB_DIRS=("$(real "${TMPDIR:-/tmp}")" /tmp /var/tmp /private/tmp /private/var/tmp "$(real "$OC_HOME")")   # (the ones that don't exist are skipped)
  if [[ "$USE_WT" == "true" ]]; then
    # Not the whole shared .git: hooks/ and config there would later run or apply outside the
    # sandbox. A commit on the worktree's branch only needs these (docs/findings.md S15).
    # From the recorded git dir, not from $WT/.git (wt_tampered has vetted it).
    GD=$(real "$WT_GITDIR"); GC=$(real "$GD/$(cat "$GD/commondir")")
    SB_DIRS+=("$(real "$WT")" "$GD" "$GC/objects" "$GC/refs/heads/opencode" "$GC/logs/refs/heads/opencode")
    # ...but the pointers git trusts stay read-only inside the writable worktree and its git dir
    SB_RO=("$(real "$WT")/.git" "$GD/commondir" "$GD/config.worktree" "$GD/config" "$GD/HEAD")   # (git ignores $GD/config today; kept read-only anyway)
    SB_READ+=("$GC")   # git reads the shared config, packed refs and objects of the repo
  elif [[ $WT_HERE -eq 1 ]]; then
    SB_READ+=("$(real "$WT")")
  else
    # in place: the repo's git dir may sit above the folder (a subdirectory of a repo)
    while IFS= read -r g; do [[ -z "$g" ]] || SB_READ+=("$(real "$g")"); done \
      < <(git -C "$RUN_IN" rev-parse --path-format=absolute --absolute-git-dir --git-common-dir 2>/dev/null || true)
    SB_READ+=("$(real "$WORKDIR")")
  fi
  SB_READ+=("${SB_DIRS[@]}" "$(real "$RUN_IN")" "$GUARD_DIR")   # a build run doesn't get the original repo, only its worktree
  OC_BIN=$(command -v opencode)   # the binary itself may live under $HOME (~/.opencode/bin, nvm, ...)
  SB_READ+=("$(real "$(dirname "$OC_BIN")")")
  OC_REAL=$(realpath "$OC_BIN" 2>/dev/null || readlink -f "$OC_BIN" 2>/dev/null || true)
  [[ -z "$OC_REAL" ]] || SB_READ+=("$(real "$(dirname "$OC_REAL")")")
  # every hop of a symlink chain (npm's .bin/opencode -> ../pkg/bin/opencode.exe) must stay resolvable inside the sandbox
  oc_hop="$OC_BIN"
  for _ in 1 2 3 4 5 6 7 8; do
    [[ -L "$oc_hop" ]] || break
    oc_to=$(readlink "$oc_hop") || break
    [[ "$oc_to" == /* ]] || oc_to="$(dirname "$oc_hop")/$oc_to"
    oc_hop="$oc_to"; SB_READ+=("$(real "$(dirname "$oc_hop")")")
  done
  for r in "${ALLOW_READS[@]+"${ALLOW_READS[@]}"}"; do SB_READ+=("$(real "$r")"); done
  # toolchains that commonly live under $HOME (installed code, not secrets), so test commands keep working
  for r in Library/Python .pyenv .nvm .volta .bun .deno .cargo .rustup go .rbenv .sdkman .local/bin .local/lib .local/share/uv; do
    [[ -d "$HOME/$r" ]] && SB_READ+=("$(real "$HOME/$r")")
  done
  if [[ "$SB_KIND" == bwrap ]]; then
    # Later mounts win. Home is hidden, then what was listed comes back (read-only, then writable), then the
    # read-only pointers and the guard dir go on top again, then the secrets in the folder are masked.
    # Network stays shared (the LM endpoint is on the host's localhost), so there is no pinning on Linux.
    # Secrets are masked as they are at the start; ones the agent creates later are not (it can't create the user's).
    sb=(bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs "$(real "$HOME")" --die-with-parent --unshare-pid)
    for p in "${SB_READ[@]}"; do [[ "$p" == "$(real "$HOME")"/* && -e "$p" ]] && sb+=(--ro-bind "$p" "$p"); done
    for p in "${SB_DIRS[@]}"; do [[ -d "$p" ]] && sb+=(--bind "$p" "$p"); done
    for p in "${SB_RO[@]+"${SB_RO[@]}"}" "$GUARD_DIR"; do [[ -e "$p" ]] && sb+=(--ro-bind "$p" "$p"); done
    mask_roots=("$(real "$RUN_IN")"); [[ "$(real "$WORKDIR")" == "${mask_roots[0]}" ]] || mask_roots+=("$(real "$WORKDIR")")
    for r in "${mask_roots[@]}"; do
      [[ -d "$r" ]] || continue
      while IFS= read -r -d '' p; do
        if [[ -d "$p" ]]; then sb+=(--tmpfs "$p"); else sb+=(--ro-bind /dev/null "$p"); fi
      done < <(find "$r" -maxdepth 8 -name .git -prune -o \( -type f -o -type d \) \
        \( -iname '.env' -o \( -iname '.env.*' ! -name '.env.example' \) -o -iname '*.pem' -o -iname '*.key' -o -iname '*.p12' -o -iname '*.pfx' \
           -o -iname 'id_rsa*' -o -iname 'id_ed25519*' -o -iname 'id_ecdsa*' \
           -o -name .opencode \) -print0 -prune 2>/dev/null)
    done
    # OpenCode's own project config dir (.opencode): the folder's masks come from the find above; the parents up to
    # the git root (OpenCode looks there too) are checked by name.
    while IFS= read -r p; do
      for r in "${mask_roots[@]}"; do [[ "$p" != "$r" ]] || continue 2; done   # (the folders themselves are covered by the find)
      [[ ! -d "$p/.opencode" ]] || sb+=(--tmpfs "$p/.opencode")
    done < <(proj_cfg_dirs)
    sb+=(--)
  else
    {
      echo '(version 1)'
      echo '(allow default)'
      echo '(deny file-write*)'
      echo '(allow file-write* (subpath "/dev"))'
      for i in "${!SB_DIRS[@]}"; do echo "(allow file-write* (subpath (param \"P$i\")))"; done
      for i in "${!SB_RO[@]}"; do echo "(deny file-write* (literal (param \"W$i\")))"; done
      echo '(deny file-write* (subpath (param "GUARD")))'
      # Reads: nothing under $HOME except what was listed (the last matching rule wins, so the allows follow the deny).
      echo '(deny file-read-data (subpath (param "HOME")))'
      for i in "${!SB_READ[@]}"; do echo "(allow file-read-data (subpath (param \"A$i\")))"; done
      # (file-read-data throughout: a rule on a more specific operation beats a later file-read* rule, so the
      # denies below must name the same operation as the allows above.)
      # secrets in the folder can't be read by any tool or command (the permission rules only see paths
      # and command strings; content search like grep -r would still read them). Only inside the folder:
      # system .pem files (TLS roots) must stay readable.
      for r in R0 R1; do
        # any case (a file can really be named .ENV), and everything inside a folder named .env
        echo "(deny file-read-data (require-all (subpath (param \"$r\")) (regex #\"\\.[Ee][Nn][Vv](\\.[^/]*)?(/|\$)\" #\"\\.([Pp][Ee][Mm]|[Kk][Ee][Yy]|[Pp]12|[Pp][Ff][Xx])\$\" #\"/[Ii][Dd]_([Rr][Ss][Aa]|[Ee][Dd]25519|[Ee][Cc][Dd][Ss][Aa])[^/]*\$\")))"
      done
      for r in R0 R1; do   # after all the denies
        echo "(allow file-read-data (require-all (subpath (param \"$r\")) (regex #\"/\\.env\\.example\$\")))"
      done
      # A .opencode path component in the folder: OpenCode 1.x would load a .opencode/plugin from it even with
      # OPENCODE_DISABLE_PROJECT_CONFIG=1 (S27). Scoped to the folder, so OpenCode's own dirs under $OC_HOME and the
      # user's ~/.config/opencode stay readable. R2 = the git root above an in-place subfolder.
      # (Not opencode.json(c): the flag already ignores it, and an unreadable one makes 1.19.5 fail with "Unexpected server error".)
      for r in R0 R1 R2; do
        echo "(deny file-read-data (require-all (subpath (param \"$r\")) (regex #\"/\\.[Oo][Pp][Ee][Nn][Cc][Oo][Dd][Ee](/|\$)\")))"
      done
      echo '(deny file-read-data (subpath (param "SSHDIR")))'
      if [[ $NO_WEB -eq 1 ]]; then
        if [[ "$BASE" =~ ^(https?)://([^/@]*@)?(127\.[0-9.]+|localhost|\[::1\])(:([0-9]{1,5}))?(/|$) ]]; then
          NET_PORT="${BASH_REMATCH[5]}"
          if [[ -z "$NET_PORT" ]]; then NET_PORT=80; [[ "${BASH_REMATCH[1]}" != https ]] || NET_PORT=443; fi
          echo '(deny network*)'
          echo "(allow network-outbound (remote ip \"localhost:$NET_PORT\"))"
          NET="pinned"
          if [[ "$OC_MAJOR" == "2" ]]; then
            # 2.x starts a standalone server and talks to it over loopback (docs/findings.md S24): any local port, nothing off this machine
            echo '(allow network-bind (local ip "localhost:*"))'
            echo '(allow network-inbound (local ip "localhost:*"))'
            echo '(allow network-outbound (remote ip "localhost:*"))'
            NET="loopback"
          fi
        else
          warn "network not pinned: the LM endpoint is not on localhost; use the SSH route (--ssh) to pin it"
        fi
      fi
    } >"$RUN_DIR/sandbox.sb"
    sb=(sandbox-exec -f "$RUN_DIR/sandbox.sb")
    for i in "${!SB_DIRS[@]}"; do sb+=(-D "P$i=${SB_DIRS[$i]}"); done
    for i in "${!SB_RO[@]}"; do sb+=(-D "W$i=${SB_RO[$i]}"); done
    for i in "${!SB_READ[@]}"; do sb+=(-D "A$i=${SB_READ[$i]}"); done
    sb+=(-D "R0=$(real "$RUN_IN")" -D "R1=$(real "$WORKDIR")" -D "R2=${GTOP:-$(real "$RUN_IN")}" -D "SSHDIR=$(real "$HOME/.ssh")" -D "HOME=$(real "$HOME")" -D "GUARD=$GUARD_DIR")
  fi
  PREFIX=("${sb[@]}")
  args=("${PREFIX[@]}" "${args[@]}")
  SANDBOX="on" ;;
esac

echo "RUN_DIR=$RUN_DIR"
WEB=on; [[ $NO_WEB -eq 1 ]] && WEB=off
[[ -z "$BASE_WARN" ]] || echo "warning: $BASE_WARN"
# no OS sandbox: OpenCode 1.x may still load the folder's own plugins/config (S27); say so, don't refuse
if [[ "$SANDBOX" != on && "$OC_MAJOR" == "1" ]]; then
  PROJ_FOUND=""
  while IFS= read -r d; do
    for n in .opencode opencode.json opencode.jsonc; do
      [[ -e "$d/$n" ]] && { PROJ_FOUND="$d/$n"; break 2; }
    done
  done < <(proj_cfg_dirs)
  [[ -z "$PROJ_FOUND" ]] || echo "warning: $PROJ_FOUND exists and there is no OS sandbox: on OpenCode 1.x the folder's own OpenCode plugins and config may load and run code (OPENCODE_DISABLE_PROJECT_CONFIG does not stop a .opencode/plugin); use a sandbox or a copy without it"
fi
echo "profile=$PROFILE model=$SHOW_MODEL context=$CTX${DEVICE:+ device=$DEVICE} sandbox=$SANDBOX web=$WEB net=$NET opencode=$OC_VERSION workdir=$WORKDIR${RESUME:+ resume=$RESUME}"
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
# git run by the agent's shell: nothing in the repo's or the user's git config may run a program or sign
# (docs/findings.md S24). Planted per-driver settings (diff.<x>.textconv, filter.<x>.*) can't all be listed;
# those need a planted .git/config, which the sandbox prevents in a build worktree and which an in-place
# explore/review run trusts like the user's own repo.
agent_git_env() {
  unset GIT_EXTERNAL_DIFF GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_SSH GIT_SSH_COMMAND GIT_ASKPASS
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat GIT_TERMINAL_PROMPT=0 \
         GIT_NO_REPLACE_OBJECTS=1 GIT_ATTR_NOSYSTEM=1 \
         GIT_AUTHOR_NAME=opencode-local-subagent GIT_AUTHOR_EMAIL=opencode-local-subagent@localhost \
         GIT_COMMITTER_NAME=opencode-local-subagent GIT_COMMITTER_EMAIL=opencode-local-subagent@localhost \
         GIT_CONFIG_COUNT=7 \
         GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false \
         GIT_CONFIG_KEY_1=core.pager GIT_CONFIG_VALUE_1=cat \
         GIT_CONFIG_KEY_2=diff.external GIT_CONFIG_VALUE_2='' \
         GIT_CONFIG_KEY_3=gpg.program GIT_CONFIG_VALUE_3=/usr/bin/false \
         GIT_CONFIG_KEY_4=core.hooksPath GIT_CONFIG_VALUE_4=/dev/null \
         GIT_CONFIG_KEY_5=commit.gpgsign GIT_CONFIG_VALUE_5=false \
         GIT_CONFIG_KEY_6=core.sshCommand GIT_CONFIG_VALUE_6=false
}
run_once() { # $1 = attempt number; $2... = the command. Output goes to raw[.N].log / stderr[.N].log
  local n="$1" raw="$RUN_DIR/raw.log" err="$RUN_DIR/stderr.log"; shift
  if [[ $n -gt 1 ]]; then raw="$RUN_DIR/raw.$n.log"; err="$RUN_DIR/stderr.$n.log"; fi
  if [[ $PGRP -eq 1 ]]; then set -- perl -e 'setpgrp(0, 0); exec @ARGV or die "exec: $!"' "$@"; fi
  # OPENCODE_DISABLE_PROJECT_CONFIG: a hostile opencode.json/.opencode in the folder must not override
  # these rules or load plugins (honoured by 1.x and 2.x). </dev/null: 1.x run waits for stdin EOF on a pipe.
  # PYTHONDONTWRITEBYTECODE: the agent's test runs must not leave __pycache__/*.pyc files that end up in the worktree diff.
  ( cd "$RUN_IN" && agent_git_env && export OPENCODE_CONFIG_CONTENT="$CONFIG" OPENCODE_DISABLE_PROJECT_CONFIG=1 \
      XDG_CONFIG_HOME="$OC_HOME/config" XDG_DATA_HOME="$OC_HOME/data" \
      XDG_CACHE_HOME="$OC_HOME/cache" XDG_STATE_HOME="$OC_HOME/state" \
      PYTHONDONTWRITEBYTECODE=1 \
      && { [[ "$OC_MAJOR" == "2" ]] || export OPENCODE_PERMISSION="$PERMISSION"; } \
      && exec "$@" ) </dev/null >"$raw" 2>"$err" &
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
  # nothing the agent started (a test runner's daemon, a background job) may outlive the run and keep
  # changing the worktree while the wrapper checks and commits it
  if [[ $PGRP -eq 1 ]]; then kill -KILL -- "-$oc_pid" 2>/dev/null || true; fi
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
    if [[ "$OC_MAJOR" == "2" ]]; then
      rargs=("${PREFIX[@]+"${PREFIX[@]}"}" opencode run --format json --auto --standalone --title "$LABEL")
      if [[ -n "$VARIANT" ]]; then rargs+=(-m "lmstudio/$MODEL#$VARIANT"); else rargs+=(-m "lmstudio/$MODEL"); fi
    else
      rargs=("${PREFIX[@]+"${PREFIX[@]}"}" opencode run --format json --auto --dir "$RUN_IN" --title "$LABEL" -m "lmstudio/$MODEL")
      [[ -n "$VARIANT" ]] && rargs+=(--variant "$VARIANT")
    fi
    run_once "$attempt" "${rargs[@]}" -s "$SID" -- "$CONT_PROMPT"
  fi
  # continue the same session after a connection drop, if one was captured
  SID=$(jq -r 'select(.sessionID) | .sessionID' "$EV" 2>/dev/null | head -1 | tr -cd 'A-Za-z0-9_.-')
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
jq -r 'select(.sessionID) | .sessionID' "$EV" 2>/dev/null | head -1 | tr -cd 'A-Za-z0-9_.-' >"$RUN_DIR/session_id" || true
[[ -s "$RUN_DIR/session_id" ]] || echo unknown >"$RUN_DIR/session_id"
# final message = text parts after the last tool call of the last attempt (OpenCode >=1.19 puts text in .part.text)
jq -js '(map(.type=="tool_use") | rindex(true) // -1) as $t
        | to_entries | map(select(.key > $t and .value.type=="text") | (.value.part.text // .value.text // empty))
        | join("\n")' "$RUN_DIR/last_attempt.jsonl" >"$RUN_DIR/last_message.txt" 2>/dev/null || : >"$RUN_DIR/last_message.txt"
# blocked = refused by a permission rule; other tool errors (e.g. "File not found") are listed apart
# v1 denial wording: "rule which prevents" / "rejected permission"; v2: "Permission denied: <tool>"
# the guard plugin throws "blocked by the opencode-local-subagent guard: ..."
TOOL_ERR='select(.type=="tool_use" and .part.state.status=="error")
  | (.part.state.error // "" | tostring | test("rule which prevents|rejected permission|Permission denied|blocked by the opencode-local-subagent guard")) as $denied'
# v1 names the path input filePath, v2 uses path
TOOL_LINE='"\(.part.tool): \(.part.state.input.command // .part.state.input.filePath // .part.state.input.path // .part.state.input.url // (.part.state.input|tostring))"'
jq -r "$TOOL_ERR | select(\$denied) | $TOOL_LINE" "$EV" >"$RUN_DIR/blocked.txt" 2>/dev/null || : >"$RUN_DIR/blocked.txt"
jq -r "$TOOL_ERR | select(\$denied | not) | $TOOL_LINE + \" -> \" + (.part.state.error | tostring | .[0:120])" \
  "$EV" >"$RUN_DIR/tool_errors.txt" 2>/dev/null || : >"$RUN_DIR/tool_errors.txt"
jq -c 'select(.type=="error" or .type=="step_finish")' "$EV" 2>/dev/null | tail -1 >"$RUN_DIR/meta.json" || true
RUN_ERROR="$(cat "$RUN_DIR/error.txt")"
SESSION_ID="$(cat "$RUN_DIR/session_id")"

echo "exit_code=$status"
echo "session_id=$SESSION_ID"
[[ $AUTO_RESUMED -eq 0 ]] || echo "auto_resumed=$AUTO_RESUMED"

# ------------------------------------------------------------------ report
# Everything the model or the API produced (final message, tool lines, errors, stderr) is untrusted text
# for whoever reads this report: control characters are stripped, sizes capped, tool lines are prefixed
# with "  | " and the final message sits between markers carrying a random nonce. The wrapper's own
# status lines come before and after it.
NONCE=$(LC_ALL=C od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
emit() { # $1 = file, $2 = max bytes, $3 = "prefix" to prefix every line with "  | ". Clean, capped, with a note if cut.
  local n; n=$(wc -c <"$1" | tr -d ' ')
  if [[ "${3:-}" == prefix ]]; then head -c "$2" "$1" | clean | sed 's/^/  | /'; else head -c "$2" "$1" | clean; echo; fi
  [[ "$n" -le "$2" ]] || echo "  [truncated $((n - $2)) bytes; full text in $1]"
}
WT_REFUSED=0; CHANGE_N="n/a"; DEL_N="n/a"
if [[ "$USE_WT" == "true" ]]; then
  echo "--- changes (baseline..$BRANCH) ---"
  if wt_tampered "$RUN_DIR/worktree.json"; then
    # the agent changed what git in the worktree would trust: run no git there, keep it for inspection
    WT_REFUSED=1; CHANGE_N="unknown"; DEL_N="unknown"
    echo "!! WORKTREE NOT PROCESSED: $WT_WHY. No git command was run there; the worktree is kept for inspection (remove it with: $0 --cleanup $RUN_DIR)"
  else
    wt_git add -A
    wt_git diff --cached --quiet --no-ext-diff || wt_git commit -q --no-verify -m "opencode result: $LABEL"
    CHANGES=$(wt_git diff --name-status --no-ext-diff --no-textconv "$BASELINE"..HEAD | clean)
    CHANGE_N=$(printf '%s\n' "$CHANGES" | grep -c . || true)
    DEL_N=$(awk -F'\t' '$1=="D"{n++} END{print n+0}' <<<"$CHANGES")
    if [[ -z "$CHANGES" ]]; then
      # only a finished run's worktree goes; after an error or an empty answer it stays for --resume
      if [[ $KEEP -eq 1 ]]; then echo "no changes (worktree kept: --keep)"
      elif [[ $status -ne 0 || -n "$RUN_ERROR" || ! -s "$RUN_DIR/last_message.txt" ]]; then
        echo "no changes yet; worktree kept so the session can be resumed (remove it with: $0 --cleanup $RUN_DIR)"
      else remove_worktree "$RUN_DIR/worktree.json"; echo "no changes; worktree and branch removed"; fi
    else
      awk -F'\t' '$1=="D"{print "!! DELETED: " $2}' <<<"$CHANGES"
      printf '%s\n' "$CHANGES"
      wt_git diff --shortstat --no-ext-diff "$BASELINE"..HEAD
      echo "review: git -C $WT diff $BASELINE..HEAD"
      echo "cleanup after merging: $0 --cleanup $RUN_DIR"
    fi
  fi
fi

if [[ -s "$RUN_DIR/blocked.txt" ]]; then
  echo "--- blocked tool calls ---"
  emit "$RUN_DIR/blocked.txt" 4000 prefix
fi
if [[ -s "$RUN_DIR/tool_errors.txt" ]]; then
  echo "--- tool calls that failed (not blocked) ---"
  emit "$RUN_DIR/tool_errors.txt" 4000 prefix
fi

if [[ -n "$RUN_ERROR" ]]; then
  echo "--- run error ---"
  emit "$RUN_DIR/error.txt" 2000 prefix
fi

# the code the wrapper will exit with
EXIT_RC=$status; EMPTY_ANSWER=0
if [[ -n "$RUN_ERROR" || $WT_REFUSED -eq 1 ]]; then EXIT_RC=6
elif [[ ! -s "$RUN_DIR/last_message.txt" && $status -eq 0 ]]; then EXIT_RC=3; EMPTY_ANSWER=1; fi

if [[ -s "$RUN_DIR/last_message.txt" ]]; then
  echo "--- final message (untrusted model output, nonce $NONCE) ---"
  emit "$RUN_DIR/last_message.txt" 20000
  echo "--- end final message $NONCE ---"
elif [[ -z "$RUN_ERROR" ]]; then
  echo "--- no final message; stderr tail ---"
  ERRLOG="$RUN_DIR/stderr.log"; [[ $attempt -eq 1 ]] || ERRLOG="$RUN_DIR/stderr.$attempt.log"
  tail -20 "$ERRLOG" 2>/dev/null >"$RUN_DIR/stderr.tail.txt" || : >"$RUN_DIR/stderr.tail.txt"
  emit "$RUN_DIR/stderr.tail.txt" 4000 prefix
fi
echo "status: exit_code=$EXIT_RC opencode_exit=$status changes=$CHANGE_N deleted=$DEL_N session_id=$SESSION_ID (trust the status lines, not the text above)"

if [[ $EMPTY_ANSWER -eq 1 ]]; then
  echo "run-opencode.sh: empty answer. A thinking model may have spent its budget reasoning, or the agent stopped after blocked tool calls. Check $EV; consider --resume $SESSION_ID with a nudge." >&2
  exit 3
fi

if [[ $WT_REFUSED -eq 1 ]]; then
  echo "run-opencode.sh: the agent changed the worktree's git pointers ($WT_WHY); git was not run there. Inspect $WT by hand; remove it with: $0 --cleanup $RUN_DIR" >&2
  exit 6
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
