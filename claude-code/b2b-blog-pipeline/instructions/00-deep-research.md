# Stage 0 — Multi-Source Research (Exa + Tavily + DuckDuckGo + SearXNG)

You are running Stage 0 of the [YOUR_VERTICAL] blog pipeline for the slug provided in
the BATCH MODE block at the bottom of this prompt. Your job is to gather research from
four sources, merge them into one structured bundle, **fact-check every quote and
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
of the four sources contributed and any that failed.)

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
(Plain list of every URL opened across all four tools, one per line. Used downstream
for citation verification.)
```

Downstream stages gate on this file existing, being at least 4 KB, and containing both
`## Direct Quotes` and `## Statistics`. A smaller or missing file marks the blog
aborted. Write a real, verified bundle, not a stub.

---

## Known limits and tool reliability (read before a batch)

These are observed constraints from running full multi-post batches. Plan around them.

**Why Gemini was retired (2026-10-14).** Across multi-post batches, roughly 30% of
Gemini's unique numeric and named claims failed verification, and it needed a signed-in
browser, which a server can't provide. Stage 0 now runs on Exa, Tavily, SearXNG and
DuckDuckGo, with Firecrawl for fact-check fetches. For citable statistics, prefer Tavily
first, because its result text contains the figure, then Exa, which is best at discovery
and primary-source PDFs.

**Claude usage window, when you orchestrate this pipeline with subagents.** Running the
writing pipeline as parallel subagents will exhaust the 5-hour Claude usage window if
you fan out too wide. A pacing that works: **at most 2 concurrent Opus writer
subagents**, with the lighter research and merge subagents on Sonnet.

---

## Operating procedure

Run the four sources in order, then merge, then fact-check. If any single source fails,
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

### Phase C (retired)

Phase C (Gemini Deep Research) was retired on 2026-10-14. Do not run it.

### Phase D — Merge and dedupe

1. Combine the findings from all four sources into the required section structure.
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

## Style and project rules apply

This stage is read-only on the filesystem except for writing the research file, plus
log lines to `logs/`. Do not modify `output/`, `instructions/`, or
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

A free source (SearXNG or DuckDuckGo) being skipped does **not** by itself cause a non-zero
exit, as long as Exa and Tavily produced a passing, fact-checked bundle.
