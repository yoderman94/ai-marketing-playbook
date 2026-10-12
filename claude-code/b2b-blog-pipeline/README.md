# B2B Service Blog Pipeline

> **Beta.** This pipeline is still in beta. Expect rough edges, and please [open an issue](https://github.com/yoderman94/ai-marketing-playbook/issues) when something breaks.

A [Claude Code](https://code.claude.com) workflow that researches, writes, fact-checks and packages SEO blog posts aimed at B2B service business owners. It's built for marketing agencies that serve one vertical (HVAC, plumbing, roofing, landscaping, commercial cleaning, IT services and so on) and write in their own voice, under their own byline.

Give it a topic. It returns a publication-ready draft with a verified research bundle, titles, meta description, slug, internal and external links, a QC report, and a branded cover image.

- **Stage 0** researches the topic across up to five sources and fact-checks every quote and statistic against its source page.
- **Stages 1-8** turn the research into a brief, a draft, an FAQ and TL;DR, titles and meta, a slug, internal links, and two rounds of link verification.
- **Stage 9** runs an automated QC report (banned phrases, readability, structure).
- **Stage 10** sets the title on a branded cover template (optional, no cost).
- **Stage 11** generates AI cover photos (optional, interactive, paid credits).

Everything runs on your machine through Claude Code. One script runs a whole batch unattended.

**Platforms:** macOS and Linux. On Windows, use WSL 2.

---

## Contents

1. [How it works](#how-it-works)
2. [What you need](#what-you-need)
3. [Quick start](#quick-start)
4. [Step-by-step setup](#step-by-step-setup)
5. [Running the pipeline](#running-the-pipeline)
6. [Settings](#settings)
7. [Folder structure](#folder-structure)
8. [Troubleshooting](#troubleshooting)
9. [Safety and privacy](#safety-and-privacy)

---

## How it works

| Stage | File | What it does | Model (default) |
|---|---|---|---|
| 0 | `instructions/00-deep-research.md` | Research from Exa, Tavily, DuckDuckGo, SearXNG and Gemini, merged into one bundle, then a fact-check gate | sonnet |
| 1 | `instructions/01-topic-development.md` | Turns the topic and research into a structured brief | sonnet |
| 2 | `instructions/02-blog-post-writing.md` | Writes the full draft from the brief | opus |
| 3 | `instructions/03-faq-tldr.md` | Reviews the FAQ and TL;DR | opus |
| 4 | `instructions/04-titles-meta-keywords.md` | SEO title, article title, image title, meta description, keywords | opus |
| 5 | `instructions/05-url-generation.md` | URL slug | sonnet |
| 6 | `instructions/06-internal-links.md` | Internal links to your site | sonnet |
| 7 | `instructions/07-external-links.md` | Adds and verifies external citations | sonnet |
| 8 | `instructions/08-check-links.md` | Independent final link check | opus |
| 9 | `scripts/qc.sh` | QC report appended to the draft | no model |
| 10 | `cover-generator/` | Template cover: SVG, PNG and WebP | no model |
| 11 | `instructions/11-ai-cover-image.md` | AI cover photos and alt text, run by hand | your session |

Stages 0-9 all work on one file: `output/<publish-date>-<slug>-draft.md`. When a job finishes, `scripts/collect-post.py` moves the draft, its research, brief and covers into `posts/<publish-date>-<slug>/`.

`scripts/blog-pipeline.sh` runs it all. It reads every file in `inputs/` and works out where each one enters the pipeline: a topic starts at Stage 0, a brief at Stage 2, a half-done draft at its next stage. Then it runs one headless `claude -p` call per stage, with a pause between stages. Every call's model, cost and duration go into an audit log.

---

## What you need

The full list, with costs and install steps for macOS and Linux, is in **[docs/TOOLS.md](docs/TOOLS.md)**. Check your machine at any time:

```bash
scripts/doctor.sh
```

### Required

| Tool | Why | Install (macOS) | Install (Debian/Ubuntu) |
|---|---|---|---|
| [Claude Code](docs/TOOLS.md#claude-code) | runs every stage | `curl -fsSL https://claude.ai/install.sh \| bash` | same |
| Claude account | Claude Code needs Pro, Max, Team, Enterprise or Console | https://claude.ai | |
| [Python 3.9+](docs/TOOLS.md#python) | router, QC, collect | `brew install python` | `sudo apt install python3 python3-pip` |
| [textstat](docs/TOOLS.md#python-packages) | QC readability | `python3 -m pip install -r requirements.txt` | same |
| [jq](docs/TOOLS.md#jq) | reads stage results | `brew install jq` | `sudo apt install jq` |
| [curl](docs/TOOLS.md#curl), [git](docs/TOOLS.md#git) | checks, cloning | preinstalled | `sudo apt install curl git` |
| [Exa MCP](docs/TOOLS.md#exa) | Stage 0 discovery (paid API, free credits to start) | `claude mcp add ...` | same |
| [Tavily MCP](docs/TOOLS.md#tavily) | Stage 0 search (1,000 free credits a month) | `claude mcp add ...` | same |

### Optional

| Tool | Adds | Without it |
|---|---|---|
| [coreutils `timeout`](docs/TOOLS.md#timeout) | a time limit per stage | a hung stage can stall the batch |
| [DuckDuckGo (ddgs)](docs/TOOLS.md#duckduckgo-ddgs) | free news and web search in Stage 0 (`scripts/ddgs-query.sh`) | logged and skipped |
| [SearXNG](docs/TOOLS.md#searxng) + [Docker](docs/TOOLS.md#docker) | free metasearch in Stage 0 | logged and skipped |
| [Firecrawl MCP](docs/TOOLS.md#firecrawl) | cheaper page fetches for the fact-check | Exa does the fetches |
| [superpowers-chrome](docs/TOOLS.md#superpowers-chrome) + [Playwright](docs/TOOLS.md#python-packages) | Gemini Deep Research in Stage 0 | logged and skipped |
| [fontTools](docs/TOOLS.md#python-packages), [resvg](docs/TOOLS.md#resvg), [cwebp](docs/TOOLS.md#cwebp) | Stage 10 template covers | no template cover |
| [Magnific](docs/TOOLS.md#magnific) | Stage 11 AI cover photos | no AI cover |
| [shellcheck](docs/TOOLS.md#shellcheck) | lint the scripts after edits | |

### What it costs to run

- **Claude usage.** Each post makes about ten `claude -p` calls, four of them on Opus. On a subscription, a batch counts against your usage window, and the script stops the queue cleanly if the window closes. On an API (Console) account, each call's cost is in `logs/*-model-audit.log`.
- **Research APIs.** Exa and Tavily bill per call. Stage 0 appends every call count to `logs/blog-batch-stage0.log`, so you can size your plans from real numbers.
- **Time.** About 1 to 3 hours per post, mostly Stage 0 and the pauses between stages.

---

## Quick start

For someone who already has Claude Code, Python and Homebrew (or apt):

```bash
# 1. Get the template (it lives in a folder of the AI Marketing Playbook repo)
git clone --depth 1 https://github.com/yoderman94/ai-marketing-playbook.git
cp -R ai-marketing-playbook/claude-code/b2b-blog-pipeline my-vertical-blog
rm -rf ai-marketing-playbook
cd my-vertical-blog && git init

# 2. Install the tools
brew install jq coreutils resvg webp          # Linux: sudo apt install jq webp  (resvg: see docs/TOOLS.md)
python3 -m pip install -r requirements.txt

# 3. Connect the two required research servers (keys from dashboard.exa.ai and app.tavily.com)
claude mcp add --transport http --scope user exa https://mcp.exa.ai/mcp --header "x-api-key: YOUR_EXA_API_KEY"
claude mcp add --scope user --transport http tavily "https://mcp.tavily.com/mcp/?tavilyApiKey=YOUR_TAVILY_API_KEY"

# 4. Check
scripts/doctor.sh

# 5. Fill in the placeholders and personas (Steps 4-7 below), then add a topic and run
echo "How [your vertical] companies can win more commercial contracts. Publish Date: 2026-11-04" > inputs/commercial-contracts.md
scripts/blog-pipeline.sh . no-gemini
```

---

## Step-by-step setup

Do these once per vertical. Steps marked **Required** produce bad output if you skip them.

### Step 1. Install the tools (Required)

Follow [docs/TOOLS.md](docs/TOOLS.md) from the top, or just the Required table above. Then run:

```bash
scripts/doctor.sh
```

Every line in the **Required** section must say `[ok]`. Optional lines can stay missing.

### Step 2. Connect the research servers (Required for Stage 0)

Stage 0 talks to search services through Claude Code's MCP servers. Add them once, at user scope, and every project can use them:

```bash
claude mcp add --transport http --scope user exa https://mcp.exa.ai/mcp --header "x-api-key: YOUR_EXA_API_KEY"
claude mcp add --scope user --transport http tavily "https://mcp.tavily.com/mcp/?tavilyApiKey=YOUR_TAVILY_API_KEY"
claude mcp list
```

Keep the names `exa` and `tavily`: the stage files and the batch script's tool allowlist use them. The optional servers (DuckDuckGo, SearXNG, Firecrawl, superpowers-chrome) are in [docs/TOOLS.md](docs/TOOLS.md).

Your API keys live in Claude Code's own configuration (`~/.claude.json`), never in this repo.

### Step 3. Make your copy

Clone the template once per vertical. Then, in the clone:

1. Reset `VERSION` to `1.0.0` and start a fresh `CHANGELOG.md` for that vertical.
2. Copy the settings file: `cp .env.example .env`. Every line in it is optional.
3. Point the clone at your own remote if you'll keep it in git. Keep that repository **private**: drafts, briefs and personas are client-facing work.

### Step 4. Replace the placeholder tokens (Required)

Find and replace each token across the whole project. `scripts/doctor.sh` tells you how many files still hold the main ones.

| Placeholder | Replace with |
|---|---|
| `[YOUR_VERTICAL]` | Your industry (`HVAC`, `roofing`, `commercial cleaning`) |
| `[YOUR_VERTICAL_SLUG]` | The same industry as it appears in your site's URLs (`hvac`, `commercial-cleaning`). Lowercase, hyphens, no spaces. |
| `[YOUR_AGENCY]` | Your agency name |
| `[YOUR-AGENCY-DOMAIN]` | Your agency domain (`example.com`) |
| `[YOUR_CITY]` / `[YOUR_STATE]` / `[YOUR_REGION]` | Your home market |
| `[YOUR_CMS]` | The CMS you recommend |
| `[ALTERNATIVE_CMS]` | The CMS you steer clients away from, if any |
| `[SERVICE_TYPE]` | Service types in your vertical (`HVAC tune-up`, `roof inspection`) |
| `[SERVICE_PROVIDER]` | What practitioners are called (`HVAC technician`, `roofer`) |
| `[PEAK_SEASON]` / `[OFF_SEASON]` / `[SHOULDER_SEASON]` | Your vertical's demand cycle |
| `[NATIONAL_COMPETITOR]` | National brands your clients compete with |
| `[NATIONAL_GENERALIST_AGENCY]` / `[VERTICAL_MARKETING_AGENCY]` | Agencies you compete with |
| `[VERTICAL_ASSOCIATION]` / `[YOUR_VERTICAL_ASSOCIATION]` | Your vertical's main trade association |
| `[YOUR_VERTICAL_PUBLICATION]` / `[SECOND_TRADE_PUBLICATION]` | Trade publications |
| `[YOUR_STATE_UNIVERSITY]` / `[RELEVANT_UNIVERSITY_DEPARTMENT]` | Research sources for citations |
| `[CLIENT_COMPANY]` / `[FIRST_NAME]` | Fictional example companies and contacts |
| `[PERSONA_NAME_1]`, `[PERSONA_NAME_2]`, `[PERSONA_NAME_3]` | Your writer persona names |

Two files need hand edits a find-and-replace can't do:

| File | What to fill in |
|---|---|
| `reference/source-policy.md` | Your vertical's trade bodies, publications and regulators in Tier 1 |
| `instructions/07-external-links.md` | The same sources, with their domains |

One way to replace a token everywhere (review the result with `git diff`):

```bash
# macOS
grep -rl '\[YOUR_VERTICAL\]' --include='*.md' --include='*.json' . | xargs sed -i '' 's/\[YOUR_VERTICAL\]/HVAC/g'
# Linux
grep -rl '\[YOUR_VERTICAL\]' --include='*.md' --include='*.json' . | xargs sed -i 's/\[YOUR_VERTICAL\]/HVAC/g'
```

### Step 5. Create your writer personas (Required)

Stage 2 writes in one of these voices.

- **Fastest:** start `claude` in this folder, paste the contents of `prompts/build-writer-personas.md`, and follow it. Paste in emails, proposals or any writing samples. Claude extracts the voice and writes `personas/writer-profiles.md`.
- **By hand:** copy `personas/WRITER-PERSONA-TEMPLATE.md` to `personas/writer-profiles.md` and fill it in.

Build two or three voices, each with real sample sentences, not just adjectives. The first profile in the file is the default.

### Step 6. Build your reader personas (Required)

`reference/reader-personas.md` has a six-tier framework by company size. Fill it in:

- **Fastest:** paste `prompts/build-reader-personas.md` into `claude` with client emails, call notes, CRM records or testimonials.
- **By hand:** replace each placeholder. Use `reference/READER-PERSONA-TEMPLATE.md` to add tiers.

The more specific and real the personas, the better the posts. Vague personas produce generic copy.

### Step 7. Customize the reference files (Required)

| File | What to do |
|---|---|
| `CLAUDE.md` | The rules every session reads. Fill in the placeholders, check the CMS positioning and writing rules. |
| `reference/competitors.md` | Competitor domains the pipeline must never link to or cite |
| `reference/fictional-companies.md` | Fictional companies for examples. Check that none matches a real business. |
| `reference/seasonal-calendar.md` | Your vertical's real demand cycle |
| `reference/cta-rules.md` | Your contact URL and anchor text |
| `reference/prohibited-phrases.md` | Banned words. QC fails a draft on the hard ones. Add your own. |
| `reference/mechanical-style-rules.md` | House style. `[HOUSE]` rules are choices you can change. |

### Step 8. Brand the cover generator (Optional, Stage 10)

1. Put your brand colors in `cover-generator/theme.json`.
2. Edit `cover-generator/templates/*.svg` in any vector editor and add your logo.
3. Test: `cd cover-generator && python3 scripts/make_cover.py --title "Your Title: The Subtitle" --slug test --date 2026-01-01`

Details: [cover-generator/README.md](cover-generator/README.md). To turn Stage 10 off, set `**Template cover:** off` in `reference/image-settings.md`.

### Step 9. Turn on AI cover photos (Optional, Stage 11)

Connect [Magnific](docs/TOOLS.md#magnific), then set `**AI cover:** on` in `reference/image-settings.md`. Stage 11 runs only in an interactive session.

### Step 10. Set up Gemini Deep Research (Optional, Stage 0)

Install the [superpowers-chrome](docs/TOOLS.md#superpowers-chrome) plugin, sign in to Google once in its browser, and install Playwright. Then `scripts/gemini-auth-check.sh` should print `LOGGED IN`. Until then, run the pipeline with `no-gemini`.

---

## Running the pipeline

### Add topics

Put files in `inputs/`. The router decides where each one enters:

| You drop in | Example | Enters at |
|---|---|---|
| A topic seed: a few lines of prose | `How [vertical] firms can win commercial contracts. Publish Date: 2026-11-04` | Stage 0 |
| A batch table (CSV, TSV or Markdown) | columns from `reference/batch-template.md`, one row per post | Stage 0, one job per row |
| A brief in the Stage 1 format | `briefs/BLOG-BRIEF-TEMPLATE.md`, filled in | Stage 2 |
| A partly finished draft | a draft that already has Stage 4 titles | the next stage |
| A research PDF or Stage 0 bundle | | attached to a job as source material |

Add `Publish Date: YYYY-MM-DD` to a seed or brief, or a Publish Date column to a table. The date goes on the front of every output filename, and only dated posts get a `posts/` folder.

### Run a batch

```bash
scripts/blog-pipeline.sh                     # every topic in inputs/, all research sources
scripts/blog-pipeline.sh . no-gemini         # skip the Gemini browser pass
scripts/blog-pipeline.sh . all skip-router   # rerun with the last manifest
```

The script:

1. Checks your tools (`scripts/doctor.sh --required-only`).
2. Classifies `inputs/` and prints the plan, then waits 60 seconds so you can press Ctrl-C if it misread something.
3. Runs each job through its stages. A stage that produces no draft stops that job. The next job still runs.
4. Runs the QC report and the template cover, then files the post in `posts/<date>-<slug>/`.
5. Prints a summary and the model and cost audit.

For long batches, run it inside `tmux` or `screen` so it survives a closed terminal. Logs are in `logs/`.

### Run one post by hand

Start `claude` in this folder and ask for the stage you want, for example:

```
Run Stage 0 for the topic in inputs/commercial-contracts.md, then Stage 1.
```

Each instruction file says what it reads and writes.

### Stage 11, AI covers

After a batch, in an interactive session:

```
claude
> Run Stage 11 (instructions/11-ai-cover-image.md) on posts/2026-11-04-my-slug/
```

### Re-run the QC on a draft

```bash
bash scripts/qc.sh posts/2026-11-04-my-slug/2026-11-04-my-slug-draft.md            # print the report
bash scripts/qc.sh posts/2026-11-04-my-slug/2026-11-04-my-slug-draft.md --append   # replace it in the draft
```

---

## Settings

All optional. Put them in `.env` (copy `.env.example`) or export them in your shell. The shell wins.

| Variable | Default | What it does |
|---|---|---|
| `BLOG_MODEL_STANDARD` | `sonnet` | Stages 1, 5, 6, 7 and the Gemini login check |
| `BLOG_MODEL_WRITING` | `opus` | Stages 2, 3, 4, 8 |
| `BLOG_MODEL_RESEARCH` | `sonnet` | Stage 0 |
| `BLOG_PERMISSION_MODE` | `allowlist` | `allowlist` or `bypass`. See [Safety](#safety-and-privacy). |
| `BLOG_ALLOWED_TOOLS` | built-in list | Space-separated tools the headless stages may use |
| `BLOG_CLAUDE_EXTRA_ARGS` | | Extra flags for every `claude` call |
| `BLOG_RESEARCH_MODE` | `all` | `all` or `no-gemini` |
| `BLOG_STAGE_TIMEOUT` | `3h` | Time limit per stage (needs `timeout` or `gtimeout`) |
| `BLOG_SLEEP_*` | 30-120 s | Pauses between stages and jobs |
| `BLOG_LOG_DIR` | `logs/` | Where logs go |
| `SEARXNG_URL` | `http://localhost:8888` | Your SearXNG |
| `FIRECRAWL_URL` | | Your self-hosted Firecrawl, for `doctor.sh` |
| `CHROME_CDP_PORT` | auto | Chrome debug port for the Gemini script |

`reference/image-settings.md` switches Stage 10 and Stage 11 on and off.

---

## Folder structure

```
README.md                    This file
CLAUDE.md                    Rules every Claude session in this folder reads
docs/TOOLS.md                Every tool, with install steps
.env.example                 Settings (copy to .env)
requirements.txt             Python packages
instructions/                One file per stage (00-08, 11)
personas/                    Writer voices (create writer-profiles.md from the template)
prompts/                     Paste-in prompts that build your personas
reference/                   Style, sources, competitors, personas, CTA rules, image settings
  image-rules/               Stage 11 photo and alt-text rules
scripts/                     blog-pipeline.sh, doctor.sh, router, QC, collect, Gemini, SearXNG
cover-generator/             Stage 10: theme.json, layouts.json, templates/, fonts/ (OFL)
services/searxng/            Optional local SearXNG (docker compose)
briefs/                      Brief template (your briefs are gitignored)
inputs/                      Drop topics here (gitignored)
output/                      Drafts in progress (gitignored)
posts/                       One folder per finished post (gitignored)
research/                    Stage 0 bundles (gitignored)
logs/                        Run logs, audit CSVs, API usage, slug map (gitignored)
```

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `required tools are missing` | Run `scripts/doctor.sh` and install what it lists. |
| `no files in inputs/` | Add a topic file. `README.md` and hidden files don't count. |
| Stage 0 bundle is thin or fails | Check `claude mcp list`: Exa and Tavily must be connected. Check your API credits. |
| A stage logs tool refusals | The allowlist blocked a tool. Add it to `BLOG_ALLOWED_TOOLS` (for example an MCP server you named differently), or use `bypass` if you accept the risk. |
| `Gemini is signed out` | Sign in again in the superpowers-chrome browser, or run with `no-gemini`. |
| `the Gemini login check could not run` | The run goes on without Gemini. Run `scripts/gemini-auth-check.sh` by hand to see why. |
| `SESSION LIMIT detected` | Your Claude usage window closed. Rerun later. Finished jobs are kept. |
| `STAGE N PRODUCED NO FILE` | The stage ran but saved nothing. Read that stage's section in `logs/blog-pipeline-*.log`. |
| SearXNG returns no results | Its search engines are answering with CAPTCHAs. See [docs/TOOLS.md](docs/TOOLS.md#searxng). |
| Stage 10 cover failed | Run `make_cover.py` by hand to see the message. See [cover-generator/README.md](cover-generator/README.md). |
| `externally-managed-environment` from pip | Use a virtual environment (see [docs/TOOLS.md](docs/TOOLS.md#python-packages)). |

---

## Safety and privacy

- **Permissions.** Unattended stages can't ask before they act. By default they may only edit files, search and fetch the web, run a short list of shell commands, and call the research servers. `BLOG_PERMISSION_MODE=bypass` removes every check (`--dangerously-skip-permissions`). Use it only on a machine you'd let an unattended agent control.
- **Your work stays out of git.** `.gitignore` excludes `inputs/`, `output/`, `posts/`, `research/`, your briefs, `reports/`, `logs/` and `.env`. Check `git status` before every commit anyway.
- **Keys.** API keys live in your Claude Code MCP configuration, never in this folder.
- **Gemini.** The login check never writes your Google account email to disk. If a Gemini run fails, the script saves a screenshot and page HTML to `logs/gemini-failures/` for debugging. They show your signed-in page, so don't share them.
- **Your clone.** Once you fill in personas, competitors and client details, keep your clone in a private repository.

---

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md). MIT license, see [LICENSE](LICENSE). The cover fonts are under the SIL Open Font License 1.1 (see `cover-generator/fonts/`).
