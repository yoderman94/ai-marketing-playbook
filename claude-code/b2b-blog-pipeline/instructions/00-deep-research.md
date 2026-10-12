# Stage 0 — Multi-Source Research (Exa + Tavily + DuckDuckGo + SearXNG + Gemini Deep Research)

You are running Stage 0 of the [YOUR_VERTICAL] blog pipeline for the slug provided in
the BATCH MODE block at the bottom of this prompt. Your job is to gather research from
five sources, merge them into one structured bundle, **fact-check every quote and
statistic against its source**, and exit.

**Do NOT write the blog post here. Do NOT generate the brief. This stage produces
verified source material only.**

---

## Requirements

This stage uses these tools. Install steps for each one are in `docs/TOOLS.md`.
Run `scripts/doctor.sh` to see which ones this machine has.

| Dependency | What it is | If it's missing |
|---|---|---|
| `mcp__exa__*` | Exa neural search, paid API | **Required.** Connect the Exa MCP. |
| `mcp__tavily__*` | Tavily search, paid API with a credit cap | **Required.** Connect the Tavily MCP. |
| `scripts/ddgs-query.sh` + the `ddgs` Python package | DuckDuckGo CLI, free, no key | Phase B3 logs and continues. Install: `python3 -m pip install -U ddgs` |
| `mcp__searxng__*` | Self-hosted metasearch (default `localhost:8888`, see `services/searxng/`) | Phase B2 logs and continues |
| `scripts/searxng-query.sh` | CLI wrapper for SearXNG | Optional. The MCP alone is enough. |
| `scripts/gemini-deep-research.py` | Playwright script that drives Gemini Deep Research | Phase C is skipped |
| `scripts/gemini-auth-check.sh` | Preflight that confirms the browser is signed in to Gemini | Phase C is skipped |
| `mcp__firecrawl__*` | Firecrawl page fetch: self-hosted (free) or the hosted API (paid) | Phase E falls through to Exa |

**Only Exa and Tavily are load-bearing.** The stage produces a passing bundle on those
two alone. Every other source logs its failure and continues.

---

## Inputs

The batch caller passes:

- `SLUG` — the topic slug, for example `local-services-ads-[YOUR_VERTICAL_SLUG]`.
- `RESEARCH_TOPIC` — the one-paragraph topic specification, including audience
  constraints such as company size and any exclusions.
- `INPUT_PDFS` — absolute paths to the source PDFs in `inputs/` this topic draws from.
  Treat these as primary source material the research must complement, not duplicate.

If `RESEARCH_TOPIC` names no audience or no intended use, derive both from
the audience rules in `CLAUDE.md` ([YOUR_VERTICAL] company decision-makers, not consumers).
State them in the first paragraph of the bundle's `## Topic Overview`.

---

## Read the source policy first

Before any searching, read `reference/source-policy.md` in full. It defines:

- The Tier 1, Tier 2, and Excluded source tiers for this vertical.
- The recency-against-authority rule. Platform claims need recency. Market and industry
  claims need authority.
- The competitor exclude list. Also re-read `reference/competitors.md` at run time.
  That file is the source of truth for exclusions.

Every search you run must apply this policy. Exclusion is strict. Inclusion is biased,
not locked.

---

## Output

Write one file: `research/[SLUG]-research.md`

Required sections, in this order, in markdown:

```
# Research Bundle — [Topic]

## Topic Overview
(2 to 4 paragraphs framing the topic, audience, and what was investigated. Note which
of the five sources contributed and any that failed.)

## Direct Quotes
(For each: blockquote the exact text, then `(Source: Author/Speaker; Year — [Source Name](url))`.
Tag each with the tool that found it and its tier, e.g. `[Tavily · Tier 1 · verified]`.)

## Statistics and Data
(For each: clearly stated stat with date, sample size, methodology when available, and
`(Source: Org, Title; Year — [Source Name](url))`. Tag each `[tool · tier · verified|unverified]`.)

## Academic Research
(For each: key finding, full citation, journal link, methodology where available. A
minor tier for most marketing topics — include only where genuinely relevant.)

## Additional Resources
(Markdown list of further-reading links with one-line descriptions.)

## Verification Notes
(The fact-check output. List what was verified, what was dropped and why, conflicting
findings, and anything flagged low-confidence. Every item in Direct Quotes and
Statistics must be accounted for here.)

## Sources Visited
(Plain list of every URL opened across all five tools, one per line. Used downstream
for citation verification.)
```

Downstream stages gate on this file existing, being at least 4 KB, and containing both
`## Direct Quotes` and `## Statistics`. A smaller or missing file marks the blog
aborted. Write a real, verified bundle, not a stub.

---

## Known limits and tool reliability (read before a batch)

These are observed constraints from running full multi-post batches. Plan around them.

**Gemini Deep Research has no daily quota.** There is no roughly-six-per-day cap. That
was an old holdover, removed 2026-07-03. Do not front-load or defer posts around a
Gemini run limit. Gemini can still fail transiently or throw a one-off "Sorry, I can't
help" error. Retry once in a fresh run. If it genuinely will not run for a post, log
`STAGE0_GEMINI_BLOCKED` and ship the bundle on Exa and Tavily. Drafts do not need
rewriting. Gemini is enrichment.

**Re-verify every Gemini number.** Across multi-post batches, roughly **30% of Gemini's
unique numeric and named claims fail verification.** That includes confident
fabrications dressed in real-looking citations: invented statistics, nonexistent
citations, fabricated case studies, inverted or misattributed findings, and stats
laundered through aggregator blogs. Exa and Tavily did not do this.

So use Gemini for narrative framing, story angles, and lead generation only. It does
surface genuine sources the API tools miss. Phase E must fetch and confirm every
Gemini-sourced figure at its primary source before it enters the bundle. For citable
statistics, prefer Tavily first, because its result text contains the figure, then Exa,
which is best at discovery and primary-source PDFs.

**Claude usage window, when you orchestrate this pipeline with subagents.** Running the
writing pipeline as parallel subagents will exhaust the 5-hour Claude usage window if
you fan out too wide. A pacing that works: **at most 2 concurrent Opus writer
subagents**, with the lighter research and merge subagents on Sonnet. Browser-driven
Gemini runs are server-side and do not consume the Claude budget, so a single shared
browser is the natural rate-limiter.

---

## Operating procedure

Run the five sources in order, then merge, then fact-check. If any single source fails,
log it and continue. The bundle must still be produced from whatever sources succeeded.

### Phase A — Exa (discovery)

Exa's neural search is best at finding primary sources when you describe the ideal
page. This build takes only `query` and `numResults`. There are no domain or date
filters, so steer entirely through query wording.

1. Derive 4 to 8 research questions from `RESEARCH_TOPIC` and the input PDFs.
2. For each, call `mcp__exa__web_search_exa` with a query that **describes the ideal
   Tier 1 page**, not keywords. For example:
   - "official Google Business Profile help documentation explaining how reviews affect local ranking"
   - "BrightLocal local consumer review survey reporting how many people read reviews before choosing a local service"
   - "Bureau of Labor Statistics data on [YOUR_VERTICAL] employment and wages"
3. When a result looks like a real primary source, call `mcp__exa__web_fetch_exa` on its
   URL to pull the full page. Never trust a snippet alone for a statistic or a quote.
4. Discard anything on the competitor exclude list or that reads as a content farm.

### Phase B — Tavily (precision and exclusion)

Tavily enforces the source policy at the parameter level. Use it for the claims where
domain control and recency gating matter most.

1. Build `exclude_domains` from `reference/competitors.md`. Re-read that file now. Pass
   the list on **every** `mcp__tavily__tavily_search` call.
2. For platform, algorithm, and product claims, set `start_date` to about 18 months
   before today, or `time_range: "year"`, and prefer official docs. Use
   `include_domains` to force a Tier 1 pull when you want a specific source, for example
   `["support.google.com"]` or `["bls.gov"]`.
3. For market, industry, and demographic claims, do not date-gate. Let authority win.
4. Use `search_depth: "advanced"` for the harder factual queries.
5. **Credit cap. Read before calling.** `mcp__tavily__tavily_research` is the most
   expensive call in Stage 0. `model: pro` costs 15 to 250 Tavily credits per request.
   `model: mini` costs 4 to 110. One `pro` call can burn a quarter of a 1,000-credit
   month. Inside a batch run you get **at most one call per topic, always
   `model: mini`**. Never `pro`. Never `auto`, which can resolve to `pro`. Reserve `pro`
   for standalone research where a human asked for depth. Mind the 20-requests-per-minute
   limit.
6. Use `mcp__tavily__tavily_extract` to pull the full page for any statistic or quote
   you intend to cite.

### Phase B2 — SearXNG (free breadth discovery, no quota)

SearXNG is a local, self-hosted metasearch that fans one query across Google, Bing,
Brave, DuckDuckGo, Startpage and more. Free, no API key, no quota. Use it as a
discovery layer to surface candidate Tier 1 pages without spending Exa or Tavily quota,
and to widen coverage on the harder questions.

It is **discovery only**. Every URL it surfaces is subject to the same source policy and
the Phase E fact-check gate before anything is cited.

1. Call it via the `searxng` MCP tool (`mcp__searxng__*`) or the CLI
   `scripts/searxng-query.sh "your query"` (`--num N`, `--json`).
2. Run plain-keyword and natural-language queries on each research question.
3. Discard anything on the competitor exclude list or that reads as a content farm.
4. Before citing anything SearXNG surfaces, pull the full page with
   `mcp__exa__web_fetch_exa` or `mcp__tavily__tavily_extract`. Phase E enforces this.
5. If SearXNG is unavailable, note it and continue. It never fails the stage.

### Phase B3 — DuckDuckGo via the ddgs CLI (news and recent coverage, no quota). REQUIRED

DuckDuckGo is free, with no API key and no daily quota. Use it to surface recent news,
press releases and trade coverage, above all for changes in the past 30 to 90 days that
Exa and Tavily may not have indexed yet. **Run it on every job. Don't skip it as "not
needed."**

Use the CLI wrapper through Bash: `scripts/ddgs-query.sh` (`--news`, `--time d|w|m|y`,
`--num N`, `--json`, `--extract URL`). It tries several backends and logs to `logs/ddgs.log`.

1. Run at least one `--news` search per research question where recency matters:
   platform updates, industry announcements, recent case studies, seasonal news. Use
   `--time m` for fast-moving topics. Omit `--time` for broader coverage.
2. Run at least one text search (no flag) on each question where Exa and SearXNG did not
   return strong Tier 1 coverage.
3. For promising results, pull the full page with `scripts/ddgs-query.sh --extract "URL"`
   (free). Use `mcp__exa__web_fetch_exa` or `mcp__tavily__tavily_extract` when it returns
   thin content.
4. Discard anything on the competitor exclude list or that reads as a content farm.
5. Before citing anything ddgs surfaces, confirm the content at its source page. Phase E
   enforces this.
6. Report the real counts in the sources line (`ddgs: N news, N text, N extracts, N usable`).
   If the wrapper exits 1 (or the ddgs package is missing), retry once, then note it and
   continue. It never fails the stage.

### Phase C — Gemini Deep Research (deep narrative pass, via local script)

Gemini Deep Research runs through a standalone Playwright script, not live MCP browser
clicks: `scripts/gemini-deep-research.py`. It attaches over CDP to
the already-running superpowers-chrome Chrome and drives Deep Research end to end in
one blocking call, so Stage 0 spends zero extra tokens on the 5 to 35 minute wait.

The `gemini-auth-check.sh` preflight, run before Stage 0, guarantees Chrome is up and
signed in. **Never launch Chrome yourself.**

Do **not** drive Gemini directly via
`mcp__plugin_superpowers-chrome_chrome__use_browser`, and do **not** use a dedicated
Gemini MCP. Both are superseded by the script for this stage, and the MCP hits
free-tier rate limits.

1. Take the prompt below, under "The Gemini prompt to paste", substitute `[TOPIC]` with
   `RESEARCH_TOPIC`, and write it to `research/.gemini-prompt-[SLUG].txt` (inside the
   project, so the headless permission rules allow the write).
2. Run:
   ```
   python3 scripts/gemini-deep-research.py \
     --topic-file research/.gemini-prompt-[SLUG].txt \
     --out research/[SLUG]-gemini-raw.md \
     --timeout-minutes 35
   ```
3. Check the exit code:
   - `0` — success. Read `research/[SLUG]-gemini-raw.md` into Phase D. The file holds
     the report body, then `## Sources Used` and `## Sources Reviewed But Not Cited`.
   - `1` (login wall or bot challenge) or `2` (Deep Research toggle not found) — this is
     the `STAGE0_GEMINI_BLOCKED` or `STAGE0_NO_DEEP_RESEARCH_MODE` condition. Log it and
     **skip Gemini.** Do not abort the stage. Continue to Phase D with the other
     sources.
   - `3` (plan-confirmation timeout), `4` (poll timeout past 35 minutes), or `5`
     (extraction failed, or the report is too short) — retry once. A fresh run can clear
     a transient glitch. If it fails again, log it and skip Gemini.

   The script already saves a screenshot and an HTML dump of whatever went wrong to
   `logs/gemini-failures/`. Do not capture one yourself. Those files show a signed-in
   Google page, so never copy them out of `logs/` (which git ignores).

### Phase D — Merge and dedupe

1. Combine the findings from all five sources into the required section structure.
2. Dedupe. When two tools surface the same statistic, keep one entry and note both as
   corroborating in Verification Notes. When two sources conflict, keep both and flag
   the conflict.
3. Preserve every direct quote and statistic verbatim. Do not paraphrase.
4. Tag each quote and statistic with `[tool · tier]` so the fact-check and the
   downstream stages know its provenance.
5. Drop anything on the competitor exclude list that slipped through.

### Phase E — Fact-check gate (Claude verifies everything)

This is the quality gate. Nothing leaves Stage 0 unverified.

1. **Verify every entry** in `## Direct Quotes` and `## Statistics and Data`. Open each
   cited URL and confirm the quote or statistic appears on that page verbatim.

   Verifying everything is affordable because of the source order below, not because
   cost does not matter. Use the cheapest source that can do the job, in this order:

   1. `mcp__firecrawl__firecrawl_scrape` — free when self-hosted, cheap on the hosted
      API. If it is down or not connected, note it and fall through. Never block the
      gate on it.
   2. `mcp__exa__web_fetch_exa` — about $1 per 1,000 pages.
   3. `mcp__tavily__tavily_extract` — billed per 5 URLs, so last.

   Runaway guard: if a bundle somehow carries more than 40 quotes and statistics, verify
   the top 40 by weight, tag the remainder `unverified`, and say so in
   `## Verification Notes`. A bundle that large is a signal the research went too wide,
   not a license to skip checks.

2. Confirm each statistic carries a date, and a sample size or methodology where the
   source provides one.
3. Mark each verified item `verified`. If a quote or statistic cannot be confirmed on
   its page:
   - Try to find the original source for the same claim. Trace the citation chain.
   - If found, swap in the verified source.
   - If not, either drop the item, or move it down and tag it `unverified`. Never let an
     unverified statistic sit in the bundle unflagged.
4. Confirm no cited domain is on the exclude list.
5. Write the result of every check into `## Verification Notes`: counts verified against
   dropped, swaps made, conflicts, and low-confidence flags.

A bundle that reaches the writer must be one where every retained statistic and quote
has been confirmed against its source, or is explicitly flagged. Stage 2 blocks on the
`unverified` tag. That coupling is the whole point of this gate.

---

## The Gemini prompt to paste (verbatim, with [TOPIC] substituted)

```
<role>

You are an expert content research specialist for a digital marketing agency that
serves small to medium [YOUR_VERTICAL] companies. You excel at surfacing current,
primary-source statistics, expert quotes, and case studies, and at verifying every
source by tracing it to its origin.

You only deliver direct expert quotes (no paraphrasing) and actionable, sourced
findings.

</role>

<task>

* Conduct thorough research on the topic I provide.
* Gather direct quotes and statistics from authoritative primary sources.
* Verify all information and ensure links are accessible and contain the referenced
  content.
* Be honest and flag anything you cannot verify.

</task>

<audience>

The finished blog post is read by owners and decision-makers at small to medium
[YOUR_VERTICAL] companies, the readers named in the topic below, who are deciding
whether to hire a marketing agency. They are not consumers. They know their trade, and
they fact-check any number about it.

Your report is read first by a brief writer, who builds the post outline from it,
and then by the post writer, who quotes and cites it. Neither one redoes your research,
so give them findings they can use as written.

</audience>

<intent>

Your findings become the fact base for a blog post published on our agency's site,
under our byline. Every statistic and quote may be cited and linked in public, so each
one must trace to a primary source a reader can open. The same facts are reused in the
post's TL;DR, its FAQ, and its title and meta description. An error repeats in all of
them.

Not wanted: general background nobody will cite, consumer how-to advice, undated
figures, and statistics you cannot trace to their origin.

</intent>

<source_priority>

Prioritize sources in this order for [YOUR_VERTICAL] MARKETING topics:

1. Official platform documentation (Google Business Profile, Local Services Ads,
   Google Ads, Google Search Central, Think with Google).
2. Government and public data (Bureau of Labor Statistics, U.S. Census, FTC, SBA, and
   your vertical's regulator).
3. [YOUR_VERTICAL] trade bodies and publications ([YOUR_VERTICAL_ASSOCIATION], the main
   trade magazines, state associations).
4. Marketing research firms that disclose methodology (BrightLocal, Moz, Whitespark,
   Pew Research).

Academic and peer-reviewed journals are a minor source for this topic set. There is no
peer-reviewed literature on tactics like Google Business Profile optimization. Use
academic sources only where they genuinely apply (consumer decision behavior, trust and
reputation psychology). Do NOT pad the report with journal searches for
marketing-tactic claims.

For platform and algorithm claims (anything about how Google products or ad systems
behave), prefer sources from the last 18 months. These products change constantly. For
market-size, labor, and demographic data, the most authoritative dataset wins even if
it is a year or two old.

DO NOT cite or link any competitor agency. The excluded domains are:

[PASTE THE DOMAIN LIST FROM reference/competitors.md HERE AT RUN TIME]

Also avoid content farms, circular "stats roundup" aggregators with no traceable
original source, undated pages making time-sensitive claims, and forum posts as a
primary statistic source.

</source_priority>

<citation_requirements>

For every piece of information:

1. Include a direct markdown link to the source: [Source Name](url)
2. Before citing, verify the link is accessible and the information actually appears on
   the page.
3. For direct quotes, use markdown blockquotes (>) and name the author/source.
4. For statistics, specify the date of the data, sample size, and methodology when
   available.
5. Evaluate source credibility on Authority, Currency, Accuracy, and Purpose.
6. Flag any information you could not adequately verify.

Never cite a link without first checking that it is accessible, contains the referenced
information, and is a credible source.

</citation_requirements>

<output_format>

Use markdown. Organize your findings as:

## Topic Overview
Brief introduction to the topic and key aspects of your research.

## Direct Quotes
For each: blockquote, then (Source: Author/Speaker; Year — [Source Name](url))

## Statistics and Data
For each: the statistic, then (Source: Organization, Title; Year — [Source Name](url)),
then **Methodology:** sample size and data collection when available.

## Additional Resources
Markdown list of valuable further-reading sources with proper links.

## Verification Notes
Notes on source verification, limitations, or conflicting information.

</output_format>

Respond with "I'll research [TOPIC], prioritizing platform documentation, government
data, [YOUR_VERTICAL] industry sources, and methodology-backed marketing research, and
I'll verify every link." Then proceed.

The topic: [TOPIC]
```

---

## Style and project rules apply

This stage is read-only on the filesystem except for writing the research file, plus
screenshots and log lines to `logs/`. Do not modify `output/`, `instructions/`, or
anything outside `research/` and `logs/`.

Project rules from `CLAUDE.md` apply: the audience is [YOUR_VERTICAL] company
decision-makers, not consumers; AP style; em dashes capped at 1 per 300 words of body
copy; no prohibited phrases; [YOUR_CMS] over [ALTERNATIVE_CMS] if CMS comes up.

Stage 0 does not write prose. But if you reformat tool output, strike any banned terms
from headings or transitions you author.

---

## Termination

Exit 0 only if both hold:

- The research file passes its gates locally: the file exists, is at least 4 KB, and
  contains `## Direct Quotes` and `## Statistics`.
- The Phase E fact-check has run, with its results recorded in `## Verification Notes`.

Otherwise exit non-zero so the batch caller marks the blog aborted.

Gemini being skipped does **not** by itself cause a non-zero exit, as long as Exa and
Tavily produced a passing, fact-checked bundle.
