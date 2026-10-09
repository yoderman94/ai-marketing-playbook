# HANDOFF: AI Marketing Playbook

Public repo `yoderman94/ai-marketing-playbook`. Every public Claude template lives here as a folder. Last updated 2026-10-09.

**Status: beta.** The main README and both pipeline READMEs say so. Remove those notes only after both pipelines pass a real end-to-end run.

Owner: `yoderman94`. Collaborator with push access: `CubeCreativeDesign`.

## Layout and ownership
- `projects/`: paste-in Claude Project templates.
- `cowork/private-schools/`: Cowork pipeline, Stage 0 plus 8 content stages, no scripts. Refreshed 2026-10-09 from the production schools pipeline (v1.14.0) and made generic.
- `claude-code/b2b-blog-pipeline/`: the scripted pipeline, v2.0.2. It has its own VERSION, CHANGELOG and HANDOFF. It moved here from the standalone `b2b-blog-pipeline-template` repo, which is now archived. Fix it here.

## What is verified (2026-10-09)
| Check | Result |
|---|---|
| Fresh clone | All folders arrive, including empty `output/` and `research/` in both pipelines. |
| b2b folder copied out on its own | `scripts/doctor.sh` exits 0. `scripts/qc.sh` runs on a sample draft. |
| Links | Every relative link and every file path a stage file cites resolves. External links in the README, getting-started and projects return 200. |
| Scrub | The internal-name and client-name grep has 0 hits. `gitleaks dir .` finds no leaks. |
| Old repo | `CubeCreativeDesign/b2b-blog-pipeline-template` is archived. Its README points here. |

Not verified: a Cowork run of the schools pipeline, and a full b2b Stage 0-11 run from inside this repo. The b2b content is unchanged from its 2.0.0 release test except the SearXNG engine set (2.0.1) and the move (2.0.2).

## Deliberate choices
- The author byline and the agency links appear only in the top-level README, CLAUDE.md and LICENSE. Template folders use `[YOUR_...]` placeholders.
- The Cowork pipeline has no QC script. Stages 2 and 3 write a Self-Check block that Claude fills by judgment. Stage 3 replaces the Stage 2 block.
- `reference/k-12-private-school-personas.md` and `k-12-private-school-competitors.md` stay templates. Never fill them with real client data.
- Two reader persona templates exist on purpose: the long guide in `k-12-private-school-personas.md` and the short `READER-PERSONA-TEMPLATE.md`. Each points to the other.
- The `projects/titles-meta-keywords.md` limits (60 characters, 160 for the meta) are maximums. The pipelines aim lower (title about 55).

## Open items
- Run the Cowork schools pipeline on one real topic. Record what broke here, then decide whether to drop the beta note.
- The b2b Stage 4 meta template still ends in "[Why from us/CTA]". Check it against the no-phone-CTA rule.
- Both pipelines are forks of production pipelines that keep changing. Fixes don't flow here on their own. Port worthwhile changes by hand and log them in the folder's changelog.

## Before every commit
Run the deny-list grep and `gitleaks dir .` (see CLAUDE.md). The repo is public, so every push needs the owner's OK. The owner runs the push.
