#!/bin/bash
# ============================================================================
# ddgs-query.sh — DuckDuckGo (ddgs) metasearch wrapper for automation
# ============================================================================
# Location: scripts/ddgs-query.sh (this project)
#
# Free, no API key, no quota. Stage 0 Phase B3 uses it for recent news and
# trade coverage that Exa and Tavily have not indexed yet. Needs the ddgs Python
# package on python3: python3 -m pip install -U ddgs
#
# Usage:
#   ddgs-query.sh "google local services ads changes"            # text search
#   ddgs-query.sh --news --time m "google local services ads"     # news, past month
#   ddgs-query.sh --num 15 --json "pest control win-back"         # raw JSON
#   ddgs-query.sh --extract "https://example.com/page"            # full page as markdown
#   time: d (day), w (week), m (month), y (year)
#
# Backends: tries auto, then duckduckgo, bing, yahoo, until one returns results.
# On success: prints results to stdout, exits 0
# On failure: prints error to stderr, exits 1   (caller notes it and continues)
# Always logs to logs/ddgs.log in this project (override with DDGS_LOG)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${DDGS_LOG:-$SCRIPT_DIR/../logs/ddgs.log}"
MODE="text"; NUM=10; TIME=""; RAW_JSON=0; QUERY=""
mkdir -p "$(dirname "$LOG_FILE")"

while [ $# -gt 0 ]; do
    case "$1" in
        --news) MODE="news"; shift ;;
        --extract) MODE="extract"; QUERY="$2"; shift 2 ;;
        --text) MODE="text"; shift ;;
        --num)  NUM="$2"; shift 2 ;;
        --time) TIME="$2"; shift 2 ;;
        --json) RAW_JSON=1; shift ;;
        *)      QUERY="$QUERY $1"; shift ;;
    esac
done
QUERY=$(echo "$QUERY" | sed -e 's/^ *//' -e 's/ *$//')
if [ -z "$QUERY" ]; then
    echo "Usage: ddgs-query.sh [--news] [--time d|w|m|y] [--num N] [--json] \"query\" | --extract URL" >&2
    exit 1
fi

START=$(date +%s)
OUT=$(MODE="$MODE" NUM="$NUM" TIME="$TIME" RAW_JSON="$RAW_JSON" QUERY="$QUERY" python3 -I - <<'PY'
import json, os, sys
from ddgs import DDGS
mode, q = os.environ["MODE"], os.environ["QUERY"]
num, t, raw = int(os.environ["NUM"]), os.environ["TIME"] or None, os.environ["RAW_JSON"] == "1"
res, used, errs = [], None, []
if mode == "extract":
    try:
        r = DDGS().extract(q)
    except Exception as e:
        print(f"extract failed: {type(e).__name__}: {e}"[:300], file=sys.stderr); sys.exit(1)
    body = (r or {}).get("content") or ""
    if not body.strip():
        print("extract returned no content", file=sys.stderr); sys.exit(1)
    print(json.dumps(r) if raw else body)
    print(f"EXTRACT CHARS={len(body)}", file=sys.stderr)
    sys.exit(0)
for b in ("auto", "duckduckgo", "bing", "yahoo"):
    try:
        fn = DDGS().news if mode == "news" else DDGS().text
        res = list(fn(q, max_results=num, timelimit=t, backend=b) or [])
        if res:
            used = b
            break
    except Exception as e:
        errs.append(f"{b}: {type(e).__name__}")
if not res:
    print("no results; " + "; ".join(errs), file=sys.stderr)
    sys.exit(1)
if raw:
    print(json.dumps(res, indent=1))
else:
    for i, r in enumerate(res, 1):
        url = r.get("href") or r.get("url") or ""
        date = f" [{r['date'][:10]}]" if r.get("date") else ""
        src = f" ({r['source']})" if r.get("source") else ""
        print(f"{i}. {r.get('title','')}{date}{src}\n   {url}\n   {(r.get('body') or '')[:240]}")
print(f"BACKEND={used} COUNT={len(res)}", file=sys.stderr)
PY
)
RC=$?
SECS=$(( $(date +%s) - START ))
if [ $RC -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') | OK | ${SECS}s | $MODE | ${QUERY:0:80}" >> "$LOG_FILE"
    echo "$OUT"
    exit 0
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') | FAIL | ${SECS}s | $MODE | ${QUERY:0:80}" >> "$LOG_FILE"
echo "ddgs failed for: $QUERY" >&2
exit 1
