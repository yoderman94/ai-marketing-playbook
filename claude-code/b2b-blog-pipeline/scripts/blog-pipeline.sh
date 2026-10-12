#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Blog Pipeline - manifest-driven batch runner
# ============================================================================
# Runs every topic in inputs/ through the stage files in instructions/, one
# headless `claude -p` call per stage. Works on any project folder with the
# standard layout: inputs/, instructions/, output/, personas/, reference/, research/.
#
# Flow:
#   1. scripts/router.py classifies inputs/ and writes inputs/.manifest.json
#   2. This script loops through the manifest jobs
#   3. Each job runs from its entry stage through Stage 9 (QC report), then
#      Stage 10 (template cover) if cover-generator/ is set up, then the
#      collect step that files the post under posts/<date>-<slug>/
#   Stage 11 (AI cover photos) is interactive only and never runs here.
#
# Inputs that drop in can be any of:
#   - Batch table (CSV / TSV / Markdown with matching headers)  -> Stage 0
#   - Topic seed (short prose, no markers)                      -> Stage 0
#   - Brief (Stage 1 output format)                             -> Stage 2
#   - Draft at any stage of completion (markers detect stage)   -> Stage N+1
#   - Research bundle (PDF or Stage 0 markdown output)          -> attached to a job
#
# Estimated runtime: 1-3 hours per job, most of it Stage 0 research and the
# sleep timers between stages.
# ============================================================================

# --- Input validation --------------------------------------------------------
usage() {
    cat >&2 <<'USAGE'
Usage: scripts/blog-pipeline.sh [project-dir] [all|no-gemini] [skip-router]

  project-dir   The blog project folder. Defaults to this repo (the folder above scripts/).
  all           Stage 0 runs every research source, Gemini included (default).
  no-gemini     Stage 0 skips the Gemini browser pass. Exa and Tavily still run.
  skip-router   Reuse inputs/.manifest.json from the last run instead of re-classifying.

Examples:
  scripts/blog-pipeline.sh                      # this repo, all sources
  scripts/blog-pipeline.sh . no-gemini          # no browser research
  scripts/blog-pipeline.sh ~/blogs/my-vertical  # another clone of this template

Settings come from environment variables or a .env file in the project folder.
See .env.example and docs/TOOLS.md.
USAGE
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

PROJECT_ARG="${1:-$REPO_ROOT}"
if [ ! -d "$PROJECT_ARG" ]; then
    echo "ERROR: project folder not found: $PROJECT_ARG" >&2
    usage
    exit 1
fi
PROJECT_DIR="$(cd "$PROJECT_ARG" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

if [ ! -d "$PROJECT_DIR/instructions" ]; then
    echo "ERROR: $PROJECT_DIR/instructions/ does not exist. Is this a blog project folder?" >&2
    exit 1
fi

if [ ! -d "$PROJECT_DIR/inputs" ]; then
    echo "ERROR: $PROJECT_DIR/inputs/ does not exist." >&2
    exit 1
fi

# Load the project .env, if there is one. A variable already set in the shell wins.
# shellcheck source=/dev/null
if [ -f "$PROJECT_DIR/.env" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in ''|'#'*) continue ;; esac
        _key="${_line%%=*}"
        _val="${_line#*=}"
        _key="$(printf '%s' "$_key" | tr -d '[:space:]')"
        case "$_key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
        _val="${_val%\"}"; _val="${_val#\"}"; _val="${_val%\'}"; _val="${_val#\'}"
        if [ -z "${!_key+x}" ]; then export "$_key=$_val"; fi
    done < "$PROJECT_DIR/.env"
fi

# --- Dependency check --------------------------------------------------------
if [ -x "$SCRIPTS_DIR/doctor.sh" ]; then
    if ! "$SCRIPTS_DIR/doctor.sh" --required-only --quiet; then
        echo "ERROR: required tools are missing. Run scripts/doctor.sh for details and install steps." >&2
        exit 1
    fi
fi

# --- Configuration -----------------------------------------------------------
LOG_DIR="${BLOG_LOG_DIR:-$PROJECT_DIR/logs}"
export BLOG_LOG_DIR="$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/blog-pipeline-${PROJECT_NAME}-$TIMESTAMP.log"
AUDIT_FILE="$LOG_DIR/blog-pipeline-${PROJECT_NAME}-$TIMESTAMP-model-audit.log"
JSON_DIR="$LOG_DIR/blog-pipeline-${PROJECT_NAME}-$TIMESTAMP-stage-json"
# Cross-run API usage log. Every Stage 0 appends to it and it is never rotated, so
# it is the one record of Exa, Tavily and Firecrawl call volume across runs.
QUOTA_LEDGER="$LOG_DIR/blog-batch-stage0.log"
# Topic slug -> final slug for every job. collect-post.py reads this same file.
SLUG_MAP="$LOG_DIR/blog-slug-map.log"
SLUG_FILE="$PROJECT_DIR/output/.current-slug"
MANIFEST_FILE="$PROJECT_DIR/inputs/.manifest.json"
ROUTER_SCRIPT="$SCRIPTS_DIR/router.py"
QC_SCRIPT="$SCRIPTS_DIR/qc.sh"
COLLECT_SCRIPT="$SCRIPTS_DIR/collect-post.py"
GEMINI_AUTH_SCRIPT="$SCRIPTS_DIR/gemini-auth-check.sh"
GEMINI_RESEARCH_SCRIPT="$SCRIPTS_DIR/gemini-deep-research.py"

# Sleep timers (seconds). Set any of them to 0 for back-to-back runs.
SLEEP_AFTER_SONNET_LIGHT="${BLOG_SLEEP_SONNET_LIGHT:-30}"   # lightweight stage (Stage 5 URL/slug)
SLEEP_AFTER_SONNET="${BLOG_SLEEP_SONNET:-60}"
SLEEP_AFTER_OPUS="${BLOG_SLEEP_OPUS:-120}"
SLEEP_BETWEEN_JOBS="${BLOG_SLEEP_BETWEEN_JOBS:-120}"
SLEEP_BEFORE_FIRST_JOB="${BLOG_SLEEP_BEFORE_FIRST_JOB:-60}" # time to press Ctrl-C if the router got it wrong

# Models. Any name or alias that `claude --model` accepts works here.
MODEL_SONNET="${BLOG_MODEL_STANDARD:-sonnet}"    # mechanical and checking stages
MODEL_OPUS="${BLOG_MODEL_WRITING:-opus}"         # writing, FAQ, titles, final link check
MODEL_RESEARCH="${BLOG_MODEL_RESEARCH:-sonnet}"  # Stage 0 research (MCP and browser calls)

# Permissions for the headless `claude -p` stages.
#   allowlist (default): file edits are accepted, and only the tools in
#                        BLOG_ALLOWED_TOOLS may run. Anything else is refused.
#   bypass:              --dangerously-skip-permissions. Every tool runs with no
#                        check. Use it only on a machine and account you'd let
#                        an unattended agent control.
PERMISSION_MODE="${BLOG_PERMISSION_MODE:-allowlist}"
DEFAULT_ALLOWED_TOOLS="Read Write Edit MultiEdit Glob Grep WebSearch WebFetch TodoWrite"
DEFAULT_ALLOWED_TOOLS+=" Bash(python3:*) Bash(curl:*) Bash(ls:*) Bash(cat:*) Bash(head:*) Bash(tail:*)"
DEFAULT_ALLOWED_TOOLS+=" Bash(wc:*) Bash(grep:*) Bash(mkdir:*) Bash(cp:*) Bash(mv:*) Bash(date:*)"
DEFAULT_ALLOWED_TOOLS+=" Bash(printf:*) Bash(echo:*) Bash(test:*) Bash(file:*) Bash(scripts/searxng-query.sh:*) Bash(scripts/ddgs-query.sh:*)"
DEFAULT_ALLOWED_TOOLS+=" mcp__exa mcp__tavily mcp__firecrawl mcp__searxng"
ALLOWED_TOOLS="${BLOG_ALLOWED_TOOLS:-$DEFAULT_ALLOWED_TOOLS}"
case "$PERMISSION_MODE" in
    allowlist)
        read -r -a _allowed <<< "$ALLOWED_TOOLS"
        CLAUDE_PERMISSION_ARGS=(--permission-mode acceptEdits --allowedTools "${_allowed[@]}")
        ;;
    bypass)
        CLAUDE_PERMISSION_ARGS=(--dangerously-skip-permissions)
        ;;
    *)
        echo "ERROR: BLOG_PERMISSION_MODE must be allowlist or bypass (got: $PERMISSION_MODE)" >&2
        exit 1
        ;;
esac
# Extra flags for every claude call, for example "--setting-sources project,local".
CLAUDE_EXTRA_ARGS=()
if [ -n "${BLOG_CLAUDE_EXTRA_ARGS:-}" ]; then
    read -r -a CLAUDE_EXTRA_ARGS <<< "$BLOG_CLAUDE_EXTRA_ARGS"
fi

# RESEARCH_MODE: "all" (every source, Gemini included) or "no-gemini".
# The older values "yes" and "no" still work.
RESEARCH_MODE="${2:-${BLOG_RESEARCH_MODE:-all}}"
case "$RESEARCH_MODE" in
    yes) RESEARCH_MODE="all" ;;
    no)  RESEARCH_MODE="no-gemini" ;;
    all|no-gemini) ;;
    *) echo "ERROR: research mode must be all or no-gemini (got: $RESEARCH_MODE)" >&2; usage; exit 1 ;;
esac
SKIP_ROUTER="${3:-}"

# Read one field from the manifest. Values travel as arguments, never pasted into
# Python source, so a quote in a slug or a path can't break the call.
manifest_get() {
    python3 - "$MANIFEST_FILE" "$@" <<'PY'
import json, sys
path, *keys = sys.argv[1:]
data = json.load(open(path))
for k in keys:
    if isinstance(data, list):
        data = data[int(k)]
    elif isinstance(data, dict):
        data = data.get(k)
    if data is None:
        break
if data is None:
    print("")
elif isinstance(data, (dict, list)):
    print(json.dumps(data))
else:
    print(data)
PY
}

# Count the items in a top-level manifest list ("jobs" or "aborted_files").
manifest_count() {
    python3 - "$MANIFEST_FILE" "$1" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1])).get(sys.argv[2]) or []))
PY
}

# Portable timeout: GNU timeout on Linux, gtimeout (coreutils) on macOS, else none.
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout "${BLOG_STAGE_TIMEOUT:-3h}")
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(gtimeout "${BLOG_STAGE_TIMEOUT:-3h}")
else
    TIMEOUT_CMD=()
fi

# Absolute path without GNU realpath (older macOS has none).
abspath() {
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

# --- Setup -------------------------------------------------------------------
mkdir -p "$LOG_DIR" "$JSON_DIR" "$PROJECT_DIR/output" "$PROJECT_DIR/research" "$PROJECT_DIR/briefs"
echo "slug,stage,requested_model,actual_model,requested_effort,cost_usd,duration_ms,is_error" > "$AUDIT_FILE"

# --- Pre-flight --------------------------------------------------------------
echo "================================================================" | tee "$LOG_FILE"
echo "BLOG PIPELINE - $PROJECT_NAME" | tee -a "$LOG_FILE"
echo "Started: $(date)" | tee -a "$LOG_FILE"
echo "Project: $PROJECT_DIR" | tee -a "$LOG_FILE"
echo "Research mode: $RESEARCH_MODE (Stage 0 = Exa + Tavily$([ "$RESEARCH_MODE" = "all" ] && echo " + Gemini"))" | tee -a "$LOG_FILE"
echo "Permissions: $PERMISSION_MODE" | tee -a "$LOG_FILE"
echo "Models: standard=$MODEL_SONNET writing=$MODEL_OPUS research=$MODEL_RESEARCH" | tee -a "$LOG_FILE"
echo "Skip router: ${SKIP_ROUTER:-no}" | tee -a "$LOG_FILE"
echo "Log: $LOG_FILE" | tee -a "$LOG_FILE"
echo "================================================================" | tee -a "$LOG_FILE"

# find, not `ls | grep -v`: under pipefail an empty folder made grep exit 1 and
# the script ended with no message. README.md and dotfiles don't count as input.
INPUT_COUNT=$(find "$PROJECT_DIR/inputs" -mindepth 1 -maxdepth 1 ! -name '.*' ! -name 'README.md' | wc -l | tr -d ' ')
if [ "$INPUT_COUNT" -eq 0 ]; then
    echo "$(date): ERROR - no files in inputs/. Add a topic seed, brief or batch table and rerun." | tee -a "$LOG_FILE"
    exit 1
fi
echo "$(date): Found $INPUT_COUNT file(s) in inputs/" | tee -a "$LOG_FILE"

# ============================================================================
# ROUTER - classify inputs and write manifest
# ============================================================================
if [ "$SKIP_ROUTER" = "skip-router" ]; then
    echo "$(date): Skipping router (skip-router flag set)" | tee -a "$LOG_FILE"
    if [ ! -f "$MANIFEST_FILE" ]; then
        echo "$(date): ERROR - skip-router set but no manifest at $MANIFEST_FILE" | tee -a "$LOG_FILE"
        exit 1
    fi
else
    echo "" | tee -a "$LOG_FILE"
    echo "================================================================" | tee -a "$LOG_FILE"
    echo "$(date): ROUTER - classifying inputs" | tee -a "$LOG_FILE"
    echo "================================================================" | tee -a "$LOG_FILE"

    if [ ! -f "$ROUTER_SCRIPT" ]; then
        echo "$(date): ERROR - router script not found at $ROUTER_SCRIPT" | tee -a "$LOG_FILE"
        exit 1
    fi

    set +e
    python3 "$ROUTER_SCRIPT" "$PROJECT_DIR" 2>&1 | tee -a "$LOG_FILE"
    ROUTER_EXIT=${PIPESTATUS[0]}
    set -e

    if [ "$ROUTER_EXIT" -eq 1 ]; then
        echo "$(date): ROUTER FAILED - aborting pipeline" | tee -a "$LOG_FILE"
        exit 1
    fi
    if [ "$ROUTER_EXIT" -eq 2 ]; then
        echo "$(date): Router completed with aborted files - non-aborted jobs will still run" | tee -a "$LOG_FILE"
    fi
fi

# --- Parse manifest ----------------------------------------------------------
if [ ! -f "$MANIFEST_FILE" ]; then
    echo "$(date): ERROR - manifest not found at $MANIFEST_FILE" | tee -a "$LOG_FILE"
    exit 1
fi

JOB_COUNT=$(manifest_count jobs)
echo "$(date): Manifest contains $JOB_COUNT job(s)" | tee -a "$LOG_FILE"

if [ "$JOB_COUNT" -eq 0 ]; then
    echo "$(date): No jobs to run (all inputs aborted or no valid inputs)" | tee -a "$LOG_FILE"
    exit 1
fi

# --- Research servers ---------------------------------------------------------
# Stage 0 needs Exa and Tavily. Without them it still writes a bundle, but a thin
# one built from web search alone. Warn loudly before any job spends money on it.
if [ "${BLOG_SKIP_MCP_CHECK:-0}" != "1" ]; then
    MCP_LIST="$(claude mcp list 2>/dev/null || true)"
    for _srv in exa tavily; do
        if ! printf '%s\n' "$MCP_LIST" | grep -qiE "^${_srv}[^a-z].*(connected|✓|✔)"; then
            echo "$(date): WARNING - MCP server '$_srv' is not connected. Stage 0 research will be thin. See docs/TOOLS.md#$_srv" | tee -a "$LOG_FILE"
        fi
    done
fi

# --- Research mode notes -----------------------------------------------------
# Exa + Tavily are MCP/API tools and run safely per job in any batch size.
# Gemini Deep Research drives a single shared Chrome session, so in multi-job runs it
# executes sequentially, one job at a time. The instruction file lets Gemini be skipped
# gracefully (login wall / no Deep Research mode) without aborting the job, so a
# multi-job run still completes on Exa + Tavily if the browser pass is unavailable.
if [ "$RESEARCH_MODE" = "all" ] && [ "$JOB_COUNT" -gt 1 ]; then
    echo "$(date): NOTE - multi-job run; Gemini Deep Research will run sequentially per job" | tee -a "$LOG_FILE"
fi

# --- Safety pause ------------------------------------------------------------
if [ "$SLEEP_BEFORE_FIRST_JOB" -gt 0 ] && [ "$SKIP_ROUTER" != "skip-router" ]; then
    echo "" | tee -a "$LOG_FILE"
    echo "$(date): Sleeping ${SLEEP_BEFORE_FIRST_JOB}s before first job - Ctrl-C now if classification looks wrong" | tee -a "$LOG_FILE"
    sleep "$SLEEP_BEFORE_FIRST_JOB"
fi

# ============================================================================
# CORE RUNNER
# ============================================================================
run_stage() {
    local stage_num="$1"
    local stage_name="$2"
    local model="$3"
    local effort="${4:-medium}"
    local prompt="$5"
    local json_out="$JSON_DIR/${SLUG:-job$JOB_INDEX}-stage${stage_num}.json"

    # A previous stage in this job produced nothing, or the session limit closed.
    # Do not spend a model call running the next stage on a file that is not there.
    if [ "$JOB_ABORT" -eq 1 ]; then
        echo "$(date): STAGE $stage_num SKIPPED - job aborted" | tee -a "$LOG_FILE"
        return 0
    fi

    echo "" | tee -a "$LOG_FILE"
    echo "----------------------------------------------------------------" | tee -a "$LOG_FILE"
    echo "$(date): STAGE $stage_num - $stage_name [requested: $model, effort=$effort]" | tee -a "$LOG_FILE"
    echo "----------------------------------------------------------------" | tee -a "$LOG_FILE"

    cd "$PROJECT_DIR"
    set +e
    ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} claude "${CLAUDE_PERMISSION_ARGS[@]}" ${CLAUDE_EXTRA_ARGS[@]+"${CLAUDE_EXTRA_ARGS[@]}"} \
        --model "$model" --effort "$effort" --output-format json -p "$prompt" >"$json_out" 2>>"$LOG_FILE"
    local exit_code=$?
    set -e

    local actual_model="unknown" cost="n/a" duration="n/a" is_error="unknown" result_text=""
    if [ -s "$json_out" ] && jq -e . "$json_out" >/dev/null 2>&1; then
        actual_model=$(jq -r '.modelUsage | keys | if length > 0 then join(";") else "unknown" end' "$json_out")
        cost=$(jq -r '.total_cost_usd // "n/a"' "$json_out")
        duration=$(jq -r '.duration_ms // "n/a"' "$json_out")
        is_error=$(jq -r 'if has("is_error") then (.is_error | tostring) else "unknown" end' "$json_out")
        result_text=$(jq -r '.result // ""' "$json_out")
        echo "$result_text" | tee -a "$LOG_FILE"
    else
        echo "$(date): WARNING - Stage $stage_num produced no parseable JSON; raw output below" | tee -a "$LOG_FILE"
        cat "$json_out" 2>/dev/null | tee -a "$LOG_FILE"
    fi

    echo "$(date): STAGE $stage_num AUDIT - actual_model=$actual_model requested_model=$model requested_effort=$effort cost_usd=$cost duration_ms=$duration is_error=$is_error" | tee -a "$LOG_FILE"
    echo "${SLUG:-job$JOB_INDEX},$stage_num,$model,$actual_model,$effort,$cost,$duration,$is_error" >> "$AUDIT_FILE"

    if [ "$exit_code" -ne 0 ]; then
        echo "$(date): FAILED - Stage $stage_num (exit $exit_code)" | tee -a "$LOG_FILE"
    else
        echo "$(date): COMPLETED - Stage $stage_num" | tee -a "$LOG_FILE"
    fi

    # Session-limit detection. If the Claude usage window closes mid-run, every
    # remaining stage would run as an instant no-op and print a false COMPLETE.
    # Stop the queue instead.
    case "$result_text" in
        *"session limit"*|*"Session limit"*|*"usage limit"*)
            echo "$(date): SESSION LIMIT detected in Stage $stage_num output. Aborting job and stopping the queue." | tee -a "$LOG_FILE"
            JOB_ABORT=1
            SESSION_LIMIT=1
            return 0
            ;;
    esac

    # Output gate. Every stage from 2 on reads and rewrites the draft, so if the draft is
    # not on disk the stage did nothing, whatever the exit code says. DATE_SLUG is read at
    # call time, so the Stage 1 and Stage 5 slug reassignments are picked up here.
    if [ "$stage_num" -ge 2 ]; then
        local expect="$PROJECT_DIR/output/${DATE_SLUG}-draft.md"

        # Stages 1 and 5 may legitimately RENAME the draft to a new slug and write the new
        # slug to output/.current-slug. The job body only re-reads that file AFTER run_stage
        # returns, so at this point DATE_SLUG can still hold the pre-rename name and the gate
        # would abort on a job that actually succeeded. Follow the rename before failing.
        if [ ! -s "$expect" ] && [ -f "$SLUG_FILE" ]; then
            local _gate_slug
            _gate_slug=$(tr -d '[:space:]' < "$SLUG_FILE")
            if [ -n "$_gate_slug" ] && [ "$_gate_slug" != "$SLUG" ]; then
                local renamed="$PROJECT_DIR/output/${DATE_PREFIX}${_gate_slug}-draft.md"
                if [ -s "$renamed" ]; then
                    echo "$(date): Stage $stage_num renamed the draft: $SLUG -> $_gate_slug" | tee -a "$LOG_FILE"
                    SLUG="$_gate_slug"
                    DATE_SLUG="${DATE_PREFIX}${SLUG}"
                    expect="$renamed"
                fi
            fi
        fi

        if [ ! -s "$expect" ]; then
            echo "$(date): STAGE $stage_num PRODUCED NO FILE - $expect missing or empty." | tee -a "$LOG_FILE"
            echo "$(date): ABORTING JOB rather than running later stages on nothing." | tee -a "$LOG_FILE"
            JOB_ABORT=1
            return 0
        fi
        echo "$(date): output gate PASSED - $(wc -w <"$expect" | tr -d " ") words in $expect" | tee -a "$LOG_FILE"
    fi
    return 0
}

# ============================================================================
# PER-JOB EXECUTION
# ============================================================================
JOB_INDEX=0
JOBS_RUN=0
JOBS_FAILED=0

# Output-gate state. JOB_ABORT is reset per job; SESSION_LIMIT stops the whole queue.
# See the gate at the end of run_stage() for why these are flags and not return codes.
JOB_ABORT=0
SESSION_LIMIT=0

while [ "$JOB_INDEX" -lt "$JOB_COUNT" ]; do

    # Extract job fields from manifest.
    SLUG=$(manifest_get jobs "$JOB_INDEX" slug)
    # Stages 1 and 5 may rename the draft. Keep the original slug, so the slug map
    # can link the final post back to its Stage 0 research.
    TOPIC_SLUG="$SLUG"
    FROM_STAGE=$(manifest_get jobs "$JOB_INDEX" entry_stage)
    PRIMARY_INPUT=$(manifest_get jobs "$JOB_INDEX" primary_input_path)
    CLASSIFICATION=$(manifest_get jobs "$JOB_INDEX" classification)
    JOB_ID=$(manifest_get jobs "$JOB_INDEX" job_id)

    # Scheduled publish date, preferred source: router-extracted publish_date
    # (from a batch-table "Publish Date" column or an inline "Publish Date: ..."
    # marker in a topic seed/brief — see reference/batch-template.md). Falls back
    # to a YYYY-MM-DD- prefix on the input filename if the manifest field is empty.
    # This date, not the run/creation date, is what goes in the output filename.
    PUBLISH_DATE=$(manifest_get jobs "$JOB_INDEX" publish_date)
    if [ -z "$PUBLISH_DATE" ]; then
        INPUT_BASENAME=$(basename "$PRIMARY_INPUT")
        if [[ "$INPUT_BASENAME" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})- ]]; then
            PUBLISH_DATE="${BASH_REMATCH[1]}"
        fi
    fi
    DATE_PREFIX="${PUBLISH_DATE:+${PUBLISH_DATE}-}"
    DATE_SLUG="${DATE_PREFIX}${SLUG}"

    # Reset the output gate for this job.
    JOB_ABORT=0

    echo "" | tee -a "$LOG_FILE"
    echo "################################################################" | tee -a "$LOG_FILE"
    echo "$(date): JOB $JOB_ID of $JOB_COUNT - $SLUG" | tee -a "$LOG_FILE"
    echo "  Classification: $CLASSIFICATION" | tee -a "$LOG_FILE"
    echo "  Primary input:  $PRIMARY_INPUT" | tee -a "$LOG_FILE"
    echo "  Publish date:   ${PUBLISH_DATE:-none}" | tee -a "$LOG_FILE"
    echo "  Output slug:    $DATE_SLUG" | tee -a "$LOG_FILE"
    echo "  Entry stage:    $FROM_STAGE" | tee -a "$LOG_FILE"
    echo "################################################################" | tee -a "$LOG_FILE"

    # Write slug marker for stages to pick up.
    echo "$SLUG" > "$SLUG_FILE"

    # If this is a draft entering at stage > 1, copy it to output/{slug}-draft.md
    # so the stages find it where they expect it. Skip the copy if src == dst.
    if [ "$FROM_STAGE" -gt 1 ] && [ "$CLASSIFICATION" = "draft" ]; then
        _SRC="$(cd "$PROJECT_DIR" && abspath "$PRIMARY_INPUT")"
        _DST="$PROJECT_DIR/output/${DATE_SLUG}-draft.md"
        if [ "$_SRC" != "$_DST" ]; then
            cp "$_SRC" "$_DST"
            echo "$(date): Copied draft to output/${DATE_SLUG}-draft.md" | tee -a "$LOG_FILE"
        else
            echo "$(date): Draft already at output/${DATE_SLUG}-draft.md — no copy needed" | tee -a "$LOG_FILE"
        fi
    fi

    # If this is a brief entering at stage 2, copy it to briefs/{slug}-brief.md
    # Skip the copy if src == dst (cp errors on identical src/dst, which would
    # kill the whole script under set -e) — mirrors the draft-copy guard above.
    if [ "$FROM_STAGE" -eq 2 ] && [ "$CLASSIFICATION" = "brief" ]; then
        _BRIEF_SRC="$(cd "$PROJECT_DIR" && abspath "$PRIMARY_INPUT")"
        _BRIEF_DST="$PROJECT_DIR/briefs/${SLUG}-brief.md"
        if [ "$_BRIEF_SRC" != "$_BRIEF_DST" ]; then
            cp "$_BRIEF_SRC" "$_BRIEF_DST"
            echo "$(date): Copied brief to briefs/${SLUG}-brief.md" | tee -a "$LOG_FILE"
        else
            echo "$(date): Brief already at briefs/${SLUG}-brief.md — no copy needed" | tee -a "$LOG_FILE"
        fi
    fi

# ----------------------------------------------------------------------------
# STAGE 0: Multi-Source Research (Exa + Tavily + Gemini) + fact-check gate
# Runs for every job entering at stage <= 1. Output contract:
# research/${SLUG}-research.md with ## Direct Quotes and ## Statistics and Data, >= 4 KB.
# ----------------------------------------------------------------------------
if [ "$FROM_STAGE" -le 1 ]; then

# Preflight gate: the Gemini pass needs a Chrome that the superpowers-chrome MCP
# runs, signed in to Google. Check the login up front, so a logged-out browser
# doesn't waste the run. Only gates when Gemini is in play (RESEARCH_MODE=all).
#   0 = signed in        1 = signed out (abort)      2 = can't tell (go on)
#   anything else = the check itself is broken: skip Gemini for this run, never
#   report it as a confirmed login.
if [ "$RESEARCH_MODE" = "all" ]; then
    echo "$(date): Preflight - checking the Gemini login (superpowers-chrome browser)" | tee -a "$LOG_FILE"
    GATE_RC=0
    if [ -x "$GEMINI_AUTH_SCRIPT" ]; then
        "$GEMINI_AUTH_SCRIPT" --gate --notify problem >> "$LOG_FILE" 2>&1 || GATE_RC=$?
    else
        GATE_RC=127
    fi
    case "$GATE_RC" in
        0) echo "$(date): Preflight OK - Gemini login confirmed." | tee -a "$LOG_FILE" ;;
        1) echo "$(date): ABORT - Gemini is signed out. Open the browser (use_browser show_browser), sign in, and rerun. Or rerun with no-gemini." | tee -a "$LOG_FILE"
           exit 1 ;;
        2) echo "$(date): WARN - Gemini login check was inconclusive; going on. Stage 0 skips Gemini if it meets a login wall." | tee -a "$LOG_FILE" ;;
        *) echo "$(date): WARN - the Gemini login check could not run (exit $GATE_RC). Skipping Gemini for this run (no-gemini)." | tee -a "$LOG_FILE"
           RESEARCH_MODE="no-gemini" ;;
    esac
fi

# `|| true`: the script runs under `set -e`, and a usage-log write must never abort a batch.
printf '%s\tRUN\tproject=%s\tslug=%s\tmode=%s\tlog=%s\n' \
    "$(date +%Y-%m-%dT%H:%M:%S)" "$PROJECT_NAME" "$SLUG" "$RESEARCH_MODE" \
    "$(basename "$LOG_FILE")" >> "$QUOTA_LEDGER" || true

run_stage 0 "Multi-Source Research (Exa + Tavily + Gemini)" "$MODEL_RESEARCH" "medium" "
CRITICAL RULES:
1. Do NOT ask for input, confirmation, or permission at any point.
2. Do NOT stop and wait for a response.
3. Make your best judgment on every decision and keep moving.
4. If something fails, log it and continue.
5. Stay in the project directory tree.
6. Use the tools you have. If a tool is refused, note it and continue. Never ask 'should I proceed?'

## TASK: Gather verified research from three sources for slug: $SLUG

### Step 1: Read instructions
Read instructions/00-deep-research.md in full. Follow every phase exactly.
Read reference/source-policy.md and the competitor reference file it names; build the
Tavily exclude_domains list from the competitor file.

### Step 2: Determine the research topic
- Topic slug: $SLUG
- Primary input: $PRIMARY_INPUT
Read $PRIMARY_INPUT and any files in inputs/ to derive RESEARCH_TOPIC (a one-paragraph
topic spec with audience constraints). If a brief already exists at
briefs/${SLUG}-brief.md, use it to sharpen the topic.

### Step 3: Run all three sources
- Phase A: Exa (mcp__exa__web_search_exa / web_fetch_exa) - discovery.
- Phase B: Tavily (mcp__tavily__tavily_search / tavily_extract / tavily_research) -
  precision; always pass the competitor exclude_domains; date-gate platform claims.
- Phase C: Gemini Deep Research via the standalone script
  $GEMINI_RESEARCH_SCRIPT (NOT live MCP browser clicks -
  it attaches over CDP to the already-running superpowers-chrome Chrome and blocks
  until done, spending zero extra tokens on the wait). Do NOT drive Gemini directly via
  mcp__plugin_superpowers-chrome_chrome__use_browser and do NOT use the dedicated
  Gemini MCP - both are superseded by the script.
  RESEARCH_MODE for this run is: $RESEARCH_MODE
  If RESEARCH_MODE is 'no-gemini', SKIP Phase C entirely and note it in the bundle.
  See instructions/00-deep-research.md Phase C for the exact invocation and exit-code
  handling. Exit 1/2 (blocked/no toggle) or exit 3/4/5 after one retry - skip it
  gracefully; do NOT abort; Exa + Tavily must still produce the bundle.

### Step 4: Merge, dedupe, and FACT-CHECK (Phase E)
Merge into research/${SLUG}-research.md in the required section order. Then fact-check
every quote and statistic against its source (fetch/extract the page, confirm verbatim).
Drop or flag anything unverifiable. Record all check results in ## Verification Notes.

### Step 5: Record API usage in the usage log (MANDATORY)
Append exactly one tab-separated line per source to $QUOTA_LEDGER. This is the only
record of API call volume, and it is what you use to size your Exa, Tavily and Firecrawl plans.
Do not skip it, including when a source failed. Format:

  <ISO8601 timestamp>\tCALLS\t<slug>\t<source>\tsearches=<n>\tfetches=<n>\tresearch=<n>\tstatus=<ok|partial|quota|error>\tnote=<short>

One line each for exa, tavily, searxng, ddgs, firecrawl, gemini. Use the real counts you
made, not estimates. Set status=quota on any HTTP 432 or 429 and put the exact code in
note. Append with a single shell command per line; never rewrite the file.

### Output
research/${SLUG}-research.md - must be >= 4 KB and contain ## Direct Quotes AND
## Statistics and Data, with the fact-check recorded in ## Verification Notes.
Print which sources ran, counts of verified vs. dropped items, and any source that failed.
Confirm the $QUOTA_LEDGER lines were appended.
"
echo "$(date): Sleeping $SLEEP_AFTER_SONNET seconds" | tee -a "$LOG_FILE"
sleep $SLEEP_AFTER_SONNET
fi

# ----------------------------------------------------------------------------
# STAGE 1: Topic Development
# ----------------------------------------------------------------------------
if [ "$FROM_STAGE" -le 1 ]; then
run_stage 1 "Topic Development" "$MODEL_SONNET" "medium" "
CRITICAL RULES:
1. Do NOT ask for input, confirmation, or permission at any point.
2. Do NOT stop and wait for a response.
3. Make your best judgment on every decision and keep moving.
4. If something fails, log it and continue.
5. Stay in the project directory tree.
6. Use the tools you have. If a tool is refused, note it and continue. Never ask 'should I proceed?'

## TASK: Develop blog topic brief

### Job context (from router)
- Topic slug (proposed):  $SLUG
- Primary input:          $PRIMARY_INPUT
- Classification:         $CLASSIFICATION

### Step 1: Read instructions
Read instructions/01-topic-development.md in full. Follow every rule.

### Step 2: Read the primary input
Read $PRIMARY_INPUT in full. This is your source material for this job.

If the classification is 'batch_table_row', the manifest at inputs/.manifest.json
contains the specific row data for this job under jobs[$JOB_INDEX].batch_row.
Use that single row, not the whole table.

### Step 3: Read reference files (if they exist)
- reference/batch-template.md
- reference/seasonal-calendar.md
- Any files in research/ from a prior Stage 0 run

### Step 4: Create the brief
Save to: briefs/${SLUG}-brief.md

If the proposed slug from the router fits the topic, keep it. If you derive a
materially better slug from the brief content, update output/.current-slug
with the new slug AND rename the brief file accordingly. Otherwise leave both alone.

### Output
- briefs/${SLUG}-brief.md (or new slug if updated)
- output/.current-slug
Print the topic slug and brief summary.
"

# Re-read slug in case Stage 1 updated it.
if [ -f "$SLUG_FILE" ]; then
    NEW_SLUG=$(cat "$SLUG_FILE" | tr -d '[:space:]')
    if [ -n "$NEW_SLUG" ] && [ "$NEW_SLUG" != "$SLUG" ]; then
        echo "$(date): Slug updated by Stage 1: $SLUG -> $NEW_SLUG" | tee -a "$LOG_FILE"
        _OLD_SLUG="$SLUG"
        SLUG="$NEW_SLUG"
        DATE_SLUG="${DATE_PREFIX}${SLUG}"
        # Stage 1 is told to rename the draft when it changes the slug. It does not always
        # do it (job 3 of the 2026-09-08 batch). Reconcile here: if the new name is absent
        # and the old one is present, move it, so later stages read a file that exists.
        if [ ! -s "$PROJECT_DIR/output/${DATE_SLUG}-draft.md" ] \
           && [ -s "$PROJECT_DIR/output/${DATE_PREFIX}${_OLD_SLUG}-draft.md" ]; then
            mv "$PROJECT_DIR/output/${DATE_PREFIX}${_OLD_SLUG}-draft.md" \
               "$PROJECT_DIR/output/${DATE_SLUG}-draft.md"
            echo "$(date): Renamed draft to match the new slug: ${DATE_PREFIX}${_OLD_SLUG}-draft.md -> ${DATE_SLUG}-draft.md" | tee -a "$LOG_FILE"
        fi
    fi
fi
echo "$(date): Working slug: $SLUG (output: $DATE_SLUG)" | tee -a "$LOG_FILE"
sleep $SLEEP_AFTER_SONNET
fi

# ----------------------------------------------------------------------------
# STAGE 2: Blog Post Writing
# ----------------------------------------------------------------------------
if [ "$FROM_STAGE" -le 2 ]; then
run_stage 2 "Blog Post Writing" "$MODEL_OPUS" "high" "
CRITICAL RULES:
1. Do NOT ask for input, confirmation, or permission at any point.
2. Do NOT stop and wait for a response.
3. Make your best judgment on every decision and keep moving.
4. If something fails, log it and continue.
5. Stay in the project directory tree.
6. Use the tools you have. If a tool is refused, note it and continue. Never ask 'should I proceed?'
7. Use as much time and as many tokens as you need. This is the most important stage.

## TASK: Write the full blog post

### Step 1: Read instructions
Read instructions/02-blog-post-writing.md in full. Follow every rule.

### Step 2: Read the brief
Read briefs/${SLUG}-brief.md.

### Step 3: Read reference files
- personas/writer-profiles.md
- reference/reader-personas.md
- reference/cta-rules.md
- reference/citation-formats.md
- reference/prohibited-phrases.md
- reference/fictional-companies.md
Note any missing files and continue.

### Step 4: Check for research
Check research/ for prior research files. Integrate findings if present.

### Step 5: Write in batch mode
This is an unattended pipeline. No section-by-section feedback. Write the full
draft in one continuous pass. Do not pause for approval.

### Step 6: Conduct research and write
Web search for current data, verify statistics through authoritative sources.
Write the full post: TL;DR, Introduction, Main Content, Conclusion with CTA, FAQ, Links heading.
Use the writer persona named in the brief (default: the first profile in personas/writer-profiles.md).

### Output
Save to: output/${DATE_SLUG}-draft.md
Print word count (main body) and a brief summary.
"
sleep $SLEEP_AFTER_OPUS
fi

# ----------------------------------------------------------------------------
# STAGE 3: FAQ & TL;DR Review
# ----------------------------------------------------------------------------
if [ "$FROM_STAGE" -le 3 ]; then
run_stage 3 "FAQ and TL;DR Review" "$MODEL_OPUS" "high" "
CRITICAL RULES:
1. Do NOT ask for input, confirmation, or permission at any point.
2. Do NOT stop and wait for a response.
3. Make your best judgment on every decision and keep moving.
4. If something fails, log it and continue.
5. Stay in the project directory tree.
6. Use the tools you have. If a tool is refused, note it and continue. Never ask 'should I proceed?'

## TASK: Review and improve FAQ and TL;DR

### Step 1: Read instructions
Read instructions/03-faq-tldr.md in full. Follow every rule.

### Step 2: Read draft
Read output/${DATE_SLUG}-draft.md.

### Step 3: Review and apply
Follow the instruction file. Apply improvements directly to the draft.

### Output
Save to output/${DATE_SLUG}-draft.md (overwrite).
"
sleep $SLEEP_AFTER_OPUS
fi

# ----------------------------------------------------------------------------
# STAGE 4: Titles, Meta, Keywords
# ----------------------------------------------------------------------------
if [ "$FROM_STAGE" -le 4 ]; then
run_stage 4 "Titles, Meta, Keywords" "$MODEL_OPUS" "high" "
CRITICAL RULES:
1. Do NOT ask for input, confirmation, or permission at any point.
2. Do NOT stop and wait for a response.
3. Make your best judgment on every decision and keep moving.
4. If something fails, log it and continue.
5. Stay in the project directory tree.
6. Use the tools you have. If a tool is refused, note it and continue. Never ask 'should I proceed?'

## TASK: Generate titles, meta description, and keywords

### Step 1: Read instructions
Read instructions/04-titles-meta-keywords.md in full. Follow every rule.

### Step 2: Read references
Read reference/prohibited-phrases.md.

### Step 3: Read draft
Read output/${DATE_SLUG}-draft.md.

### Step 4: Generate the title package
Follow the instruction file completely.

### Step 5: Insert at top of draft
Insert the complete title package at the TOP of output/${DATE_SLUG}-draft.md.

### Output
Save to output/${DATE_SLUG}-draft.md (overwrite with title package added).
"
sleep $SLEEP_AFTER_OPUS
fi

# ----------------------------------------------------------------------------
# STAGE 5: URL/Slug Generation
# ----------------------------------------------------------------------------
if [ "$FROM_STAGE" -le 5 ]; then
run_stage 5 "URL/Slug Generation" "$MODEL_SONNET" "low" "
CRITICAL RULES:
1. Do NOT ask for input, confirmation, or permission at any point.
2. Do NOT stop and wait for a response.
3. Make your best judgment on every decision and keep moving.
4. If something fails, log it and continue.
5. Stay in the project directory tree.
6. Use the tools you have. If a tool is refused, note it and continue. Never ask 'should I proceed?'

## TASK: Generate URL slug and Publishing Package

### Step 1: Read instructions
Read instructions/05-url-generation.md in full. Follow every rule.

### Step 2: Read draft
Read the TOP of output/${DATE_SLUG}-draft.md (title package from Stage 4).

### Step 3: Auto-accept and generate slug
Auto-accept Stage 4's recommended titles. Generate 2-3 slug options. Auto-select the recommended.

### Step 4: Insert Publishing Package
Insert at the very TOP of output/${DATE_SLUG}-draft.md, above the Stage 4 title package.

### Step 5: Rename if slug changed
If generated slug differs from ${SLUG}:
1. Rename output/${DATE_SLUG}-draft.md to output/${DATE_PREFIX}[new-slug]-draft.md
2. Rename briefs/${SLUG}-brief.md to briefs/[new-slug]-brief.md (if exists)
3. Write the new slug to output/.current-slug

### Output
Save to output/ with Publishing Package at top.
"

# Re-read slug in case Stage 5 changed it.
if [ -f "$SLUG_FILE" ]; then
    NEW_SLUG=$(cat "$SLUG_FILE" | tr -d '[:space:]')
    if [ -n "$NEW_SLUG" ] && [ "$NEW_SLUG" != "$SLUG" ]; then
        echo "$(date): Slug updated by Stage 5: $SLUG -> $NEW_SLUG" | tee -a "$LOG_FILE"
        _OLD_SLUG="$SLUG"
        SLUG="$NEW_SLUG"
        DATE_SLUG="${DATE_PREFIX}${SLUG}"
        # Stage 5 is told to rename the draft when it changes the slug. It does not always
        # do it (job 3 of the 2026-09-08 batch). Reconcile here: if the new name is absent
        # and the old one is present, move it, so later stages read a file that exists.
        if [ ! -s "$PROJECT_DIR/output/${DATE_SLUG}-draft.md" ] \
           && [ -s "$PROJECT_DIR/output/${DATE_PREFIX}${_OLD_SLUG}-draft.md" ]; then
            mv "$PROJECT_DIR/output/${DATE_PREFIX}${_OLD_SLUG}-draft.md" \
               "$PROJECT_DIR/output/${DATE_SLUG}-draft.md"
            echo "$(date): Renamed draft to match the new slug: ${DATE_PREFIX}${_OLD_SLUG}-draft.md -> ${DATE_SLUG}-draft.md" | tee -a "$LOG_FILE"
        fi
    fi
fi
sleep $SLEEP_AFTER_SONNET_LIGHT
fi

# ----------------------------------------------------------------------------
# STAGE 6: Internal Linking
# ----------------------------------------------------------------------------
if [ "$FROM_STAGE" -le 6 ]; then
run_stage 6 "Internal Linking" "$MODEL_SONNET" "medium" "
CRITICAL RULES:
1. Do NOT ask for input, confirmation, or permission at any point.
2. Do NOT stop and wait for a response.
3. Make your best judgment on every decision and keep moving.
4. If something fails, log it and continue.
5. Stay in the project directory tree.
6. Use the tools you have. If a tool is refused, note it and continue. Never ask 'should I proceed?'

## TASK: Add internal links

### Step 1: Read instructions
Read instructions/06-internal-links.md in full. Follow every rule.

### Step 2: Read draft
Read output/${DATE_SLUG}-draft.md.

### Step 3: Verify post URL
Check if blog URL from Publishing Package is live (web search).

### Step 4: Catalog existing links
Document every existing link - protected from modification.

### Step 5: Find and add internal links
Per instruction file: identify topics, search target site, verify URLs live, apply links, follow density rules.

### Step 6: Add internal link table
Add under the # Links heading per instruction file.

### Output
Save to output/${DATE_SLUG}-draft.md (overwrite).
"
sleep $SLEEP_AFTER_SONNET
fi

# ----------------------------------------------------------------------------
# STAGE 7: External Link Verification
# ----------------------------------------------------------------------------
if [ "$FROM_STAGE" -le 7 ]; then
run_stage 7 "External Link Verification" "$MODEL_SONNET" "low" "
CRITICAL RULES:
1. Do NOT ask for input, confirmation, or permission at any point.
2. Do NOT stop and wait for a response.
3. Make your best judgment on every decision and keep moving.
4. If something fails, log it and continue.
5. Stay in the project directory tree.
6. Use the tools you have. If a tool is refused, note it and continue. Never ask 'should I proceed?'
7. Use as much time and as many tokens as you need. Verify every single link. Do not skip any.

## TASK: Verify and fix all external links and citations

### Step 1: Read instructions
Read instructions/07-external-links.md in full. Follow every rule.

### Step 2: Read references
- reference/competitors.md
- reference/citation-formats.md

### Step 3: Read draft
Read output/${DATE_SLUG}-draft.md.

### Step 4-7: Per instruction file
Extract claims, verify each via tiered system, fix issues directly, add verification table.

### Output
Save to output/${DATE_SLUG}-draft.md (overwrite).
"
sleep $SLEEP_AFTER_SONNET
fi

# ----------------------------------------------------------------------------
# STAGE 8: Final Link Check
# ----------------------------------------------------------------------------
if [ "$FROM_STAGE" -le 8 ]; then
run_stage 8 "Link Checking - Final" "$MODEL_OPUS" "medium" "
CRITICAL RULES:
1. Do NOT ask for input, confirmation, or permission at any point.
2. Do NOT stop and wait for a response.
3. Make your best judgment on every decision and keep moving.
4. If something fails, log it and continue.
5. Stay in the project directory tree.
6. Use the tools you have. If a tool is refused, note it and continue. Never ask 'should I proceed?'
7. Use as much time and as many tokens as you need. This is the final quality gate.

## TASK: Independent final link verification

### Step 1: Read instructions
Read instructions/08-check-links.md in full. Follow every rule.

### Step 2: Read references
- reference/citation-formats.md

### Step 3: Read draft
Read output/${DATE_SLUG}-draft.md - the near-final draft.

### Step 4-8: Per instruction file
Extract all links, test independently, cross-check Stage 7, fix issues, add Link Check Report.

### Output
Save final draft to output/${DATE_SLUG}-draft.md.
Print Publication Status and full link check summary.
"
fi

# ----------------------------------------------------------------------------
# STAGE 9: QC Report (scripts/qc.sh --append)
# ----------------------------------------------------------------------------
if [ "$JOB_ABORT" -eq 1 ]; then
  echo "$(date): STAGE 9 SKIPPED - job aborted" | tee -a "$LOG_FILE"
elif [ "$FROM_STAGE" -le 9 ]; then
  if [ -f "$QC_SCRIPT" ]; then
    DRAFT_FILE="$PROJECT_DIR/output/${DATE_SLUG}-draft.md"
    if [ -f "$DRAFT_FILE" ]; then
      echo "" | tee -a "$LOG_FILE"
      echo "----------------------------------------------------------------" | tee -a "$LOG_FILE"
      echo "$(date): STAGE 9 - QC Report [qc.sh]" | tee -a "$LOG_FILE"
      echo "----------------------------------------------------------------" | tee -a "$LOG_FILE"
      set +e
      # Stages 7 and 8 often write their verification notes with H4 headings, and
      # the QC fails any H4. Turn H4 into H3 in the internal notes only: everything
      # after the "# Links" heading. The post body above it is never touched.
      python3 - "$DRAFT_FILE" <<'H4FIX' 2>&1 | tee -a "$LOG_FILE"
import re, sys
p = sys.argv[1]
lines = open(p).read().split("\n")
start = next((i for i, l in enumerate(lines) if re.match(r"^# Links\s*$", l)), None)
if start is not None:
    n = 0
    for i in range(start, len(lines)):
        if lines[i].startswith("#### "):
            lines[i] = "### " + lines[i][5:]; n += 1
    if n:
        open(p, "w").write("\n".join(lines))
        print(f"H4 fix: {n} heading(s) in the internal notes changed to H3")
H4FIX
      bash "$QC_SCRIPT" "$DRAFT_FILE" --append 2>&1 | tee -a "$LOG_FILE"
      QC_EXIT=${PIPESTATUS[0]}
      set -e
      if [ "$QC_EXIT" -eq 0 ]; then
        echo "$(date): COMPLETED - Stage 9" | tee -a "$LOG_FILE"
      else
        echo "$(date): Stage 9 QC failed (exit $QC_EXIT) - continuing to next job" | tee -a "$LOG_FILE"
      fi
    else
      echo "$(date): Stage 9 skipped - draft not found at $DRAFT_FILE" | tee -a "$LOG_FILE"
    fi
  else
    echo "$(date): ERROR - Stage 9 skipped: QC script not found at $QC_SCRIPT" | tee -a "$LOG_FILE"
  fi
fi

# ----------------------------------------------------------------------------
# STAGE 10: Template cover (only when cover-generator/ is set up)
# Pure script, no Claude call, so it runs headless. Writes SVG/PNG/WebP to
# cover-generator/output/<date>-<slug>/ from the draft's H1 SEO title
# (colon = sub), falling back to the H2 article title, then the H3. Turn it off with
# "Template cover: off" in reference/image-settings.md. A failure never stops
# the job; it is logged and the cover can be made by hand later.
# Stage 11 (AI cover photos, Magnific) is interactive only. See
# instructions/11-ai-cover-image.md.
# ----------------------------------------------------------------------------
IMG_SETTINGS="$PROJECT_DIR/reference/image-settings.md"
img_setting() { grep -i -m1 -E "^\s*-?\s*\*\*$1:\*\*" "$IMG_SETTINGS" 2>/dev/null | sed -E 's/.*\*\*[^*]+:\*\*[[:space:]]*//' | awk '{print tolower($1)}' || true; }
COVER_SCRIPT="$PROJECT_DIR/cover-generator/scripts/covers_from_drafts.py"
if [ "$JOB_ABORT" -eq 0 ] && [ -f "$COVER_SCRIPT" ] && [ "$(img_setting 'Template cover')" != "off" ]; then
  DRAFT_FILE="$PROJECT_DIR/output/${DATE_SLUG}-draft.md"
  if [ -f "$DRAFT_FILE" ]; then
    echo "" | tee -a "$LOG_FILE"
    echo "----------------------------------------------------------------" | tee -a "$LOG_FILE"
    echo "$(date): STAGE 10 - Template cover [cover-generator]" | tee -a "$LOG_FILE"
    echo "----------------------------------------------------------------" | tee -a "$LOG_FILE"
    set +e
    (cd "$PROJECT_DIR/cover-generator" && python3 "$COVER_SCRIPT" --only "$SLUG") 2>&1 | tee -a "$LOG_FILE"
    COVER_EXIT=${PIPESTATUS[0]}
    set -e
    if [ "$COVER_EXIT" -eq 0 ]; then
      echo "$(date): COMPLETED - Stage 10" | tee -a "$LOG_FILE"
    else
      echo "$(date): Stage 10 cover failed (exit $COVER_EXIT) - continuing. Make it by hand: see cover-generator/README.md" | tee -a "$LOG_FILE"
    fi
  fi
fi

    echo "" | tee -a "$LOG_FILE"
    if [ "$JOB_ABORT" -eq 1 ]; then
        echo "$(date): JOB $JOB_ID ABORTED - $SLUG (a stage produced no file, or the session limit closed)" | tee -a "$LOG_FILE"
        JOBS_FAILED=$((JOBS_FAILED + 1))
    else
        echo "$(date): JOB $JOB_ID COMPLETE - $SLUG" | tee -a "$LOG_FILE"
        JOBS_RUN=$((JOBS_RUN + 1))
    fi

    # Topic slug -> final slug. collect-post.py reads this to find research and
    # briefs filed under the topic slug. Written for aborted jobs too, so a
    # half-finished draft can still be traced to its research.
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date +%Y-%m-%dT%H:%M:%S)" "$PROJECT_NAME" "$TOPIC_SLUG" "$SLUG" \
        "${PUBLISH_DATE:-}" >> "$SLUG_MAP" || true

    # ----------------------------------------------------------------------------
    # COLLECT: move everything for this post into posts/<date>-<slug>/
    # The draft, sources, AI photos, covers, brief and research end up in one flat
    # folder. Later steps (a re-made cover, Stage 11) look there first. Never overwrites; a failure is logged and never stops the job.
    # Runs after the slug map line above, so research filed under the topic slug is found.
    # An undated post (no publish date) has no posts/ folder and stays in output/.
    # ----------------------------------------------------------------------------
    if [ "$JOB_ABORT" -eq 0 ] && [ -f "$COLLECT_SCRIPT" ] \
         && [[ "$DATE_SLUG" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}- ]]; then
      echo "" | tee -a "$LOG_FILE"
      echo "$(date): COLLECT - posts/${DATE_SLUG}/" | tee -a "$LOG_FILE"
      set +e
      python3 "$COLLECT_SCRIPT" "$PROJECT_DIR" --date-slug "$DATE_SLUG" --slug-map "$SLUG_MAP" --apply 2>&1 | tee -a "$LOG_FILE"
      COLLECT_EXIT=${PIPESTATUS[0]}
      set -e
      [ "$COLLECT_EXIT" -eq 0 ] || echo "$(date): collect failed (exit $COLLECT_EXIT) - files left in place" | tee -a "$LOG_FILE"
    fi

    JOB_INDEX=$((JOB_INDEX + 1))

    # A closed usage window does not reopen inside this run. Stop rather than burn the
    # rest of the queue on no-op stages.
    if [ "$SESSION_LIMIT" -eq 1 ]; then
        echo "$(date): STOPPING QUEUE - session limit hit. $((JOB_COUNT - JOB_INDEX)) job(s) not started." | tee -a "$LOG_FILE"
        break
    fi

    # Sleep between jobs unless this was the last one.
    if [ "$JOB_INDEX" -lt "$JOB_COUNT" ] && [ "$SLEEP_BETWEEN_JOBS" -gt 0 ]; then
        echo "$(date): Sleeping ${SLEEP_BETWEEN_JOBS}s before next job" | tee -a "$LOG_FILE"
        sleep "$SLEEP_BETWEEN_JOBS"
    fi
done

# ============================================================================
# FINAL REPORT
# ============================================================================
echo "" | tee -a "$LOG_FILE"
echo "================================================================" | tee -a "$LOG_FILE"
echo "$(date): PIPELINE COMPLETE - $PROJECT_NAME" | tee -a "$LOG_FILE"
echo "================================================================" | tee -a "$LOG_FILE"
echo "Jobs run:    $JOBS_RUN of $JOB_COUNT" | tee -a "$LOG_FILE"
echo "Jobs failed: $JOBS_FAILED" | tee -a "$LOG_FILE"
if [ "$SESSION_LIMIT" -eq 1 ]; then
    echo "STOPPED EARLY: the Claude session limit closed mid-run. Rerun to finish the queue." | tee -a "$LOG_FILE"
fi
if [ "$JOB_INDEX" -lt "$JOB_COUNT" ]; then
    echo "Not started: $((JOB_COUNT - JOB_INDEX)) job(s)" | tee -a "$LOG_FILE"
fi
echo "Project dir: $PROJECT_DIR" | tee -a "$LOG_FILE"
echo "Output dir:  $PROJECT_DIR/output/ (in progress)" | tee -a "$LOG_FILE"
echo "Posts dir:   $PROJECT_DIR/posts/ (one folder per finished post)" | tee -a "$LOG_FILE"
echo "Manifest:    $MANIFEST_FILE" | tee -a "$LOG_FILE"
echo "Log:         $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Review each post folder in posts/ and its draft's Publication Status." | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"
echo "----------------------------------------------------------------" | tee -a "$LOG_FILE"
echo "MODEL/EFFORT AUDIT (actual_model is API-confirmed via modelUsage; requested_effort is the flag passed, not independently API-verified)" | tee -a "$LOG_FILE"
echo "----------------------------------------------------------------" | tee -a "$LOG_FILE"
column -s, -t "$AUDIT_FILE" | tee -a "$LOG_FILE"
echo "Full audit CSV: $AUDIT_FILE" | tee -a "$LOG_FILE"
echo "Raw per-stage API responses: $JSON_DIR" | tee -a "$LOG_FILE"

# Report any aborted files from the router.
ABORTED_COUNT=$(manifest_count aborted_files 2>/dev/null || echo "0")
if [ "$ABORTED_COUNT" -gt 0 ]; then
    echo "" | tee -a "$LOG_FILE"
    echo "WARNING: $ABORTED_COUNT input file(s) were aborted by the router - see manifest for reasons." | tee -a "$LOG_FILE"
fi
echo "================================================================" | tee -a "$LOG_FILE"
