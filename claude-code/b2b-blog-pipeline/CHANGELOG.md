# Changelog

All notable changes to the B2B service blog pipeline template are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **This is a template.** When you clone it to start a new vertical, reset
> `VERSION` to `1.0.0` and start a fresh changelog for that vertical. The
> entries below track the template itself, not any cloned pipeline.

## [2.1.0] - 2026-10-12

### Changed
- Stage 0 Phase B3 runs DuckDuckGo through the bundled CLI wrapper `scripts/ddgs-query.sh` (text, `--news`, `--extract URL`, with backend fallback) instead of the ddgs MCP, and it is required on every job. Install the package with `python3 -m pip install -U ddgs`. The ddgs MCP is no longer needed. `scripts/doctor.sh` checks for the package, and the batch allowlist includes the wrapper.

## [2.0.2] - 2026-10-09

### Changed
- The template moved into the AI Marketing Playbook repo as
  `claude-code/b2b-blog-pipeline/`. The old standalone repo is archived.
- README quick start: clone the playbook, then copy this folder out as your own project.

## [2.0.1] - 2026-10-09

### Fixed
- `services/searxng/searxng/settings.yml`: SearXNG's default engines returned no results from a residential connection (Google silent, DuckDuckGo and Startpage CAPTCHAs). It now ships with a tested engine set (`duckduckgo web`, `yep`, `yandex`, `fynd`) and says how to re-test engines. `docs/TOOLS.md` explains the failure mode.

## [2.0.0] - 2026-10-09

First public release. The template now runs on its own from a fresh clone, on
macOS or Linux, with no files from outside the repo.

### Added
- `scripts/`: the batch runner (`blog-pipeline.sh`), the input router, the Stage 9
  QC suite (`qc.sh` plus three Python checkers), `collect-post.py`, the Gemini
  Deep Research helpers, the SearXNG wrapper, and `doctor.sh`, which checks every
  tool and prints the install command for anything missing.
- `docs/TOOLS.md`: every command-line tool, Python package and MCP server the
  pipeline uses, with what it does, which stage needs it, what it costs, and
  install steps for macOS and Linux.
- `cover-generator/`: Stage 10 template covers. Four layouts, three color
  palettes, two free OFL fonts. Brand it in `theme.json` and `templates/`.
- `reference/image-rules/`: the photo-prompt and alt-text rules Stage 11 reads.
- `services/searxng/`: an optional local SearXNG (docker compose).
- `.env.example`, `requirements.txt`, `LICENSE`.
- `[YOUR_VERTICAL_SLUG]` placeholder for URL paths, so a vertical with a space ("commercial HVAC") still makes valid URLs.
- A warning before a batch when the Exa or Tavily MCP server isn't connected.

### Changed
- **Stage numbers.** Stage 10 is now the scripted template cover. The interactive
  AI cover stage moved to Stage 11 (`instructions/11-ai-cover-image.md`).
  `reference/image-settings.md` has a switch for each: `Template cover` and `AI cover`.
- The batch runner's headless stages now run with an allowlist of tools by
  default. `BLOG_PERMISSION_MODE=bypass` restores `--dangerously-skip-permissions`.
- Models, sleep timers, the per-stage timeout and service URLs are settings
  (`.env` or environment variables).
- Logs, the API usage log and the slug map live in `logs/` inside the project.
- `.gitignore` now keeps `posts/`, `briefs/`, `reports/`, `logs/` and `.env` out of git.
- Em-dash rule unified at 1 per 300 words of body copy, everywhere.
- Covers try the short H1 SEO title first, then the H2, then the H3 image title.

### Fixed
- `collect-post.py` read the slug map from a different place than the batch
  runner wrote it, so research filed under a topic slug never reached the post.
- The Gemini login preflight reported "login confirmed" when the check script
  was missing or not executable.
- An `inputs/` folder with only hidden files ended the run with no message.
- Values from the manifest were pasted into Python source, so a quote in a slug
  or path broke the run.
- The Gemini login check no longer writes the account email to disk.

### Removed
- The Ollama preflight (no stage used it), the Google Drive upload step, and the
  hooks into tools that don't ship with the template.
