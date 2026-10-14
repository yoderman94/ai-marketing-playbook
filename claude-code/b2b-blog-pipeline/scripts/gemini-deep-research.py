#!/usr/bin/env python3
# RETIRED from blog Stage 0 on 2026-10-14. Kept for manual use only.
"""
gemini-deep-research.py — drive Gemini Deep Research via Playwright, attached
over CDP to the already-running superpowers-chrome browser. Zero Claude
tokens: this is a plain script, not an agent loop, so it replaces the
per-click MCP tool calls Stage 0's Phase C used to spend on pure
clicking/polling.

HARD RULE — never launch Chrome yourself. Raw-launching Chrome on the live
superpowers-chrome profile with mismatched cookie-encryption flags corrupts
Google's rotating session cookies and logs the account out (see
gemini-auth-check.sh). This script only ever connects to a Chrome that's
already running (started by the superpowers-chrome MCP) — if it can't
connect, that's a hard failure, never a "launch it for you" fallback.

Usage:
    python3 gemini-deep-research.py --topic "..." --out research/slug-research.md
    python3 gemini-deep-research.py --topic-file /path/to/prompt.txt --out ...

Exit codes:
    0  success — report + source lists written to --out
    1  STAGE0_GEMINI_BLOCKED   (login wall, captcha, or Chrome unreachable)
    2  STAGE0_NO_DEEP_RESEARCH_MODE
    3  plan confirmation ("Start research") never appeared
    4  poll timeout — still researching past --timeout-minutes
    5  extraction failed (report too short / no cited sources)

These exit codes and log-line tags match the STAGE0_GEMINI_BLOCKED /
STAGE0_NO_DEEP_RESEARCH_MODE convention already used in
00-deep-research.md's Phase C, so a caller can skip Gemini and continue with
Exa/Tavily the same way it does today, without needing new failure-handling
logic.
"""

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

GEMINI_URL = "https://gemini.google.com/app"
DEFAULT_CDP_PORT = 9222

PLAN_CONFIRMATION_TIMEOUT_SECONDS = 300  # plan generation can take well over 90 s
POLL_INTERVAL_SECONDS = 20
MIN_REPORT_CHARS = 2000

# Screenshots and HTML of a failed run. They show a signed-in Google page, so they
# stay under the gitignored logs/ folder and never go anywhere else.
FAILURE_DIR = Path(os.environ.get("BLOG_LOG_DIR") or Path(__file__).resolve().parent.parent / "logs") / "gemini-failures"

# Where the superpowers-chrome MCP records the debug port of the Chrome it runs.
PROFILE_META_DIRS = (
    Path.home() / "Library" / "Caches" / "superpowers" / "browser-profiles",   # macOS
    Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "superpowers" / "browser-profiles",  # Linux
)


def discover_cdp_port(profile):
    """CHROME_CDP_PORT, else the port in the superpowers-chrome profile metadata, else 9222."""
    env = os.environ.get("CHROME_CDP_PORT")
    if env and env.isdigit():
        return int(env)
    for d in PROFILE_META_DIRS:
        meta = d / f"{profile}.meta.json"
        try:
            port = json.loads(meta.read_text()).get("port")
            if isinstance(port, int):
                return port
        except (OSError, ValueError):
            continue
    return DEFAULT_CDP_PORT

BOT_CHALLENGE_PHRASES = ("unusual traffic", "verify you're not a robot", "captcha")


def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


class ResearchFailure(Exception):
    def __init__(self, exit_code, tag, detail=""):
        super().__init__(f"{tag}: {detail}" if detail else tag)
        self.exit_code = exit_code
        self.tag = tag
        self.detail = detail


def save_failure_artifacts(page, tag):
    if page is None:
        return
    FAILURE_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    base = FAILURE_DIR / f"{tag}-{ts}"
    try:
        page.screenshot(path=str(base) + ".png", full_page=True)
        (base.with_suffix(".html")).write_text(page.content())
        log(f"Saved failure artifacts: {base}.png / .html")
    except Exception as e:
        log(f"Could not save failure artifacts ({e})")


def connect(cdp_port):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        raise ResearchFailure(
            1, "STAGE0_GEMINI_BLOCKED",
            "the playwright Python package is missing. Install it with: "
            "python3 -m pip install playwright",
        )

    pw = sync_playwright().start()
    try:
        browser = pw.chromium.connect_over_cdp(f"http://localhost:{cdp_port}")
    except Exception as e:
        pw.stop()
        raise ResearchFailure(
            1, "STAGE0_GEMINI_BLOCKED",
            f"can't reach Chrome on port {cdp_port} — is superpowers-chrome "
            f"running? ({e})",
        )
    return pw, browser


def check_body_for_challenge(page):
    text = page.locator("body").inner_text(timeout=10000).lower()
    if any(p in text for p in BOT_CHALLENGE_PHRASES):
        raise ResearchFailure(1, "STAGE0_GEMINI_BLOCKED", "bot-challenge text found on page")
    return text


def check_login(page):
    try:
        page.wait_for_selector(
            "div[contenteditable='true'], textarea", timeout=15000,
        )
    except Exception:
        raise ResearchFailure(1, "STAGE0_GEMINI_BLOCKED", "no compose box found — login wall")
    check_body_for_challenge(page)


def enable_deep_research(page):
    """Deep Research lives at Upload & tools -> More tools -> Deep research,
    NOT in the model picker (that dropdown, labeled e.g. "Thinking", only
    switches between Flash/Thinking/Pro model tiers). Verified against the
    live DOM 2026-08-24. 2026-10-02: "More tools" became a gem-menu-item
    submenu that opens on click, not hover. The engaged check is now the
    composer placeholder, because the menu label also matched the old check."""
    for attempt in range(3):
        try:
            page.locator("[aria-label='Upload & tools']").click(timeout=8000)
            page.wait_for_timeout(800)
            page.locator("gem-menu-item", has_text="More tools").first.click(timeout=5000)
            page.wait_for_timeout(1000)
            page.locator("gem-menu-item", has_text="Deep research").first.click(timeout=5000)
            page.wait_for_timeout(1500)
            # Confirm the toggle engaged: the composer placeholder changes.
            page.locator(
                "div.ql-editor[data-placeholder='What do you want to research?']"
            ).first.wait_for(timeout=5000)
            return
        except Exception:
            page.keyboard.press("Escape")
            page.wait_for_timeout(1500)
    raise ResearchFailure(2, "STAGE0_NO_DEEP_RESEARCH_MODE", "toggle not found after 3 attempts")


def submit_topic(page, topic):
    box = page.locator("div[contenteditable='true'], textarea").first
    box.click()
    box.fill(topic)
    box.press("Enter")


def confirm_research_plan(page):
    """Gemini renders a research PLAN first, with its own "Start research"
    button — a separate step from submitting the topic. Collapsing these two
    steps is the single most likely way to produce a silent multi-minute
    hang, so this gets its own short timeout."""
    try:
        start_btn = page.get_by_role("button", name="Start research")
        start_btn.wait_for(timeout=PLAN_CONFIRMATION_TIMEOUT_SECONDS * 1000)
    except Exception:
        raise ResearchFailure(
            3, "STAGE0_PLAN_CONFIRMATION_TIMEOUT",
            f"'Start research' button never appeared within "
            f"{PLAN_CONFIRMATION_TIMEOUT_SECONDS}s",
        )
    start_btn.click()


def poll_until_done(page, timeout_minutes):
    """The only reliable completion signal, confirmed against two real runs,
    is the "Sources used in the report" heading. Do NOT use a "Thoughts"
    section or the absence of words like "researching" as a fallback — the
    live "Show thinking" trace contains the word "Thoughts" (and reads as
    calm, settled prose) throughout the ENTIRE run, well before the report
    is actually finished. A fallback here caused a real false-positive: the
    script called it done ~5.5 min in and failed extraction, while the
    report didn't actually finish for several more minutes."""
    deadline = time.time() + timeout_minutes * 60
    while time.time() < deadline:
        text = check_body_for_challenge(page)
        if "sources used in the report" in text.lower():
            return
        remaining = int(deadline - time.time())
        log(f"  still researching... ({remaining}s left before timeout)")
        page.wait_for_timeout(POLL_INTERVAL_SECONDS * 1000)
    raise ResearchFailure(4, "STAGE0_POLL_TIMEOUT", f"still researching after {timeout_minutes} min")


def extract_report(page):
    """Text-anchor parsing, not CSS selectors — a live run showed the actual
    DOM has no data-test-id hooks for the report container. The three anchor
    phrases below are stable, human-visible Gemini UI labels."""
    full_text = page.locator("body").inner_text(timeout=10000)

    used_anchor = "Sources used in the report"
    reviewed_anchor = "Sources read but not used in the report"
    thoughts_anchor = "\nThoughts\n"

    if used_anchor not in full_text:
        raise ResearchFailure(5, "STAGE0_EXTRACTION_FAILED", "no 'Sources used' section found")

    # Report body: from "Share & Export" / "Create" toolbar (whichever comes
    # last before the body) to the "Sources used" anchor.
    body_start = 0
    for marker in ("Share & Export", "Create\n"):
        idx = full_text.find(marker)
        if idx != -1:
            body_start = max(body_start, idx + len(marker))
    body_end = full_text.find(used_anchor)
    report_body = full_text[body_start:body_end].strip()

    if len(report_body) < MIN_REPORT_CHARS:
        raise ResearchFailure(5, "STAGE0_EXTRACTION_FAILED",
                               f"report body only {len(report_body)} chars")

    reviewed_idx = full_text.find(reviewed_anchor)
    thoughts_idx = full_text.find(thoughts_anchor)

    if reviewed_idx != -1:
        used_block = full_text[body_end + len(used_anchor):reviewed_idx].strip()
        end_of_reviewed = thoughts_idx if thoughts_idx != -1 else len(full_text)
        reviewed_block = full_text[reviewed_idx + len(reviewed_anchor):end_of_reviewed].strip()
    else:
        end_of_used = thoughts_idx if thoughts_idx != -1 else len(full_text)
        used_block = full_text[body_end + len(used_anchor):end_of_used].strip()
        reviewed_block = ""

    return report_body, used_block, reviewed_block


def format_source_block(raw_block):
    """Gemini's source list renders as alternating (domain, title) lines,
    e.g. "digitalapplied.com\nConversion Rate Benchmarks... - Digital
    Applied\nOpens in a new window". Turn that into a plain markdown list —
    no URLs are recoverable from rendered text alone, so this keeps the
    domain + title pairing, which is enough for Claude's fact-check pass to
    search for and re-verify against the live page."""
    lines = [l.strip() for l in raw_block.splitlines() if l.strip() and l.strip() != "Opens in a new window"]
    out = []
    i = 0
    while i < len(lines) - 1:
        domain, title = lines[i], lines[i + 1]
        out.append(f"- **{domain}** — {title}")
        i += 2
    return "\n".join(out) if out else "(none)"


def run(topic, out_path, cdp_port, timeout_minutes):
    pw = browser = page = None
    try:
        pw, browser = connect(cdp_port)
        if not browser.contexts:
            raise ResearchFailure(1, "STAGE0_GEMINI_BLOCKED", "Chrome has no open browser context")
        context = browser.contexts[0]
        page = context.new_page()
        page.goto(GEMINI_URL, wait_until="domcontentloaded", timeout=30000)
        page.wait_for_timeout(3000)

        log("Checking login...")
        check_login(page)

        log("Enabling Deep Research mode...")
        enable_deep_research(page)

        log("Submitting topic...")
        submit_topic(page, topic)

        log("Waiting for research plan confirmation...")
        confirm_research_plan(page)

        log(f"Research running — polling up to {timeout_minutes} min...")
        poll_until_done(page, timeout_minutes)

        log("Extracting report...")
        report_body, used_raw, reviewed_raw = extract_report(page)

        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(
            f"{report_body}\n\n"
            f"## Sources Used\n{format_source_block(used_raw)}\n\n"
            f"## Sources Reviewed But Not Cited\n{format_source_block(reviewed_raw)}\n"
        )
        log(f"Wrote {out_path} ({len(report_body)} chars body)")
        return 0

    except ResearchFailure as e:
        save_failure_artifacts(page, e.tag)
        log(f"{e.tag}: {e.detail}")
        return e.exit_code

    finally:
        if pw is not None:
            # Disconnect only. connect_over_cdp shares the live
            # superpowers-chrome instance; browser.close() here does NOT
            # kill that process, it only ends this script's CDP session.
            try:
                browser.close()
            except Exception:
                pass
            pw.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--topic", help="Research topic/prompt text")
    parser.add_argument("--topic-file", help="Path to a file containing the topic/prompt text")
    parser.add_argument("--out", required=True, help="Output markdown file path")
    parser.add_argument("--cdp-port", type=int, default=None,
                        help="Chrome debug port (default: CHROME_CDP_PORT, else the "
                             "superpowers-chrome profile metadata, else 9222)")
    parser.add_argument("--profile", default=os.environ.get("CHROME_WS_PROFILE", "superpowers-chrome"),
                        help="superpowers-chrome profile name used to find the port")
    parser.add_argument("--timeout-minutes", type=int, default=35)
    args = parser.parse_args()

    if not args.topic and not args.topic_file:
        parser.error("one of --topic or --topic-file is required")
    topic = args.topic or Path(args.topic_file).read_text().strip()

    port = args.cdp_port or discover_cdp_port(args.profile)
    log(f"Connecting to Chrome on port {port}")
    return run(topic, Path(args.out), port, args.timeout_minutes)


if __name__ == "__main__":
    sys.exit(main())
