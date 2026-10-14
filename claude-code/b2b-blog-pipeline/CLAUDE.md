# [YOUR_AGENCY] — [YOUR_VERTICAL] Blog Pipeline

## About This Workspace
This is the content creation workspace for [YOUR_AGENCY], a digital marketing agency based in [YOUR_CITY], [YOUR_STATE]. This project handles the [YOUR_VERTICAL] blog content pipeline.

[YOUR_AGENCY] markets TO [YOUR_VERTICAL] companies as clients — we are not writing on behalf of [YOUR_VERTICAL] companies to their end customers. Our content targets [YOUR_VERTICAL] business owners, operations managers, office managers, and marketing decision-makers who are evaluating whether to hire a marketing agency.

**Note:** This workspace covers [YOUR_VERTICAL] company marketing only. Put each other vertical you serve in its own clone of this template.

## Versioning
This template uses semantic versioning (MAJOR.MINOR.PATCH), tracked in `VERSION` and documented in `CHANGELOG.md`:
- **MAJOR** — breaking changes to pipeline structure (stage reorder/removal, changed output contract or CMS template tags)
- **MINOR** — new methodology (added instruction sections, new QC checks, new required elements)
- **PATCH** — fixes and wording (bug fixes, path corrections, clarifications)

When you change any instruction or reference file: bump `VERSION`, add a dated entry to `CHANGELOG.md`, and tag the commit `vX.Y.Z`.

**When cloning this template for a new vertical:** reset `VERSION` to `1.0.0` and start a fresh `CHANGELOG.md` for that vertical. Each cloned pipeline is versioned independently of this template and of the other verticals.

## Finished posts: posts/<date>-<slug>/

Each finished post's files live in one flat folder, `posts/<date>-<slug>/`: the draft, `-sources.md`, `-images.md`, cover files, the brief and the research. `output/`, `briefs/`, `research/` and `cover-generator/output/` hold only work in progress and batch files.

- `scripts/blog-pipeline.sh` moves a post there as the last step of its job, with `scripts/collect-post.py`. It runs after the slug map line, so research filed under the topic slug follows the post. Undated posts stay in `output/`.
- Run it by hand with `python3 scripts/collect-post.py . --date-slug <date>-<slug> [--apply]` or `--all`. It's a dry run unless `--apply`, never overwrites, and lists anything it can't match.
- Later steps look in `posts/` first: `cover-generator/scripts/make_cover.py` (a re-made cover) and Stage 11.
- Git ignores `posts/`, `output/`, `research/`, `briefs/` (except the template), `reports/` and `logs/`, so client work never lands in the repo by accident.

## Folders to ignore
**Never read, audit, or process any folder or file whose name starts with an underscore** (e.g. `_old/`, `_ignore/`, `_archive/`, `_draft-stash/`). These are archived / out-of-scope by convention. Only look inside an underscore-prefixed folder if the user explicitly points you at one by name.

## How to Use This System

### Quick Start
Open Claude Code in this folder. Point it at a topic, or at `reference/batch-queue.md` to work the queue. Read `README.md` first if this is a fresh clone: it lists the placeholders you must fill in before the pipeline produces usable output.

### Pipeline Overview
This workspace contains a blog post creation pipeline: a research stage, 8 content stages, an automated QC pass, and two optional cover stages. Most have an instruction file in `instructions/`. Always read the relevant instruction file before executing any stage.

0. **Multi-Source Research** → `instructions/00-deep-research.md` (Exa, Tavily, DuckDuckGo, SearXNG, then a fact-check gate)
1. **Topic Development** → `instructions/01-topic-development.md`
2. **Blog Post Writing** → `instructions/02-blog-post-writing.md`
3. **FAQ and TL;DR Review** → `instructions/03-faq-tldr.md`
4. **Titles, Meta Description, and Keywords** → `instructions/04-titles-meta-keywords.md`
5. **URL/Slug Generation** → `instructions/05-url-generation.md`
6. **Internal Linking** → `instructions/06-internal-links.md`
7. **External Link Verification** → `instructions/07-external-links.md`
8. **Link Checking** → `instructions/08-check-links.md`
9. **QC Report** → `scripts/qc.sh <draft> --append` (automatic, no instruction file)
10. **Template Cover** → `cover-generator/` (automatic when set up, no Claude call; see `cover-generator/README.md`)
11. **AI Cover Image and Alt Text** → `instructions/11-ai-cover-image.md` (interactive only, never in the batch script)

Run Stage 0, then all 8 content stages in sequence on each post, then let the QC step and the template cover run automatically. Stages 0 through 9 save to the same file: `output/[date]-[topic-slug]-draft.md`.

**Run the whole batch with `scripts/blog-pipeline.sh`.** It reads every topic in `inputs/`, runs one headless `claude -p` call per stage, and logs to `logs/`. See `README.md` for setup and `docs/TOOLS.md` for every tool it uses.

**Stage 11 cannot be scripted.** Magnific is a claude.ai connector and its sign-in does not survive a headless `claude -p` subprocess. Run Stage 11 yourself, in an interactive session, after a batch finishes. The gate is `reference/image-settings.md`: a missing file or `AI cover: off` means skip the project and say so.

## Batch Mode
For processing multiple topics from a table, see `reference/batch-template.md` for the required table format and batch mode rules. Keep your planning queue in `reference/batch-queue.md` (copy `reference/batch-queue-master.md`). To run topics, put the table (CSV, TSV or Markdown with the same headers) or one file per topic in `inputs/` and run `scripts/blog-pipeline.sh`. In batch mode, all approval gates and questions are skipped — inputs come from the table.

## Cross-Vertical Adaptation
Some posts may be adapted from [YOUR_AGENCY]'s other verticals. When the user provides source content from another vertical, adapt it for [YOUR_VERTICAL] by swapping industry-specific examples, personas, keywords, and data points. The user will specify whether to keep the same structure or write fresh from the same angle.

## Project Structure

```
README.md                           ← Setup guide. Read this on a fresh clone.
docs/TOOLS.md                       ← Every command-line tool and MCP server, with install steps
scripts/                            ← blog-pipeline.sh, router, QC, collect, doctor
cover-generator/                    ← Stage 10 template covers (fonts, templates, theme)
services/searxng/                   ← Optional local SearXNG (docker compose)
.env.example                        ← Settings for the batch script (copy to .env)
CLAUDE.md                           ← This file
VERSION / CHANGELOG.md              ← Template version history
instructions/
  00-deep-research.md               ← Five-source research, fact-check gate
  01-topic-development.md
  02-blog-post-writing.md
  03-faq-tldr.md
  04-titles-meta-keywords.md
  05-url-generation.md
  06-internal-links.md
  07-external-links.md
  08-check-links.md
  11-ai-cover-image.md              ← AI cover image and alt text. Interactive only.
  router-config.json                ← Stage detection by draft marker
personas/
  WRITER-PERSONA-TEMPLATE.md        ← Template for building writer voice profiles
  writer-profiles.md                ← Your writer voices (create from template)
prompts/                            ← Paste-ready prompts for building personas
reference/
  source-policy.md                  ← Stage 0 source tiers and exclusions
  image-settings.md                 ← Stage 10 and 11 on/off, ratio, minimum resolution
  image-rules/                      ← Stage 11 photo prompt and alt-text rules
  batch-template.md                 ← Batch table format and rules
  batch-queue-master.md             ← Blank queue to copy
  batch-queue.md                    ← Your active topic queue (create this)
  citation-formats.md               ← 5-format citation rotation system
  cta-rules.md                      ← Contact CTA and who-we-serve link rules
  mechanical-style-rules.md         ← Canonical wording for the style rules
  prohibited-phrases.md             ← Banned words and phrases for all content
  competitors.md                    ← Competitor domains to avoid linking
  reader-personas.md                ← Size-tiered reader personas
  READER-PERSONA-TEMPLATE.md        ← Template for adding a persona
  fictional-companies.md            ← Fictional reference companies for examples
  seasonal-calendar.md              ← Seasonal content planning
  known-misses.md                   ← Two-strike log. Carry it over empty.
briefs/                             ← Topic briefs
inputs/                             ← Drop source material here
research/                           ← Stage 0 bundles (gitignored)
output/                             ← Drafts in progress (gitignored)
  _done/                            ← Move finished drafts here
posts/                              ← One folder per finished post (gitignored)
logs/                               ← Run logs, audit CSVs, slug map (gitignored)
```

## Global Writing Rules (Apply to ALL Content)
- AP Style with Oxford comma
- Short paragraphs (2-4 sentences)
- Active voice preferred
- Em dashes: maximum 1 per 300 words of body copy, enforced by the scripts/qc.sh readability check (main body only, reported as a warning). Replace excess with semicolons, periods, or parentheses. Never a second em dash in the same paragraph or in back-to-back paragraphs. See `reference/mechanical-style-rules.md` for the canonical wording.
- No emojis in blog content
- Include specific data points and statistics where relevant — every statistic must be cited
- All claims must be verifiable — [YOUR_VERTICAL] business owners will fact-check you and write you off if something doesn't ring true
- All blog posts end with a CTA linking to: https://[YOUR-AGENCY-DOMAIN]/contact
- All content should position [YOUR_AGENCY] as the knowledgeable, approachable expert who understands the [YOUR_VERTICAL] industry

### CMS Positioning
- [YOUR_AGENCY] is a [YOUR_CMS] shop — always position [YOUR_CMS] as the preferred CMS
- Never recommend [ALTERNATIVE_CMS] as a first choice
- If [ALTERNATIVE_CMS] comes up: acknowledge its market share, then pivot to its real drawbacks — security vulnerabilities, plugin dependency bloat, update breakage, and the true cost of ongoing maintenance
- Never write content that makes [ALTERNATIVE_CMS] sound like the safer or easier choice

### Words and Phrases to NEVER Use
- "landscape", "crucial", "critical", "it's important to note", "it's worth noting"
- "in today's digital age", "in today's fast-paced world", "in the ever-evolving landscape"
- "game-changer", "dive into", "deep dive", "navigate", "leverage", "robust"
- "streamline", "cutting-edge", "holistic", "synergy", "paradigm shift", "utilize"
- "showcasing", "testament", "vibrant"
- "unlock", "discover", "boost", "grow", "optimize", "delve", "revolutionize"

See `reference/prohibited-phrases.md` for the complete list.