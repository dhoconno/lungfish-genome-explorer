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
| D8 | **DECIDED 2026-09-24 (owner):** Filtered-sheet cell comments carry the exact user notes only. The evidence summary ("display=…, raw support=…") moves to its own column. Remove the five `KNOWN_PREEXISTING_FAILURES` entries once the tests are reconciled. Earlier interim text: the Genotype Excel Filtered-sheet comment contract. Five tests expect comments wrapped as "Evidence: display=…, raw support=…", while the green contract test `GenotypeExcelExportServiceTests.testMatrixCommentsAreExactUserNotesAndReviewsRemainPureFormatting` requires exact user notes. Both fail or pass that way at the pre-audit base. Until decided, the five are quarantined in `scripts/full-suite-gate.sh` (`KNOWN_PREEXISTING_FAILURES`, ledger TST-15) so the release gate stays usable | Team (interim) | Remove entries once decided |
| D9 | **BAM read display is depth-capped, not count-capped.** Default maximum displayed depth 500x (range 50 to 5,000). Regions below the cap show every read, and deeper regions are subsampled per ~1 kb bin (`samtools --subsample` fractions from a depth query using the same filters). A 250,000-read ceiling stays as a safety net. The Inspector has a slider with direct numeric entry to override the cap. Replaces DS-02 | Owner | Prototype: 50x flanks kept at 50x (was 3.7x), 5,000x block held near 440x |
| D10 | **One slider control everywhere.** Every slider uses the shared `NumericSliderField` with the same look and a numeric field for direct entry, enforced by the `scripts/ratchets/shared-slider-control.sh` pre-push ratchet | Owner | |
| D11 | **GEN-02:** a haplotype counts as matched only when at least one observed diagnostic allele is not explained by another matched haplotype | Owner | Homozygotes call correctly |
| D12 | **GEN-04:** identical reference sequences (including reverse complements) are detected at reference load, collapsed to one representative, and carry an "ambiguous with" list | Owner | |
| D13 | **GEN-05:** one denominator per **source locus**, computed identically in the genotype viewer, the haplotype viewer and the haplotype caller. Source loci can have very different depths, so each is normalized on its own | Owner | Not the haplotype-group option |
| D14 | **GEN-06:** "Min %" is the per-sample read fraction for known and candidate rows alike. A separate control, "Seen in ≥ N% of animals", filters by prevalence | Owner | |
| D15 | **GEN-10:** a zero-SNP full-length ONT hit stays "known" even with indels, because stochastic ONT indels would otherwise cause false negatives. Add an indel column and a review flag | Owner | |
| D16 | **REL-03:** keep the owner's email in the GPL source offer, pin licence links to the release tag, elect BSD for zstd | Owner | |
| D17 | **REL-04:** deferred to a release expert (orchestrator). See the REL-04 lane result in the ledger | Owner → Team | |
| D18 | **NEW-11:** the no-follow walk starts at the project or bundle root, opened by path (which works with user-granted project access). Components below the root keep symlink protection | Owner | |
| D19 | **EsViritu read format for single-file input (NEW-06).** Owner: detect interleaving and run pairs as pairs, but merged reads (VSP2 merges overlapping pairs) must be single-end. EsViritu's `-p` takes `unpaired`, `paired` or `interleaved` only. `interleaved` sends one file to fastp `--interleaved_in`, which pairs records by position, and there is no mixed mode. Two runs would need merged abundance tables, which EsViritu cannot produce. So: **strictly interleaved** input (every record next to its mate by LGE's pairing rule) runs once as `interleaved`, labelled "Interleaved paired-end reads". **Mixed** input (pairs plus merged or orphan reads, or merge evidence in bundle metadata) runs once as `unpaired`, labelled "Mixed paired and merged reads (run as single-end)", with layout, counts and reason in provenance. True single-end and separate R1/R2 files are unchanged | Owner + Team | Classification is a bounded scan (first 100,000 records) plus metadata. The pipeline re-checks `interleaved` on the materialized file and falls back to `unpaired` |
| D20 | **NEW-02:** rescan the project tree when a window becomes key or the app activates, as a backstop to the FSEvents watcher | Owner | |
| D6a | **Amendment to D6 (2026-09-24):** `appSmokeRequired` stays **false** in `config/release-contract.json`, as on main, until the owner creates the dedicated `lungfish-release-qa` macOS account. The real-app smoke must run as that account at the graphical console with clean Lungfish state, which cannot be satisfied on this Mac, so `true` would block every release. The green unit-tier evidence requirement from D6 stays. For this release the packaged candidate gets a Computer Use walkthrough instead. To re-enable, create the account and flip the contract value and `EXPECTED_GATES` in `scripts/tests/test_release_contract.py` together | Team (release) | Reversible, one value |
| D21 | **Adopt unfinished work from idle sessions when it is complete and tested.** The idle "setup-worktree bare return" session's uncommitted fix was carried into this release (43e077716) so the owner's "no outstanding worktrees" request does not destroy work. Its finished SRA select-all plan (already implemented on main) was moved to the Trash under the docs-retention rule | Team | |
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
