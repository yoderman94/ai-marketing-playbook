#!/usr/bin/env bash
# ============================================================================
# doctor.sh - check that this machine has everything the blog pipeline needs
# ============================================================================
# Checks every command-line tool, Python package, MCP server, local service and
# setting the pipeline uses. Prints what's missing and the command to install it.
# Changes nothing.
#
# Usage:
#   scripts/doctor.sh                  # full report
#   scripts/doctor.sh --required-only  # only the tools the pipeline can't run without
#   scripts/doctor.sh --quiet          # no output, just the exit code
#
# Exit codes:
#   0  every REQUIRED item is present (optional items may be missing)
#   1  at least one REQUIRED item is missing
#
# Full install guide: docs/TOOLS.md
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REQUIRED_ONLY=0
QUIET=0
for arg in "$@"; do
    case "$arg" in
        --required-only) REQUIRED_ONLY=1 ;;
        --quiet) QUIET=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $arg (see --help)" >&2; exit 64 ;;
    esac
done

# Load .env for the URL settings, without overriding the shell.
if [ -f "$REPO_ROOT/.env" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in ''|'#'*) continue ;; esac
        _key="$(printf '%s' "${_line%%=*}" | tr -d '[:space:]')"
        _val="${_line#*=}"
        case "$_key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
        _val="${_val%\"}"; _val="${_val#\"}"; _val="${_val%\'}"; _val="${_val#\'}"
        if [ -z "${!_key+x}" ]; then export "$_key=$_val"; fi
    done < "$REPO_ROOT/.env"
fi

OS="$(uname -s)"
case "$OS" in
    Darwin) PKG="brew install" ;;
    Linux)  PKG="sudo apt install" ;;
    *)      PKG="install" ;;
esac

MISSING_REQUIRED=0
MISSING_OPTIONAL=0

out() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
section() { out ""; out "== $* =="; }
ok()   { out "  [ok]       $1${2:+  ($2)}"; }
miss() { # miss <required|optional> <name> <why> <fix>
    if [ "$1" = "required" ]; then
        MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
        out "  [MISSING]  $2 - $3"
    else
        MISSING_OPTIONAL=$((MISSING_OPTIONAL + 1))
        out "  [optional] $2 - $3"
    fi
    out "             fix: $4"
}

version_of() { "$@" 2>&1 | head -1 | tr -d '\r'; }

check_cmd() { # check_cmd <required|optional> <cmd> <why> <fix> [version-flag]
    local level="$1" cmd="$2" why="$3" fix="$4" vflag="${5:---version}"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd" "$(version_of "$cmd" "$vflag")"
    else
        miss "$level" "$cmd" "$why" "$fix"
    fi
}

check_py() { # check_py <required|optional> <module> <pip-name> <why>
    if python3 -c "import $2" >/dev/null 2>&1; then
        ok "python: $2"
    else
        miss "$1" "python: $2" "$4" "python3 -m pip install $3   (or: python3 -m pip install -r requirements.txt)"
    fi
}

http_up() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null | grep -qE '^[23]'; }

# ---------------------------------------------------------------- required
section "Required: the pipeline won't run without these"
check_cmd required claude "Claude Code runs every stage" "curl -fsSL https://claude.ai/install.sh | bash   (see docs/TOOLS.md)"
check_cmd required python3 "router, QC and collect scripts" "$PKG python3"
check_cmd required jq "reads each stage's JSON result" "$PKG jq"
check_cmd required curl "health checks and link checks" "$PKG curl"
check_cmd required git "version control for your clone" "$PKG git"
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
        ok "python3 >= 3.9"
    else
        miss required "python3 >= 3.9" "the scripts use 3.9+ syntax" "$PKG python3 (3.9 or newer)"
    fi
    check_py required textstat textstat "Stage 9 readability check"
fi

if [ "$REQUIRED_ONLY" -eq 0 ]; then
    # ------------------------------------------------------------ recommended
    section "Recommended"
    if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
        ok "timeout" "stages get a time limit (BLOG_STAGE_TIMEOUT)"
    else
        miss optional "timeout / gtimeout" "without it a hung stage can block the batch" \
            "$( [ "$OS" = Darwin ] && echo 'brew install coreutils' || echo 'sudo apt install coreutils' )"
    fi
    check_cmd optional shellcheck "lint the shell scripts after you edit them" "$PKG shellcheck"

    if python3 -c "import ddgs" >/dev/null 2>&1; then
        ok "ddgs" "DuckDuckGo search for Stage 0 (scripts/ddgs-query.sh)"
    else
        miss optional "ddgs" "free news and web search in Stage 0" "python3 -m pip install -U ddgs"
    fi

    # ------------------------------------------------------------ Stage 0 research
    section "Stage 0 research (MCP servers in Claude Code)"
    if command -v claude >/dev/null 2>&1; then
        MCP_LIST="$(claude mcp list 2>/dev/null || true)"
        for spec in "exa|required for Stage 0 (discovery)|docs/TOOLS.md#exa" \
                    "tavily|required for Stage 0 (precision search)|docs/TOOLS.md#tavily" \
                    "firecrawl|optional page fetching|docs/TOOLS.md#firecrawl" \
                    "searxng|optional free metasearch|docs/TOOLS.md#searxng" \
                    "superpowers-chrome|optional, Gemini Deep Research|docs/TOOLS.md#superpowers-chrome"; do
            name="${spec%%|*}"; rest="${spec#*|}"; why="${rest%%|*}"; doc="${rest#*|}"
            if printf '%s' "$MCP_LIST" | grep -qi "$name"; then
                ok "mcp: $name"
            else
                miss optional "mcp: $name" "$why" "see $doc"
            fi
        done
        out "  note: Stage 0 needs Exa AND Tavily for a passing research bundle."
    fi

    section "Stage 0 local services (optional)"
    SEARX="${SEARXNG_URL:-http://localhost:8888}"
    if http_up "$SEARX/"; then ok "SearXNG" "$SEARX"; else miss optional "SearXNG at $SEARX" "free metasearch, Phase B2" "cd services/searxng && docker compose up -d"; fi
    FC="${FIRECRAWL_URL:-}"
    if [ -n "$FC" ]; then
        if http_up "$FC/"; then ok "Firecrawl" "$FC"; else miss optional "Firecrawl at $FC" "page fetching, Phase E" "start your Firecrawl instance, or unset FIRECRAWL_URL to use the hosted API"; fi
    fi
    check_cmd optional docker "runs SearXNG (and a self-hosted Firecrawl)" "https://docs.docker.com/get-docker/"
    check_cmd optional node "the superpowers-chrome MCP runs on Node.js" "$PKG node"
    if command -v python3 >/dev/null 2>&1; then
        check_py optional playwright playwright "Gemini Deep Research script (Phase C)"
    fi

    # ------------------------------------------------------------ covers
    section "Stage 10 template covers (optional)"
    check_cmd optional resvg "renders the cover SVG to PNG" "$( [ "$OS" = Darwin ] && echo 'brew install resvg' || echo 'cargo install resvg  (or download a release: https://github.com/linebender/resvg/releases)' )"
    check_cmd optional cwebp "makes the WebP files" "$( [ "$OS" = Darwin ] && echo 'brew install webp' || echo 'sudo apt install webp' )" -version
    if command -v magick >/dev/null 2>&1; then
        ok magick "$(version_of magick -version)"
    elif command -v identify >/dev/null 2>&1; then
        ok "identify (ImageMagick 6)"
    else
        miss optional "ImageMagick" "checks every cover's pixel size" "$( [ "$OS" = Darwin ] && echo 'brew install imagemagick' || echo 'sudo apt install imagemagick' )"
    fi
    if command -v python3 >/dev/null 2>&1; then
        check_py optional fontTools fonttools "draws the cover text as outlines"
    fi
    for f in "$REPO_ROOT/cover-generator/fonts/Anton-Regular.ttf" "$REPO_ROOT/cover-generator/fonts/BarlowCondensed-ExtraBold.ttf"; do
        if [ -f "$f" ]; then ok "font: $(basename "$f")"; else miss optional "font: $(basename "$f")" "cover font file" "see cover-generator/README.md"; fi
    done

    # ------------------------------------------------------------ Stage 11
    section "Stage 11 AI cover photos (optional, interactive only)"
    out "  Needs the Magnific connector in an interactive Claude Code session."
    out "  doctor.sh can't see claude.ai connectors. See docs/TOOLS.md#magnific."

    # ------------------------------------------------------------ project setup
    section "Project setup"
    if [ -f "$REPO_ROOT/personas/writer-profiles.md" ]; then ok "personas/writer-profiles.md"; else miss optional "personas/writer-profiles.md" "Stage 2 writes in this voice" "copy personas/WRITER-PERSONA-TEMPLATE.md and fill it in (README step 2)"; fi
    PLACEHOLDERS=$(grep -rlE '\[YOUR_AGENCY\]|\[YOUR_VERTICAL\]|\[YOUR-AGENCY-DOMAIN\]' \
        "$REPO_ROOT/CLAUDE.md" "$REPO_ROOT/instructions" "$REPO_ROOT/reference" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$PLACEHOLDERS" -eq 0 ]; then
        ok "placeholders filled in"
    else
        miss optional "placeholders" "$PLACEHOLDERS file(s) still hold [YOUR_AGENCY], [YOUR_VERTICAL] or [YOUR-AGENCY-DOMAIN]" "README step 1"
    fi
    if [ -f "$REPO_ROOT/.env" ]; then ok ".env"; else out "  [info]     no .env (fine: the defaults apply; see .env.example)"; fi
fi

section "Result"
if [ "$MISSING_REQUIRED" -gt 0 ]; then
    out "  $MISSING_REQUIRED required item(s) missing. The pipeline won't run until you install them."
    exit 1
fi
out "  All required items present. $MISSING_OPTIONAL optional item(s) missing."
exit 0
