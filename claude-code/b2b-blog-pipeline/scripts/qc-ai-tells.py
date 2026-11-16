#!/usr/bin/env python3
"""
AI-tell check for blog drafts: one shared file that every QC wrapper and the writer prompt read.

Keep the rules in this file only, not in a pipeline's prohibited-phrases.md, so copies can't drift.

Three tiers:
  clean  Paste leftovers that are never right in a post: hidden characters, ChatGPT citation
         markers, utm_source=chatgpt.com. With --clean the file is fixed in place and each fix is
         logged. Without --clean they count as FAIL.
  fail   Chatbot text a person must rewrite ("Sure! Here's a draft", "I'd be happy to"). The QC
         wrapper turns it into a FAIL status.
  warn   Sentence patterns, stock headings, lists of three, bold-label bullets. Never blocks.

Scope: clean runs on the whole file. fail and warn read the post body only: from the TL;DR or Quick
Summary heading, else "## Introduction" (else the top of the file), to the first "# Links" heading or a QC report block.
Text inside double quotes or a blockquote is example dialogue and passes.

Usage:
  <this file> <draft.md> [--clean] [--markdown]   scan a draft
  <this file> --rules                             print the rules for a writer prompt
Output: JSON (default) or a markdown section ending in "AI-tell status: PASS|WARN|FAIL".
Exit: 0 ran, 1 file error, 2 bad arguments.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# ---------------- clean tier ----------------
INVISIBLE = {
    "​": "zero-width space", "‌": "zero-width non-joiner", "‍": "zero-width joiner",
    "⁠": "word joiner", "﻿": "byte order mark", "­": "soft hyphen",
}
SPACES = {" ": "non-breaking space", " ": "narrow non-breaking space", " ": "figure space"}
PRIVATE_USE = re.compile(r"[-]")  # ChatGPT wraps citations in private-use characters
CITE_PATTERNS = [
    ("oaicite contentReference", re.compile(r"[ \t]*:?contentReference\[oaicite:\d+\]\{index=\d+\}")),
    ("oaicite marker", re.compile(r"[ \t]*\[oaicite:\d+\]")),
    ("ChatGPT source marker", re.compile(r"[ \t]*【\d+(?::\d+)?†[^】]{0,80}】")),
    ("ChatGPT cite token", re.compile(r"[ \t]*\b(?:cite|filecite|navlist)(?:turn\d+(?:search|news|view|fetch|file|image)\d+)+")),
    ("ChatGPT turn token", re.compile(r"[ \t]*\bturn\d+(?:search|news|view|fetch|file|image)\d+\b")),
]
_AI_SRC = r"utm_source=(?:chatgpt\.com|openai|chatgpt|perplexity(?:\.ai)?|copilot\.microsoft\.com|gemini\.google\.com)"
UTM_CHATGPT = re.compile(r"[?&]" + _AI_SRC)
UTM_MID = re.compile(r"([?&])" + _AI_SRC + r"&")  # ?utm_source=chatgpt.com&x=1 -> ?x=1
UTM_END = re.compile(r"[?&]" + _AI_SRC + r"(?![\w&=])")  # last or only parameter

# ---------------- fail tier ----------------
FAIL_TERMS = [  # only text no human writes in a finished post (checked on 87 finished posts, 2026-11-16: 0 hits)
    "here's a draft", "here is a draft", "here's the draft", "here's the revised", "here is the revised",
    "here's a revised", "here's an updated", "here is an updated", "i've revised", "i have revised", "i've rewritten",
    "would you like me to", "as of my knowledge cutoff", "my knowledge cutoff", "my training data",
    "i don't have access to real-time", "i do not have access to real-time", "as a large language model",
    "[citation needed]", "[source]", "[link]", "[insert", "lorem ipsum",
]
FAIL_LINE_START = re.compile(r"^\s*(?:[-*]\s+)?(?:sure|certainly|absolutely|of course|great)[!,.]\s", re.I)

# ---------------- warn tier ----------------
WARN_TERMS = [
    # chatbot-sounding, but a person can write them in a real call to action, so warn, never fail
    "i'd be happy to", "i would be happy to", "happy to help", "feel free to ask", "let me know if you",
    "here's your", "here is your", "i've updated the", "i can't access", "i cannot access",
    "in this article", "in this post", "in this guide", "in this blog", "we'll explore", "we will explore",
    "we'll dive", "ultimately", "in essence", "at its core", "it's important to remember", "it's important to understand",
    "let's be honest", "let's face it", "the truth is", "picture this", "imagine a world", "in a world where",
    "more than ever", "buckle up", "without further ado", "rest assured", "look no further",
    "take it to the next level", "next level", "elevate your", "the secret sauce", "the key takeaway",
    "a game changer", "stay ahead of the curve", "ever-changing", "it goes without saying", "needless to say",
]
WARN_PATTERNS = [
    ("it's not X, it's Y", re.compile(r"\b(?:it's|it is|this is|that's|that is)\s+not\s+(?:just\s+)?(?:about\s+)?[^.;!?]{1,60}?[,;:—-]\s*(?:it's|it is|this is|that's)\b", re.I)),
    ("this isn't X. It's Y.", re.compile(r"\b(?:this|that|it)\s+(?:isn't|is not|wasn't|was not)\s+(?:just\s+)?(?:about\s+)?[^.!?]{1,60}[.!]\s+(?:it's|it is|it was)\b", re.I)),
    ("rhetorical 'The result?'", re.compile(r"\bthe\s+(?:result|answer|catch|kicker|truth|takeaway|upshot|bottom line)\?", re.I)),
]
STOCK_HEADINGS = {
    "conclusion", "in conclusion", "final thoughts", "key takeaways", "takeaways", "wrapping up", "wrap-up",
    "the bottom line", "bottom line", "closing thoughts", "summary", "in summary", "the takeaway", "final words",
}
TRIPLET = re.compile(r"\b[\w'-]+(?: [\w'-]+){0,2}, [\w'-]+(?: [\w'-]+){0,2},? (?:and|or) [\w'-]+(?: [\w'-]+){0,2}\b")
BOLD_LABEL = re.compile(r"^\s*(?:[-*]|\d+\.)\s+\*\*[^*]{1,60}?(?::\*\*|\*\*:)")
QUOTED = re.compile(r"\"[^\"]*\"|“[^”]*”")
QC_BLOCK = re.compile(r"^##?#?\s+(?:Stage 3 QC Report|QC Report|External Link Check)", re.I)  # report blocks are not copy


def body_range(lines: list[str]) -> tuple[int, int]:
    intro = next((i for i, l in enumerate(lines) if re.match(r"^##\s+Introduction\b", l)), None)
    # The TL;DR (or Quick Summary) sits above the Introduction and is published copy: scan it too.
    summ = next((i for i, l in enumerate(lines) if re.match(r"^#{2,3}\s+(?:TL;?DR|Quick Summary)\b", l, re.I)), None)
    start = min(x for x in (intro, summ, len(lines)) if x is not None) if (intro is not None or summ is not None) else 0
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if QC_BLOCK.match(lines[i]) or re.match(r"^#\s+(Links|Internal Notes|Sources)\b", lines[i], re.I):
            end = i
            break
    return start, end


def clean(text: str) -> tuple[str, list[dict]]:
    fixes = []

    def note(kind, n):
        if n:
            fixes.append({"fix": kind, "count": n})

    for ch, name in INVISIBLE.items():
        note("removed " + name, text.count(ch))
        text = text.replace(ch, "")
    for ch, name in SPACES.items():
        note("replaced " + name, text.count(ch))
        text = text.replace(ch, " ")
    for name, rx in CITE_PATTERNS:
        text, n = rx.subn("", text)
        note("removed " + name, n)
    text, n = PRIVATE_USE.subn("", text)
    note("removed private-use character", n)
    text, n1 = UTM_MID.subn(r"\1", text)
    text, n2 = UTM_END.subn("", text)
    note("removed AI utm_source tag", n1 + n2)
    return text, fixes


def leftovers(text: str) -> list[dict]:
    """Paste leftovers still in the text (used when --clean is off)."""
    out = []
    for ch, name in {**INVISIBLE, **SPACES}.items():
        if ch in text:
            out.append({"term": name, "count": text.count(ch)})
    for name, rx in CITE_PATTERNS[:1] + CITE_PATTERNS[2:] + [("private-use character", PRIVATE_USE), ("AI utm_source tag", UTM_CHATGPT)]:
        n = len(rx.findall(text))
        if n:
            out.append({"term": name, "count": n})
    return out


def scan(text: str) -> tuple[list, list, dict]:
    lines = text.split("\n")
    s, e = body_range(lines)
    fails, warns = [], []
    words = triplets = bold = 0
    in_fence = False
    for i in range(s, e):
        raw = lines[i]
        if raw.strip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence or raw.lstrip().startswith(">") or raw.lstrip().startswith("|"):
            continue
        line = QUOTED.sub('""', raw)
        low = line.lower().replace("’", "'")
        n = i + 1
        h = re.match(r"^(#{2,4})\s+(.*)", raw)
        if h:
            title = re.sub(r"[^a-z -]", "", h.group(2).lower()).strip()
            if title in STOCK_HEADINGS:
                warns.append({"rule": "stock heading", "line": n, "text": raw.strip()[:80]})
            continue
        words += len(re.findall(r"\b\w+\b", line))
        if FAIL_LINE_START.match(line):
            fails.append({"rule": "chatbot opener", "line": n, "text": raw.strip()[:80]})
        for t in FAIL_TERMS:
            if t in low:
                fails.append({"rule": "chatbot leftover: " + t, "line": n, "text": raw.strip()[:80]})
        for t in WARN_TERMS:
            if re.search(r"\b" + re.escape(t) + r"\b", low):
                warns.append({"rule": t, "line": n, "text": raw.strip()[:80]})
        for name, rx in WARN_PATTERNS:
            if rx.search(line.replace("’", "'")):
                warns.append({"rule": name, "line": n, "text": raw.strip()[:80]})
        triplets += len(TRIPLET.findall(line))
        if BOLD_LABEL.match(raw):
            bold += 1
    limit_trip = max(3, words // 100)  # 1 per 100 words: warns on 7 of 101 posts (2026-11-16); 1 per 150 warned on 47
    if triplets > limit_trip:
        warns.append({"rule": "lists of three", "line": 0,
                      "text": "%d 'A, B and C' lists, limit %d (1 per 100 words) for %d words. Use 2 or 4 items when that's what the facts are." % (triplets, limit_trip, words)})
    if bold > 10:
        warns.append({"rule": "bold-label bullets", "line": 0,
                      "text": "%d '**Label:** text' bullets. Keep them for lists of real named items only." % bold})
    return fails, warns, {"body_words": words, "triplets": triplets, "bold_label_bullets": bold}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("draft", nargs="?")
    ap.add_argument("--rules", action="store_true", help="print the rules for a writer prompt and exit")
    ap.add_argument("--clean", action="store_true", help="fix paste leftovers in place and log each fix")
    ap.add_argument("--markdown", action="store_true", help="print a markdown report section, not JSON")
    a = ap.parse_args()
    if a.rules:
        print(writer_rules())
        return 0
    if not a.draft:
        ap.error("give a draft file, or --rules")
    p = Path(a.draft)
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as ex:
        print("%s: %s" % (Path(__file__).stem, ex), file=sys.stderr)
        return 1
    fixes, left = [], []
    if a.clean:
        new, fixes = clean(text)
        if new != text:
            p.write_text(new, encoding="utf-8")
            text = new
    else:
        left = leftovers(text)
    fails, warns, stats = scan(text)
    fails = [{"rule": "paste leftover: " + x["term"], "line": 0, "text": "%d found (run with --clean)" % x["count"]} for x in left] + fails
    status = "FAIL" if fails else "WARN" if warns else "PASS"
    res = {"status": status, "cleaned": fixes, "fails": fails, "warns": warns,
           "summary": dict(stats, fail_count=len(fails), warn_count=len(warns), cleaned_count=sum(f["count"] for f in fixes))}
    if not a.markdown:
        print(json.dumps(res, indent=1, ensure_ascii=False))
        return 0
    print(markdown(res))
    return 0


def writer_rules() -> str:
    """The same lists as the scan, worded for the writer, so the prompt and QC never disagree."""
    q = lambda xs: ", ".join('"%s"' % x for x in xs)
    return "\n".join([
        "AI-tell rules (QC runs these on the draft; the FAIL items stop the post):",
        "- FAIL, never write: a chatbot opener at the start of a line (Sure!, Certainly!, Absolutely!, Of course!, Great!), "
        "or any of " + q(FAIL_TERMS) + ".",
        "- Never paste citation markers or tracking tags from a chat tool: oaicite, contentReference, \u3010n\u2020source\u3011, "
        "turn0search, utm_source=chatgpt.com. Link the source URL itself.",
        "- Warning, avoid: " + q(WARN_TERMS) + ".",
        "- Warning, avoid these shapes: \"it's not X, it's Y\"; \"This isn't X. It's Y.\"; a one-word rhetorical question "
        "such as \"The result?\" or \"The catch?\".",
        "- Warning, never use a stock heading: " + q(sorted(STOCK_HEADINGS)) + ". Write a heading that says what the section proves.",
        "- Warning: no more than 1 \"A, B and C\" list per 100 words. Use 2 or 4 items when that's what the facts are.",
        "- Warning: no more than 10 \"**Label:** text\" bullets in a post. Keep them for lists of real named items.",
        "- Quoted dialogue and blockquotes are exempt.",
    ])


def markdown(res: dict) -> str:
    out = ["### AI-Tell Check (%s)" % Path(__file__).stem, ""]
    s = res["summary"]
    out.append("- Paste leftovers cleaned: **%d**%s" % (s["cleaned_count"], " (" + ", ".join("%s x%d" % (f["fix"], f["count"]) for f in res["cleaned"]) + ")" if res["cleaned"] else ""))
    out.append("- Chatbot text to rewrite (FAIL): **%d**" % s["fail_count"])
    out.append("- AI patterns (warning): **%d**. Lists of three: %d. Bold-label bullets: %d." % (s["warn_count"], s["triplets"], s["bold_label_bullets"]))
    rows = [("**FIX**", x) for x in res["fails"]] + [("WARN", x) for x in res["warns"]]
    if rows:
        out += ["", "| Level | Rule | Line | Text |", "|---|---|---|---|"]
        for lvl, x in rows:
            out.append("| %s | %s | %s | %s |" % (lvl, x["rule"].replace("|", "\\|"), x["line"] or "-", x["text"].replace("|", "\\|")))
    out += ["", "AI-tell status: %s" % res["status"], ""]
    return "\n".join(out)


if __name__ == "__main__":
    sys.exit(main())
