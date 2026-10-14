# Source Policy — [YOUR_VERTICAL] Marketing Research

This file governs what kinds of sources Stage 0 research may pull from, and how the
four research tools (Exa, Tavily, DuckDuckGo, SearXNG) should be
steered. It is read by `instructions/00-deep-research.md` before any searching. The
principle is simple:

**Exclusion is strict. Inclusion is biased, not locked.**

Hard-block competitors and junk. Bias hard toward authoritative primary sources, but do
not forbid a good source just because it is not on the preferred list.

---

## Setup: what you must fill in

Three things in this file are vertical-specific. Replace them before your first run.

1. The trade-body and trade-publication block in **Tier 1**.
2. The regulator or agency block in **Tier 1**, if your vertical has one.
3. Nothing in **Excluded** — that list is generated at run time from
   `reference/competitors.md`. Fill in that file instead.

Everything else transfers as written.

---

## Why this matters for this audience

Your readers are [YOUR_VERTICAL] business owners and marketing decision-makers. They
fact-check, and they write you off over one bad statistic. In the marketing-advice
niche, plain web search rewards exactly the wrong pages: SEO content farms, AI-spun
listicles that recycle fabricated numbers, and your own competitors.

For this audience, source survivability beats source breadth. Accept slightly thinner
research in exchange for every stat holding up under scrutiny.

---

## The two-axis rule: recency against authority

Source quality is not one scale. Weight the two axes by claim type.

**Platform, algorithm, and product claims** — Google Business Profile, Local Services
Ads, Google Ads mechanics, local ranking, social platform features, ad products. These
change constantly.

- **Recency dominates.** A current mid-tier source beats a three-year-old authoritative
  one, because the product changed.
- Gate these queries to the **last 18 months** with Tavily `start_date` or `time_range`.
- Prefer official platform documentation as the primary source.

**Market, industry, and demographic claims** — market size, industry revenue, labor
data, seasonality, consumer behavior, churn benchmarks.

- **Authority dominates.** Age is acceptable if it is the authoritative dataset.
- Do not date-gate these. The best source may be a government release a couple of years
  old.

---

## Tier 1 — Actively seek

Steer Exa queries to describe these pages. Use Tavily `include_domains` to force-pull
from them. Use them as steering cues for DuckDuckGo and
SearXNG search terms too.

**Platform and official documentation**
- Google Business Profile Help, Local Services Ads Help, Google Ads Help
- Google Search Central and the Search Central Blog
- Think with Google (thinkwithgoogle.com)

**Government and public data**
- Bureau of Labor Statistics (bls.gov)
- U.S. Census Bureau (census.gov)
- Federal Trade Commission (ftc.gov)
- Small Business Administration (sba.gov)
- **[Add your vertical's regulator here, if it has one.]**

**Trade bodies and trade publications for [YOUR_VERTICAL]**
- [YOUR_VERTICAL_ASSOCIATION]
- **[Add your vertical's two or three main trade publications here.]**
- State and regional [YOUR_VERTICAL] associations

**Marketing research with disclosed methodology**
- BrightLocal (local consumer review and search surveys)
- Moz (moz.com, Local Search Ranking Factors)
- Whitespark (local SEO studies)
- Pew Research Center (pewresearch.org)
- Search Engine Land and Search Engine Journal, for articles citing primary data. Never
  as the primary source themselves.
- Statista, only when the underlying source is named and traceable

---

## Tier 2 — Acceptable with caution

Usable, but verify the underlying data and prefer a Tier 1 source if one exists for the
same claim.

- Mainstream business and trade press, with a named author and a date
- Vendor or software research that discloses its methodology and sample
- Reputable non-competitor SEO and marketing blogs

If a Tier 2 page only restates a statistic, trace it to the original and cite that
instead.

---

## Excluded — Hard block, never cite, never link

**Competitor agencies.** Every domain in `reference/competitors.md`. Re-read that file
at run time and build the Tavily `exclude_domains` list from it. Do not keep a second
copy of the list here. It will drift.

**Junk and unreliable sources.** Exclude by judgment. Never cite as a source for a
statistic:

- Content farms and auto-generated listicle sites
- Stat-aggregator pages that cite each other in a circle, such as "99 stats" roundups,
  with no traceable original
- Undated pages making time-sensitive platform claims
- Reddit, Quora, and forum posts as a **primary** statistic source. Fine as a lead to
  find the real source, never as the citation.
- Press releases dressed as research, with no methodology

---

## Note on academic sources

Keep peer-reviewed journals as a **minor tier**. There is no peer-reviewed literature on
tactics like Google Business Profile optimization, and a research pass that chases DOIs
for marketing-tactic claims wastes the run and pads the bundle.

Use academic sources only where they genuinely apply: consumer decision behavior, trust
and reputation psychology, and anything your vertical has real research behind. For
everything else, industry and platform primary sources outrank journals.

If your vertical does have a real academic literature (medical, legal, education),
promote this tier accordingly and say so here.

---

## How each tool applies this policy

- **Tavily** enforces the policy at the parameter level. Always pass the competitor
  `exclude_domains`. Use `include_domains` to force Tier 1 pulls. Use `start_date` or
  `time_range` to gate platform claims to the last 18 months. Use `tavily_extract` to
  confirm a statistic appears on the page.
- **Exa** takes only a query in this build, so steer it by **describing the ideal Tier 1
  page** in natural language. Use `web_fetch_exa` to confirm a statistic appears on the
  page.
- **SearXNG** is discovery only, with no domain-filter parameter. Apply the competitor
  exclude list by discarding results by hand. Every URL it surfaces must pass Phase E
  before it is cited.
- **DuckDuckGo** is news and general web search, with no domain-filter parameter. Apply
  the exclude list by discarding competitor results before you pull the page. Every URL
  must pass Phase E.
