#!/usr/bin/env bash
# RETIRED from blog Stage 0 on 2026-10-14. Kept for manual use only.
# ============================================================================
# gemini-auth-check.sh - check that the Google account in the superpowers-chrome
# browser is signed in to Gemini.
#
# WHY THIS EXISTS:
#   Stage 0 can run Gemini Deep Research in the Chrome that the superpowers-chrome
#   MCP runs. If that Google session is signed out, a long batch wastes hours.
#   blog-pipeline.sh runs this check first and stops early on a signed-out browser.
#
# HARD RULE:
#   NEVER start Chrome yourself on the superpowers-chrome profile. A Chrome
#   started with different cookie-encryption flags corrupts Google's session
#   cookies and SIGNS YOU OUT. This script checks the login ONLY through the
#   superpowers-chrome MCP (with `claude -p`), which starts Chrome correctly.
#
# USAGE:
#   gemini-auth-check.sh [--gate] [--notify always|problem|never] [--profile NAME] [--quiet]
#
#   --gate            Preflight mode for blog-pipeline.sh. Same checks.
#   --notify MODE     always  = desktop notification on every run
#                     problem = only when you need to sign in again (default)
#                     never   = no notifications, just the exit code and the log
#   --profile NAME    superpowers-chrome profile (default: superpowers-chrome)
#   --quiet           No stdout. The log file is still written.
#
# ENVIRONMENT:
#   BLOG_LOG_DIR          log folder (default: <repo>/logs)
#   GEMINI_BROWSER_TOOL   MCP tool name for the browser
#                         (default: mcp__plugin_superpowers-chrome_chrome__use_browser)
#   BLOG_MODEL_STANDARD   model for the check (default: sonnet)
#
# EXIT CODES:
#   0   signed in
#   1   signed out (confident)      -> sign in again; the pipeline stops
#   2   can't tell / check error    -> NOT a confirmed sign-out; the pipeline goes on
#   64  bad arguments
#
# PRIVACY: the account email is never written to disk. The log records IN, OUT
# or ERROR only.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="superpowers-chrome"
LOG_DIR="${BLOG_LOG_DIR:-$SCRIPT_DIR/../logs}"
LOG="$LOG_DIR/gemini-auth-check.log"
STATUS_FILE="$LOG_DIR/gemini-auth-status.txt"
LOCKDIR="${TMPDIR:-/tmp}/gemini-auth-check.$(id -u).lock.d"
BROWSER_TOOL="${GEMINI_BROWSER_TOOL:-mcp__plugin_superpowers-chrome_chrome__use_browser}"
MODEL="${BLOG_MODEL_STANDARD:-sonnet}"
mkdir -p "$LOG_DIR"

NOTIFY="problem"
GATE=0
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gate)    GATE=1 ;;
    --notify)  shift; NOTIFY="${1:-problem}" ;;
    --profile) shift; PROFILE="${1:-superpowers-chrome}" ;;
    --quiet)   QUIET=1 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1 (see --help)" >&2; exit 64 ;;
  esac
  shift
done
case "$NOTIFY" in always|problem|never) ;; *) echo "--notify must be always, problem or never" >&2; exit 64 ;; esac
export CHROME_WS_PROFILE="$PROFILE"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
say() { [ "$QUIET" -eq 1 ] || echo "$*"; echo "[$(ts)] $*" >> "$LOG"; }

# Find the claude binary. A scheduler (launchd, cron) often has a minimal PATH.
CLAUDE="$(command -v claude 2>/dev/null || true)"
if [ -z "$CLAUDE" ]; then
  for c in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.claude/local/claude"; do
    [ -x "$c" ] && { CLAUDE="$c"; break; }
  done
fi
if [ -z "$CLAUDE" ]; then
  say "ERROR: claude binary not found. Install Claude Code first."
  printf '%s\tERROR\tno-claude-binary\n' "$(ts)" > "$STATUS_FILE"
  exit 2
fi

# The superpowers-chrome MCP runs under node. Under a scheduler, node from nvm is
# often missing from PATH, so the MCP can't connect. Add node's folder if needed.
if ! command -v node >/dev/null 2>&1; then
  NVM_NODE_BIN=""
  for d in "$HOME"/.nvm/versions/node/*/bin; do [ -x "$d/node" ] && NVM_NODE_BIN="$d"; done
  for d in "$NVM_NODE_BIN" /opt/homebrew/bin /usr/local/bin; do
    if [ -n "$d" ] && [ -x "$d/node" ]; then export PATH="$d:$PATH"; break; fi
  done
fi
command -v node >/dev/null 2>&1 || say "WARN: node not found on PATH; the browser MCP may not connect."

# Single-flight: never let two checks drive the browser at once.
# macOS has no flock(1), so use an atomic mkdir lock with stale recovery (>15 min).
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
    say "Stale lock (>15 min) found; reclaiming."
    rmdir "$LOCKDIR" 2>/dev/null
    mkdir "$LOCKDIR" 2>/dev/null || { say "Could not get the lock; skipping."; exit 2; }
  else
    say "Another auth check is already running; skipping this one."
    exit 2
  fi
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

notify() {  # notify <state> <title> <message>. Desktop only; never fails the check.
  local state="$1" title="$2" msg="$3" sound="Glass"
  [ "$state" = "OUT" ] && sound="Basso"
  if command -v osascript >/dev/null 2>&1; then          # macOS
    osascript -e "display notification \"${msg}\" with title \"${title}\" subtitle \"Gemini login monitor\" sound name \"${sound}\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then      # Linux desktop
    notify-send "$title" "$msg" >/dev/null 2>&1 || true
  fi
}

PROMPT="You are an automated login checker. Use ONLY the tool ${BROWSER_TOOL}. Do not use Bash, Read, Write, or any other tool.

Goal: determine whether the Google account is logged in at https://gemini.google.com/app.

Procedure:
1. Open the page WITHOUT disturbing any existing work: prefer action=\"new_tab\" with payload \"https://gemini.google.com/app\". If new_tab errors, fall back to action=\"navigate\" with that URL.
2. The page is a slow SPA. POLL until it settles: run this exact eval, and REPEAT it up to 6 times waiting ~3 seconds between attempts (use await_text or just re-eval):
   (()=>{const a=document.querySelector('[aria-label*=\"Google Account\"]');const t=(document.body.innerText||'');const signedOut=/Meet Gemini, your personal AI assistant/.test(t)||!!document.querySelector('a[href*=\"ServiceLogin\"]');const rendered=t.replace(/\\s+/g,'').length>40;return JSON.stringify({account:a?a.getAttribute('aria-label'):null, signedOut:signedOut, rendered:rendered});})()
   - As soon as \"account\" contains an email => STOP early: LOGGED IN.
   - Keep polling while \"rendered\" is false (page still loading) — do NOT conclude from an unrendered page.
3. If you opened a new tab, action=\"close_tab\" to close ONLY that tab. Never close other tabs.

Interpretation (after polling):
- \"account\" has an email  => LOGGED IN.
- \"account\" null AND \"signedOut\" true (and the page rendered) => LOGGED OUT.
- Page never rendered, or a tool errored, or the state is ambiguous (account null but signedOut false) => ERROR. Do NOT guess LOGGED OUT from an unsettled page — a false logged-out reading would wrongly abort a healthy run.

Output EXACTLY ONE final line, nothing after it:
  AUTHRESULT=IN              (logged in; do not print the email)
  AUTHRESULT=OUT             (logged out)
  AUTHRESULT=ERROR <reason>  (a tool failed)
Do not type into the page, do not start research, do not navigate elsewhere."

say "Running Gemini auth check (profile=$PROFILE, notify=$NOTIFY, gate=$GATE)…"
OUT="$("$CLAUDE" --allowedTools "$BROWSER_TOOL" --model "$MODEL" -p "$PROMPT" 2>>"$LOG")"
# Never log an email address, even if the model prints one.
printf '%s\n' "$OUT" | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' >> "$LOG"

# grep is line-based, so .* safely captures to end-of-line (do NOT use [^\n]).
RESULT_LINE="$(printf '%s\n' "$OUT" | grep -oE 'AUTHRESULT=.*' | tail -1)"

case "$RESULT_LINE" in
  AUTHRESULT=IN*)
    say "LOGGED IN"
    printf '%s\tIN\n' "$(ts)" > "$STATUS_FILE"
    [ "$NOTIFY" = "always" ] && notify IN "Blog pipeline - Gemini OK" "Signed in to Gemini."
    exit 0
    ;;
  AUTHRESULT=OUT*)
    say "LOGGED OUT — re-login needed."
    printf '%s\tOUT\t\n' "$(ts)" > "$STATUS_FILE"
    [ "$NOTIFY" != "never" ] && notify OUT "Blog pipeline - Gemini SIGNED OUT" "Sign in to Gemini in the superpowers-chrome browser."
    exit 1
    ;;
  *)
    REASON="$(printf '%s' "$RESULT_LINE" | sed -E 's/^AUTHRESULT=ERROR[[:space:]]*//; s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g')"
    [ -z "$RESULT_LINE" ] && REASON="no AUTHRESULT returned (check claude/MCP)"
    say "CHECK ERROR — ${REASON}. Indeterminate (NOT a confirmed logout)."
    printf '%s\tERROR\t%s\n' "$(ts)" "$REASON" > "$STATUS_FILE"
    [ "$NOTIFY" != "never" ] && notify OUT "Blog pipeline - Gemini check inconclusive" "Could not confirm login (${REASON}). Verify manually."
    # Exit 2 = indeterminate, distinct from a confident logout (1). The preflight
    # gate treats this as warn-and-proceed (Stage 0 still skips Gemini gracefully),
    # so a transient render/MCP glitch never aborts an otherwise-healthy run.
    exit 2
    ;;
esac
