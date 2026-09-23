# Decisions for the implementation round

**Recorded 2026-09-23.** "Owner" means the user decided. "Team" means the orchestrating panel decided in the owner's absence, with the owner's standing authority: an Opus 5.5 orchestrator plus LGE, bioinformatics, UI/UX and Swift performance review lenses. Team decisions are conservative. Where a decision is contested, the reversible option wins.

## Execution

| Topic | Decision | By |
|---|---|---|
| Implementation | Proceed with the plan. An Opus 5.5 orchestrator decomposes the work and reviews every diff. Lesser models (Sonnet, Haiku) implement bounded tasks | Owner |
| Git | Work lands on `claude/lge-best-practices-audit-0a1b8f`, merged with `origin/main` at 2026.9.39, and is pushed to origin. **No merge to main.** | Owner |
| Releases | **No release is cut.** Release notes and prep are left for the owner | Owner |
| Deliverable build | At the end, a debug build of the branch is installed at `/Applications/Lungfish Debug.app` for the owner to test | Owner |
| GUI verification | Computer Use uses the installed `/Applications/Lungfish Preview.app` (2026.9.39) to confirm findings before fixes. Fixes are verified in the branch's debug build. Scratch projects only. Never open or modify the owner's real projects | Owner |
| CI | No GitHub-runner checks. All gating is local | Owner |

## Product decisions

| # | Decision | By | Notes |
|---|---|---|---|
| D1 | **FASTQ quality binning is off by default everywhere.** It is opt-in at import only, named correctly and recorded in provenance. It is never applied silently to downloads or derived operation outputs | Owner | Closes WFL-01 and SCI-08 in P0-B |
| D2 | Legacy ONT workbook-transaction recovery code is **kept this round** as read-only recovery and deleted in a later round | Team | Deleting recovery paths while the owner is away is not reversible for users with pending transactions |
| D3 | PrimalScheme coverage and allele modes are **not removed**. The primer work is under active development. The only action is verifying the lge.5 contract-version suspicion (SIMP-03). If it is confirmed broken, the version checks are fixed | Team | |
| D4 | "GATK + WhatsHap Phased" is **hidden** from the caller list until implemented | Team | Reversible: one catalog flag |
| D5 | **AI haplotyping is not exposed.** The owner disabled it as unreliable. Every entry point is verified unreachable, and any remaining surface is removed from the main viewport. The code is kept behind the disabled flag | Owner | |
| D6 | The release gate requires a green unit tier at the release commit, an app launch smoke and a file-mode check. A nightly launchd job is provided but not installed. The owner installs it if wanted | Team | |
| D7 | `ONTGenotyping` gets a review-only scientific correctness report this round. It produces no code changes unless a P0 is found | Team | |
| Docs | Finished engineering notes are **deleted**. Manual media moves to a **private** `dhoconno/lungfish-manual-media` repo, **pinned per release** with `media.lock`. Git history is **not** rewritten | Owner | See [docs-strategy.md](docs-strategy.md) |

## Consensus rules for the team

- **Scientific defaults follow the tool authors' documented recommendations.** Deviations are recorded in provenance and the help text. Examples:
  - viral bcftools: `--ploidy 1`, depth cap well above amplicon depth;
  - iVar: GFF with per-segment CDS and phases.
- **Changing numbers users see needs a golden test and a release-note line.** Persisted caches get a version bump so old values are recomputed rather than trusted.
- **When a feature is broken and a fix is large, hide it rather than ship it broken.** Keep the code, gate the entry point, and log the decision in the ledger.
- **Never delete user data to fix a bug.** Anything written by a migration or cleanup goes to the Trash or a recovery folder.
- **UI changes follow the existing conventions.**
  - Accent `#D47B3A`.
  - Single-line rows, with the EsViritu viewer as the reference.
  - The shared `BatchTableView` and the operations dialog shell.
  - The Run button says "Run".
