# Tools reference

Every command-line tool, Python package, MCP server and local service this pipeline uses: what it does, which stage needs it, what it costs, how to install it on macOS and Linux, and what happens if you don't have it.

Run this any time to see what your machine has and what's missing:

```bash
scripts/doctor.sh
```

Install commands come from each vendor's own documentation (checked 2026-10-09). Vendors change their install steps, so if a command fails, follow the linked source.

Windows: run everything inside WSL 2 (Ubuntu) and follow the Linux steps.

---

## At a glance

| Tool | Kind | Needed for | Required? | Cost |
|---|---|---|---|---|
| [Claude Code](#claude-code) | CLI | every stage | **Required** | Claude Pro, Max, Team, Enterprise or Console account |
| [Python 3.9+](#python) | CLI | router, QC, collect, covers | **Required** | Free |
| [textstat](#python-packages) | Python package | Stage 9 QC readability | **Required** | Free |
| [jq](#jq) | CLI | reads each stage's JSON result | **Required** | Free |
| [curl](#curl) | CLI | health and link checks | **Required** | Free |
| [git](#git) | CLI | cloning and version control | **Required** | Free |
| [Exa MCP](#exa) | MCP server | Stage 0 discovery | **Required for Stage 0** | Paid API (free credits to start) |
| [Tavily MCP](#tavily) | MCP server | Stage 0 precision search | **Required for Stage 0** | 1,000 free credits a month, then paid |
| [coreutils `timeout`](#timeout) | CLI | time limit per stage | Recommended | Free |
| [DuckDuckGo (ddgs)](#duckduckgo-ddgs) | Python package + `scripts/ddgs-query.sh` | Stage 0 news and web search | Recommended | Free |
| [SearXNG](#searxng) + its MCP | Docker service + MCP | Stage 0 metasearch | Optional | Free, self-hosted |
| [Docker](#docker) | CLI + daemon | runs SearXNG (and self-hosted Firecrawl) | Optional | Free |
| [Firecrawl MCP](#firecrawl) | MCP server | Stage 0 page fetching for the fact-check | Optional | Free self-hosted, or paid API |
| [Node.js](#nodejs) | CLI | runs the SearXNG and Firecrawl MCPs | Optional | Free |
| [fontTools](#python-packages) | Python package | Stage 10 covers | Optional | Free |
| [resvg](#resvg) | CLI | Stage 10 covers: SVG to PNG | Optional | Free |
| [cwebp](#cwebp) | CLI | Stage 10 covers: WebP files | Optional | Free |
| [ImageMagick](#imagemagick) | CLI | checking image sizes by hand | Optional | Free |
| [shellcheck](#shellcheck) | CLI | linting the scripts after you edit them | Optional | Free |
| [Magnific](#magnific) | MCP connector | Stage 11 AI cover photos | Optional | Paid credits |

**Minimum to produce a post:** Claude Code, Python with textstat, jq, curl, git, and the Exa and Tavily MCP servers. Everything else adds sources or covers. If a source is missing, its stage logs it and continues.

---

## Package managers

| | Install |
|---|---|
| macOS | Homebrew: see https://brew.sh. Then every `brew install` below works. |
| Debian / Ubuntu | `sudo apt update` once, then the `sudo apt install` lines below. |

---

## Claude Code

Runs every stage. `scripts/blog-pipeline.sh` calls it once per stage as `claude -p` (headless). You also use it interactively for setup, single posts and Stage 11.

- **Requirements:** macOS 13+, Ubuntu 20.04+, Debian 10+ or Alpine 3.19+; 4 GB+ RAM. A Claude Pro, Max, Team, Enterprise or Console account. The free claude.ai plan has no Claude Code access.
- **Install (macOS, Linux, WSL):**
  ```bash
  curl -fsSL https://claude.ai/install.sh | bash
  ```
  Alternatives: `brew install --cask claude-code` on macOS, or `npm install -g @anthropic-ai/claude-code` (needs Node.js 22+; never use `sudo` with it).
- **Sign in:** run `claude` and follow the browser prompt.
- **Check:** `claude --version`
- **Source:** https://code.claude.com/docs/en/setup

How the pipeline calls it: `claude -p "<stage prompt>" --model <model> --effort <level> --output-format json`, plus the permission flags below.

### Permissions in batch mode

Headless stages can't stop to ask you for permission, so the script sets permissions up front. Choose with `BLOG_PERMISSION_MODE` in `.env`:

- **`allowlist` (default).** `--permission-mode acceptEdits` plus `--allowedTools` with a fixed list: file read/write/edit, web search and fetch, a short list of shell commands (`python3`, `curl`, `ls`, `cat`, `mkdir`, `mv`, `cp` and similar), the `scripts/searxng-query.sh` and `scripts/ddgs-query.sh` wrappers, and the research MCP servers (`mcp__exa`, `mcp__tavily`, `mcp__firecrawl`, `mcp__searxng`). Anything else is refused, and the stage notes it and continues. Change the list with `BLOG_ALLOWED_TOOLS`. If you named your MCP servers differently, add their names here.
- **`bypass`.** `--dangerously-skip-permissions`. Every tool runs with no check, including any shell command. Use it only on a machine and account you'd let an unattended agent control, never on a machine with production credentials.

Source for the flags: https://code.claude.com/docs/en/cli-reference

---

## Python

Runs the router, the QC checkers, the collect step, and the cover generator.

- **Version:** 3.9 or newer.
- **macOS:** `brew install python`
- **Linux:** `sudo apt install python3 python3-pip python3-venv`
- **Check:** `python3 --version`

### Python packages

All three are in `requirements.txt`:

```bash
python3 -m pip install -r requirements.txt
```

If your system Python refuses ("externally managed environment"), use a virtual environment and run the pipeline from inside it:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

| Package | Required? | Used by | If missing |
|---|---|---|---|
| `textstat` | **Required** | `scripts/qc-readability.py` (Stage 9) | Stage 9 fails |
| `fonttools` | Optional | `cover-generator/scripts/make_cover.py` (Stage 10) | Stage 10 fails, logs it, and the job continues |

Source: https://pypi.org/project/textstat/

---

## jq

Reads the JSON result of each `claude -p` call: model used, cost, duration, errors.

- **macOS:** `brew install jq` (also ships with recent macOS)
- **Linux:** `sudo apt install jq`
- **Check:** `jq --version`

## curl

Health checks for SearXNG and Firecrawl, and link checks inside stages.

- **macOS:** preinstalled
- **Linux:** `sudo apt install curl`

## git

- **macOS:** `xcode-select --install` or `brew install git`
- **Linux:** `sudo apt install git`

## timeout

Puts a time limit on each stage (`BLOG_STAGE_TIMEOUT`, default `3h`), so one hung call can't stall a whole batch. Without it, stages run with no limit.

- **macOS:** `brew install coreutils`. The command is installed as `gtimeout`; the script finds it.
- **Linux:** part of coreutils, already installed.

---

## Exa

**Stage 0, Phases A and E.** Neural search for discovery, and page fetching for the fact-check. Load-bearing: Stage 0 needs Exa and Tavily to produce a passing research bundle.

- **Cost:** paid API, about $1 per 1,000 page fetches. New accounts get free credits. Pricing: https://exa.ai/pricing
- **Key:** https://dashboard.exa.ai/api-keys
- **Add to Claude Code** (remote server, key in a header; built from Claude Code's documented `claude mcp add` syntax and Exa's documented `x-api-key` header):
  ```bash
  claude mcp add --transport http --scope user exa https://mcp.exa.ai/mcp \
    --header "x-api-key: YOUR_EXA_API_KEY"
  ```
  Exa also offers a Claude Code plugin: `claude plugin install exa@claude-plugins-official`.
- **Check:** `claude mcp list` shows `exa` as connected.
- **Sources:** https://docs.exa.ai/reference/exa-mcp, https://code.claude.com/docs/en/mcp

## Tavily

**Stage 0, Phases B and E.** Search with domain and date filters, plus page extraction. Load-bearing.

- **Cost:** 1,000 free API credits a month with no card, then paid. Read the credit note in Stage 0, Phase B before a big batch.
- **Key:** https://app.tavily.com/home
- **Add to Claude Code** (remote server):
  ```bash
  # Sign in with OAuth (Tavily's documented command):
  claude mcp add --scope user --transport http tavily https://mcp.tavily.com/mcp/

  # Or pass the key in the URL:
  claude mcp add --scope user --transport http tavily "https://mcp.tavily.com/mcp/?tavilyApiKey=YOUR_TAVILY_API_KEY"
  ```
  Name the server `tavily`, so its tools are `mcp__tavily__*` as the stage files expect. Tavily's docs call it `tavily-remote-mcp`; if you keep that name, add `mcp__tavily-remote-mcp` to `BLOG_ALLOWED_TOOLS`.
- **Sources:** https://docs.tavily.com/documentation/mcp, https://docs.tavily.com/documentation/api-credits

## DuckDuckGo (ddgs)

**Stage 0, Phase B3.** Free news and web search, no key, no quota. Required on every job; if it is missing, Phase B3 logs it and continues.

- **Install** (Python 3.10+):
  ```bash
  python3 -m pip install -U ddgs
  ```
  Stage 0 calls it through `scripts/ddgs-query.sh` (text search, `--news`, `--extract URL`). No MCP server is needed.
- **Check:** `scripts/ddgs-query.sh --num 3 "test query"` prints three results.
- **If missing:** Phase B3 logs it and continues.
- **Sources:** https://github.com/deedy5/ddgs

## SearXNG

**Stage 0, Phase B2.** A free, self-hosted metasearch engine that queries Google, Bing, DuckDuckGo and others at once. Optional.

1. **Start the server** (needs [Docker](#docker)):
   ```bash
   cd services/searxng
   # Put a random value in searxng/settings.yml -> server.secret_key first:
   openssl rand -hex 32
   docker compose up -d
   curl "http://localhost:8888/search?q=test&format=json" | head -c 300
   ```
   SearXNG refuses to start while `secret_key` is still `ultrasecretkey`. The shipped `settings.yml` already turns on the JSON format the pipeline needs.
2. **Add the MCP server** (Node.js 22+):
   ```bash
   claude mcp add --scope user searxng --env SEARXNG_URL=http://localhost:8888 -- npx -y mcp-searxng
   ```
3. **Shell use:** `scripts/searxng-query.sh "your query"`. It starts the Docker service if it's down.

- **Engines get blocked.** Search engines CAPTCHA or block SearXNG over time, and a blocked engine fails silently: queries just return fewer results, or none. With SearXNG's defaults, a test machine got zero results (Google silent, DuckDuckGo and Startpage CAPTCHAs). The shipped `settings.yml` turns those off and uses `duckduckgo web`, `yep`, `yandex` and `fynd`, which returned 43-63 relevant results per query on 2026-10-09. Check what's failing with `curl "http://localhost:8888/search?q=test+query&format=json" | jq '.unresponsive_engines'`, test one engine with `&engines=<name>`, edit the `engines:` list in `settings.yml`, and `docker compose restart searxng`.
- **If missing:** Phase B2 logs it and continues.
- **Sources:** https://docs.searxng.org/admin/settings/index.html, https://github.com/ihor-sokoliuk/mcp-searxng

## Docker

Runs SearXNG, and Firecrawl if you self-host it.

- **macOS:** Docker Desktop, https://docs.docker.com/desktop/setup/install/mac-install/
- **Linux:** Docker Engine, https://docs.docker.com/engine/install/
- **Check:** `docker compose version`

## Firecrawl

**Stage 0, Phase E.** The cheapest way to fetch each cited page for the fact-check. Optional: without it, Phase E falls through to Exa, which costs a little more.

- **Hosted API:** get a key at https://www.firecrawl.dev, then:
  ```bash
  claude mcp add --scope user firecrawl --env FIRECRAWL_API_KEY=fc-YOUR_API_KEY -- npx -y firecrawl-mcp
  ```
- **Self-hosted (free):** run Firecrawl with Docker (see Firecrawl's self-hosting guide in its GitHub repository, https://github.com/firecrawl/firecrawl), then point the MCP at it:
  ```bash
  claude mcp add --scope user firecrawl --env FIRECRAWL_API_URL=http://127.0.0.1:3002 -- npx -y firecrawl-mcp
  ```
  Set `FIRECRAWL_URL=http://127.0.0.1:3002` in `.env` so `doctor.sh` checks it.
- **Source:** https://github.com/firecrawl/firecrawl-mcp-server

## Node.js

Runs the SearXNG MCP (22+), the Firecrawl MCP, and the npm install of Claude Code (22+).

- **macOS:** `brew install node`
- **Linux:** follow https://nodejs.org/en/download (the distro package is often too old)
- **Check:** `node --version`

---

## resvg

**Stage 10.** Renders the cover SVG to PNG at exact sizes. Don't substitute ImageMagick's SVG renderer: it draws some shapes wrong.

- **macOS:** `brew install resvg`
- **Debian 13 / newer Ubuntu:** `sudo apt install resvg`. Older releases ship a very old version or none.
- **Any Linux:** `cargo install resvg` (needs Rust, https://rustup.rs), or download `resvg-linux-x86_64.tar.gz` from https://github.com/linebender/resvg/releases and put `resvg` on your `PATH`.
- **Check:** `resvg --version`

## cwebp

**Stage 10.** Makes the WebP versions of each cover. Without it, the covers are PNG only.

- **macOS:** `brew install webp`
- **Linux:** `sudo apt install webp`
- **Check:** `cwebp -version`

## ImageMagick

Not needed by the scripts. Handy for checking an image by hand: `magick identify cover.png`.

- **macOS:** `brew install imagemagick`
- **Linux:** `sudo apt install imagemagick` (the command there may be `identify` / `convert`)

## shellcheck

Lints the shell scripts. Run it after you edit one: `shellcheck -S warning scripts/*.sh`.

- **macOS:** `brew install shellcheck`
- **Linux:** `sudo apt install shellcheck`

---

## Magnific

**Stage 11.** Generates AI cover photographs from four image models. Interactive only: Magnific's sign-in lives in your interactive Claude session and doesn't carry into the headless `claude -p` runs, so the batch script never calls it.

- **Cost:** any Magnific account works. Each image uses Magnific credits, which cost money.
- **Add to Claude Code:**
  ```bash
  claude mcp add --scope user --transport http magnific https://mcp.magnific.com
  ```
  Then run `/mcp` in a `claude` session and sign in. On claude.ai you can add it instead as a custom connector (Customize, Connectors, Add custom connector, URL `https://mcp.magnific.com`).
- **Turn it on:** set `**AI cover:** on` in `reference/image-settings.md`.
- **Check:** in a `claude` session, ask Claude to call `mcp__magnific__account_balance`.
- **Source:** https://docs.magnific.com/modelcontextprotocol

---

## Scripts that ship with this repo

| Script | What it does | Calls |
|---|---|---|
| `scripts/blog-pipeline.sh` | Runs every topic in `inputs/` through Stages 0-10 and files each post | `claude`, `jq`, `python3`, `timeout`, every script below |
| `scripts/doctor.sh` | Checks this machine; prints install commands | `claude mcp list`, `curl`, `python3` |
| `scripts/router.py` | Classifies `inputs/` and writes `inputs/.manifest.json` | Python stdlib |
| `scripts/qc.sh` | Stage 9 QC report (`--append` writes it into the draft) | the three `qc-*.py` checkers |
| `scripts/qc-prohibited-scan.py` | Banned words and phrases from `reference/prohibited-phrases.md` | Python stdlib |
| `scripts/qc-readability.py` | Reading grade, sentence length, em dashes, passive voice | `textstat` |
| `scripts/qc-structure-check.py` | Heading levels, bold-as-heading, other structure rules | Python stdlib |
| `scripts/collect-post.py` | Moves a finished post's files into `posts/<date>-<slug>/` | Python stdlib |
| `scripts/gemini-auth-check.sh`, `scripts/gemini-deep-research.py` | Retired 2026-10-14 with Gemini; kept for manual use only | |
| `scripts/searxng-query.sh` | Queries SearXNG from the shell | `curl`, `python3`, `docker` |
| `cover-generator/scripts/make_cover.py` | One template cover | `fonttools`, `resvg`, `cwebp` |
| `cover-generator/scripts/covers_from_drafts.py` | Covers for every dated draft | `make_cover.py` |

Each script documents its options in its header comment. Most also print them with `--help`.
