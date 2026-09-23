# LGE best-practices audit (fresh start)

**2026-09-23 · Review only · HEAD `a1f439076` (Preview 2026.9.38) · branch `claude/lge-best-practices-audit-0a1b8f`**

Nine specialist reviewers assessed Lungfish Genome Explorer (LGE) independently. None of them read the 2026-09-05 audit while forming findings. A tenth reviewer then compared the two audits. No source, test, script or config file was changed.

- **Builds and tests:** one reviewer ran a cold build and the documented unit tier.
- **Scientific checks:** another ran the managed samtools, bcftools, iVar and LoFreq on synthetic inputs and the SARS-CoV-2 fixture.
- **GUI:** the app was not launched. GUI findings are traced through the source and must be confirmed in a hands-on pass (see [Verification still owed](#verification-still-owed)).

## Overall judgment

LGE is a substantial and in many places well-built application. The module graph is sound and enforced by SwiftPM. There is no AppKit below the UI kernel, and the CLI stays separate. Swift 6 concurrency hygiene is better than the pace of development suggests. The provenance framework, the FSEvents watcher, the async sidebar scan, the Operations panel, the Trash-based deletes and the gate's fail-closed result parser are all worth keeping.

The problems are not in the foundations. They are in **how features were added on top of them.** Most features were written quickly, one at a time, by agents that bypassed shared machinery that already existed. Four patterns explain most of the 162 findings:

1. **Silent data changes and wrong numbers on main paths.** Several paths do this without telling the user:
   - quality binning and even Trim Galore applied to FASTQ outputs;
   - manifest rewrites that drop alignment tracks;
   - same-name FASTQ imports that replace existing samples;
   - an IQ-TREE command that deletes shared scratch and existing output;
   - unique-read counts capped at 100,000;
   - an iVar annotation file that merges the ORF1ab frameshift into one span.

   These are the most serious findings, and none of them is new since 2026-09-05. The prior audit left scientific review out of scope.
2. **The same action goes through several code paths.**
   - There are two execution models for analyses (in-process and via the CLI).
   - The CLI runners are copied nine times.
   - FASTQ command lines are encoded three ways, and the GUI and CLI write different provenance.
   - A BAM means one thing when dropped on the sidebar and another in Import Center.

   Each copy drifts. The drift appears as "Copy CLI command" strings that cannot run, options the wizard shows but never passes, and results the sidebar cannot open.
3. **Contracts that are optional.** `OperationCenter.start` returns an ordinary ID even when it refuses a locked bundle. Window scoping of notifications fails open. Export failures are logged but not shown. When the safe path is opt-in, older callers keep the unsafe default. This is exactly why 14 of the 35 findings from 2026-09-05 are only partly fixed ([reconciliation](reconciliation.md)).
4. **Verification weaker than it looks.**
   - The documented pre-push unit tier is **red at HEAD**: 117 failures and one test that hangs forever.
   - The release gate runs 186 of about 14,200 tests. The pre-push hook is not installed in the main checkout.
   - About 300 tests read production source as text.
   - Eleven releases shipped over the red tier.

   Separately, **every shipped app bundle is readable only by the account that installed it** (a `umask 077` problem), and no gate checks file modes.

**Recommendation:** don't rewrite anything and don't pause feature work for a long time. Do a short, strict stabilisation phase first: fix the ship-blockers and data-loss paths, then make the local gates trustworthy. After that, remove duplicated paths one family at a time, and make each shared contract impossible to bypass so the fixes stay fixed. The phased plan is in [implementation-plan.md](implementation-plan.md).

## Review packet

| Report | Prefix | Findings | Focus |
|---|---|---:|---|
| [architecture.md](architecture.md) | ARC | 16 | Layering, composition roots, execution models, globals, process launching |
| [concurrency-performance.md](concurrency-performance.md) | PERF | 16 | Main-thread blocking, actor stalls, cancellation, rendering, memory |
| [features-data-viewers.md](features-data-viewers.md) | FEA | 17 | Entry points and dead ends in import, viewers, export, settings |
| [features-workflows.md](features-workflows.md) | WFL | 21 | End-to-end matrix of 25 analysis workflows |
| [scientific-integrity.md](scientific-integrity.md) | SCI | 21 | Coordinates, variant calling, statistics, extraction, provenance |
| [consistency-ux.md](consistency-ux.md) | UX | 18 | Cross-viewer consistency, HIG, keyboard, accessibility |
| [simplification.md](simplification.md) | SIMP | 17 | Dead code, duplication, overengineering, repo hygiene |
| [testing-ci.md](testing-ci.md) | TST | 14 | Suite value, flakiness, gates; includes the build and unit-tier run |
| [release-dependencies.md](release-dependencies.md) | REL | 17 | Signing, Sparkle, version sites, licensing, dependency pinning |
| [reconciliation.md](reconciliation.md) | REC | 5 extra | Status of the 35 findings from 2026-09-05, contradictions, lessons |
| [docs-strategy.md](docs-strategy.md) | | | Where docs, media and process records should live (owner decisions recorded) |
| [implementation-plan.md](implementation-plan.md) | | | Phased work packages, dependencies, acceptance gates, execution rules |
| [_BRIEF.md](_BRIEF.md) | | | The shared rules every reviewer followed |

Confidence labels are used throughout: **Confirmed** means reproduced by running something, **Traced** means followed end to end in source, **Suspected** means plausible but needing verification. Priorities: P0 is data loss, wrong scientific results, security or release-breaking. P1 is a broken main path or a serious performance or design flaw. P2 is an inconsistency or partial feature. P3 is polish.

## P0 findings

| ID | Finding | Confidence | Plan |
|---|---|---|---|
| REL-01 | Shipped app bundles are owner-only (0700/0600) because `umask 077` is set before `xcodebuild`. Verified on the published 2026.9.38 DMG and the installed 2026.9.37 and 2026.9.28 | Confirmed | P0-A |
| TST-01 | Pre-push unit tier red: 115 XCTest + 2 Swift Testing failures and a 14-minute hang. Most come from `821ca701a` (stable-namespace test homes, Swift Build resource paths). About 12 are real drift the tests correctly catch | Confirmed | P0-A |
| TST-02 | No gate runs the broad suite. The release gate has 186 tests, the hook is not installed, and the app-launch smoke is optional | Confirmed | P0-A |
| FEA-01 | Variant-deletion paths rewrite `manifest.json` without alignment tracks and the record store, so BAM tracks vanish | Traced | P0-B |
| FEA-02 | GUI FASTQ import always passes `--force` into `Imports/`, while the duplicate check looks at the project root. Same-named samples replace existing bundles and their subsets | Traced | P0-B |
| WFL-02 | `tree infer iqtree` deletes the shared project `.tmp` and deletes existing output even when it refused to overwrite. It can also hang because it waits before reading output. Siblings in MSA and `tree` are listed as REC-02 | Traced (lead reviewer re-read the code) | P0-B |
| WFL-01 + SCI-08 | FASTQ operation outputs are silently quality-binned on re-import, even ONT and PacBio. Above a size threshold the clumping default becomes Trim Galore. Originals are deleted and nothing is recorded in provenance | Traced | P0-B (needs owner decision D1) |
| PERF-04 | TaxTriage and EsViritu "Unique Reads" use `fetchReads` with the default `maxReads: 100_000`, so counts can never exceed 100,000 per contig. TaxTriage batches persist these values | Traced (lead reviewer re-read the code) | P0-C |
| SCI-01 | The GFF given to iVar collapses multi-segment CDS (the ORF1ab −1 frameshift, spliced genes) into one span, so amino-acid calls and codon merging are wrong | Confirmed with iVar | P0-C |

## P1 findings, grouped by theme

The same defect is often reported by several reviewers from different angles. Clusters are merged below.

- **Scientific correctness:**
  - duplicate VCF records for overlapping CDS (SCI-02);
  - AF and depth thresholds ignored for LoFreq, bcftools, Medaka and Clair3 but recorded as applied (SCI-03, WFL-10);
  - bcftools runs diploid with a 250 depth cap (SCI-04);
  - mapping rate counts records, not reads (SCI-05);
  - extraction ignores strand and splicing (SCI-06);
  - reverse-complement extraction leaves variants untransformed (SCI-07);
  - NAO-MGS coverage is inflated (SCI-09).
- **Dead ends on main paths:**
  - "GATK + WhatsHap Phased" shows Ready, then always refuses (WFL-03);
  - pbAA and Savont results cannot be opened (WFL-05);
  - renamed classifier batches cannot be reopened (WFL-06);
  - the Remove Human Reads picker discards the chosen file (WFL-07);
  - BAM primer trim never matches contig names (WFL-08);
  - Viral Recon loses outputs on caller overrides (WFL-04);
  - no shared dependency preflight (WFL-09);
  - alignment sort and colour modes are implemented but unreachable (FEA-08).
- **Edits that do not persist:** annotation delete and edit from the viewer or Inspector does nothing on reference bundles, behind a "cannot be undone" confirmation (FEA-03, UX-01, REC-05). Multi-file BAM or VCF import processes only the first file (FEA-05).
- **Operation lifecycle:**
  - `start` refusals can be ignored, and seven callers do (ARC-04, FEA-07, with one sub-claim corrected in the reconciliation);
  - no warning on quit while work runs (FEA-06);
  - cancellation stops only the helper (PERF-13, WFL-12);
  - no gate timeout, and a possible real cancel bug in `CLIImportRunner` (TST-05).
- **Entry-point divergence:** the same BAM or VCF behaves differently by entry point (FEA-04, FEA-14, REC-04). The CLI strings shown in the Operations panel cannot be run, and the GUI and CLI write different provenance (ARC-01, ARC-03, ARC-07, ARC-09, WFL-11, FEA-12, SIMP-01). The nine CLI runners are copy-pasted (ARC-02, SIMP-04).
- **Main-thread and actor stalls:**
  - whole-BAM hashing on main (PERF-01);
  - `NativeToolRunner.shared` blocked for a child's lifetime (PERF-02);
  - TaxTriage runs samtools on main (ARC-13, PERF-03);
  - a synchronous full project rescan after each import (PERF-05);
  - GFF3 export decompresses the whole genome (PERF-06).
- **Silent failures:** export failures are never shown in five viewers (UX-02).
- **Release and legal:**
  - a GPL-2.0 kernel is shipped with no notice or source offer, and THIRD-PARTY-NOTICES is stale and not bundled (REL-03);
  - there is no way to withdraw ("yank") a bad Sparkle release (REL-04);
  - a 180 s cap covers every `gh` call, including the 167 MB upload (REL-05);
  - test resources broke under Swift Build (TST-03), and about 75 tests broke after the stable-namespace change (TST-04).

P2 and P3 findings (about 110) are in the specialist reports, and their work packages are in the plan.

## Corrections and owner decisions applied during synthesis

- **FEA-07, third bullet, is wrong.** Annotation-drawer deletion does check the lock ([ViewerViewController+AnnotationDrawer.swift:486](../../../Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift:486)). The rest of FEA-07 stands ([reconciliation §1.1](reconciliation.md)).
- **REL-02 and TST-06 are reframed.** The owner paused GitHub Actions CI deliberately, for build-time and credit cost and low value. **Any CI-style checking must run locally, never on GitHub runners.** The remaining action is to disable `ci.yml` cleanly (manual-dispatch only or `gh workflow disable`) so pushes stop failing as invalid. The prior audit's QR-04 and QR-07 "regressions" split the same way: the hosted-CI half becomes an accepted owner decision, and the local-gate half (TST-02, REL-09, TST-12) stays open as P0 and P2 work.
- **Docs strategy decided** ([docs-strategy.md](docs-strategy.md)). Finished engineering notes are deleted, not archived. Manual media moves to a media repo pinned per app release. Git history is not rewritten, because the Sparkle build number is `git rev-list --count HEAD`.
- **Project memory corrected.** `MapReadsWizardSheet` does not exist and `OrientWizardSheet` is dead, contrary to the recorded dialog-template convention. The lead reviewer checked both.
- **Lead-reviewer spot checks.** REL-01 (`umask 077` at [build-notarized-dmg.sh:1254](../../../scripts/release/build-notarized-dmg.sh:1254)), WFL-02 ([TreeCommand.swift:451-462,596-600](../../../Sources/LungfishCLI/Commands/TreeCommand.swift:451)) and PERF-04 ([EsVirituResultViewController.swift:1021](../../../Sources/LungfishEsVirituUI/EsVirituResultViewController.swift:1021) with [AlignmentDataProvider.swift:436](../../../Sources/LungfishIO/Bundles/AlignmentDataProvider.swift:436)) were re-read and hold. For the SIMP-03 "lge.5 breaks coverage and allele modes" suspicion, the constants are hard-pinned to lge.3 and lge.4 ([PrimalScheme3DesignPipeline.swift:283-285](../../../Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3DesignPipeline.swift:283)). Whether lge.5 reports those contract versions was not verified, so it stays Suspected.

## Relationship to the 2026-09-05 audit

From [reconciliation.md](reconciliation.md):

- **Status of the 35 prior findings:** 19 fixed, 14 partly fixed, 2 regressed, none left fully open.
- **Where fixes stuck:** where one shared function serves every caller.
- **Where fixes stayed partial:** where each caller had to adopt a pattern.
  - A sibling mutation service still deletes its backup (REC-01).
  - MSA and tree `--force` still delete output before work (REC-02).
  - Kraken2 taxonomy and BLAST exports have no provenance (REC-03).
- **The two regressions (QR-04, QR-07):** a concurrent release redesign (`34548a699`) cut the release gate to 8 classes and made the app smoke optional six hours after the remediation. Nobody reconciled it.
- **Where the P0s came from:** every fresh P0 is in code that existed at the prior baseline. The prior audit excluded scientific review, and its deferred per-family journey checks were never run.
- **Unreviewed area:** the `ONTGenotyping` area is about 24% of changed lines since then, and neither audit has reviewed it for scientific correctness.

## Decisions needed from the owner

These block specific work packages. Each has a recommendation.

| # | Decision | Recommendation | Blocks |
|---|---|---|---|
| D1 | Should FASTQ quality binning stay a default? It is on by default at import, and silent on downloads and operation outputs | Off by default everywhere. Opt-in at import only, with the scheme named correctly and recorded in provenance. Never silent on derived outputs | P0-B |
| D2 | Recovery window for legacy ONT workbook transactions (5.9K lines with no remaining writer) | One release of read-only recovery, then delete | P5 |
| D3 | Are PrimalScheme coverage and allele modes shipped features or research? | Research: remove from the product, keep in the fork | P5 |
| D4 | "GATK + WhatsHap Phased": hide or implement? | Hide now, implement only on user demand | P2 |
| D5 | AI haplotyping in the main viewport (no key check, no consent, macaque defaults) | Move behind a Settings opt-in with a disclosure | P2 |
| D6 | Release cadence and gate cost. There were about 38 previews this month. A stronger local gate adds roughly 12 minutes per release (the unit tier took about 12 minutes, excluding the hung test) | Keep the cadence but require the unit tier and an app launch at the release commit. Run full, integration and real-tool tiers nightly through launchd | P0-A |
| D7 | Scientific-correctness review of `ONTGenotyping` (unreviewed by either audit) | Commission a focused review before the next genotyping feature | P3 |

## Verification still owed

These items are reviewed from source only and still need hands-on checks:

- **GUI journeys.** The data-viewers report lists 15 journeys that most need a hands-on walkthrough. The workflow report's matrix marks further rows as Suspected. Project policy is that GUI findings are confirmed with Computer Use on a debug `.app` build, not by code reading. The plan makes this the first step of each GUI package.
- **Suspected items needing a focused reproduction before any fix:**
  - UX-03: controller-level shortcuts never fire;
  - SCI-16: interleaved subsample is not pair-aware;
  - TST-05: `CLIImportRunner.cancel` leaves a live child;
  - REL-08: legacy alpha installs are offered builds with a different bundle ID;
  - SIMP-03: lge.5 contract versions.
- **Build output in the worktree.** The testing reviewer's run left build output in this worktree's `.build`. Its per-test failure list is in the session scratchpad (`unit-gate/gate.result.json`) and can be regenerated with `scripts/full-suite-gate.sh --tier unit`.
