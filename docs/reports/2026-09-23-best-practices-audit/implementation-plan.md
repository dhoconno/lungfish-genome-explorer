# Implementation plan: 2026-09-23 best-practices audit

**Companion to [README.md](README.md). Baseline HEAD `a1f439076`. Nothing in this plan has been started.**

This plan orders the work from the specialist reports into phases and packages. Each specialist report has a "Proposed work packages" section with fuller file lists; this plan points to those sections and does not repeat them. Where two reports proposed overlapping packages, they are merged here and the merged package lists every finding it closes.

## Part 1. How to run this (read first)

The [reconciliation](reconciliation.md) showed why fixes from 2026-09-05 stayed partial: they were applied to named callers instead of to a contract, and a concurrent effort reversed others. These rules exist to prevent a repeat. They are binding for every package.

1. **Re-verify before fixing.** HEAD will have moved. The implementer confirms each finding still holds at the current commit, and records "still holds / already fixed / changed shape" in the package's results note. Suspected findings get a focused reproduction first. If it fails to reproduce, the finding is closed as not reproduced, not "fixed".
2. **Scope by contract, not by file list.** Every package that repairs a contract starts with a search query that finds every caller, for example `rg "targetBundleURL:"` or `rg "try\? FileManager.default.removeItem\(at: output"`. The query and its hit count go in the results note. The package is done when every hit is migrated or explicitly exempted with a reason.
3. **Make the unsafe path impossible, not optional.** Prefer API changes that make misuse a compile error:
   - a `start` that returns a handle or throws;
   - a `WindowContext` parameter instead of globals;
   - one `CLIInvocation` type that is both executed and displayed.

   Deprecate, then delete, the old entry point in the same phase.
4. **Test at the caller level.** For each family of callers, write one behavioural test that drives a real caller through the refusal or failure path. Do not add tests that grep production source. Where a structural rule is needed, put it in a **local ratchet script** (a count of unsafe call sites that may only go down) run by the pre-push hook. Do not express it as an XCTest.
5. **Scientific changes carry evidence.** Any change that alters numbers or files users see gets:
   - a golden-output fixture test;
   - a release-note line saying which results change and whether existing results must be recomputed;
   - a cache or schema version bump where values are persisted.
6. **GUI changes are confirmed in the GUI.** Each GUI package starts and ends with a Computer Use walkthrough of its affected journeys on a debug `.app` build (per project memory, the raw SwiftPM binary is invisible to screen capture). Use the 15 journeys listed in [features-data-viewers.md](features-data-viewers.md) as the checklist.
7. **All gating is local.** There are no GitHub-runner checks (owner decision). Gates are the pre-push hook, `scripts/full-suite-gate.sh` tiers, `release.py` gates and an optional nightly launchd job.
8. **Serialize SwiftPM.** There is one `.build/.lock` per checkout. Run implementer agents one at a time per checkout, or give each its own worktree. Never run two `swift build` or `swift test` commands against the same `.build`.
9. **One findings ledger.** Keep `ledger.md` in this folder: a table of finding ID, status, package, commit and verification evidence. Any change to release gates, test tiers or a contract listed here must update the ledger. This is how a concurrent redesign is prevented from silently undoing a fix again.
10. **Delete finished process docs** (owner decision). When a package is complete, its results note is folded into `ledger.md` and any scratch plan is deleted in the same commit.

## Part 2. Phases at a glance

| Phase | Theme | Packages | Rough size | Can start |
|---|---|---|---|---|
| **P0** | Stop the bleeding | P0-A gates and ship-blockers, P0-B data safety, P0-C wrong numbers | ~2 weeks | Now (P0-A first) |
| **P1** | Operation contract and failure visibility | P1-A operation handle, P1-B cancellation, P1-C surfaced failures | ~1.5 weeks | After P0-A |
| **P2** | Dead ends and option fidelity | P2-A persistence, P2-B routing, P2-C dead-end features, P2-D options and preflight | ~2 weeks | After P1-A |
| **P3** | Remaining scientific correctness | P3-A mapping and coverage, P3-B extraction and coordinates, P3-C translation and GFF, P3-D robustness, P3-E genotyping review | ~2 weeks | After P0-C; parallel with P2 in a second worktree |
| **P4** | Main-thread and actor performance | P4-A freezes, P4-B process runner, P4-C memory, P4-D rendering | ~1.5 weeks | After P1-B |
| **P5** | Deletion and hygiene | P5-A dead code, P5-B docs, P5-C decided removals | ~1 week, spread out | P5-A and P5-B any time after P0-A |
| **P6** | One path per action | P6-A CLI transport, P6-B argv as truth, P6-C shared run services, P6-D window context, P6-E import router | ~4–6 weeks | After P1 and P5-A |
| **P7** | Consistency and accessibility | P7-A shared table, P7-B responder and keyboard, P7-C vocabulary, P7-D accessibility, P7-E inspector rows | ~3 weeks | After P6-A; P7-C any time |
| **P8** | Release and dependency hardening | P8-A publish robustness, P8-B single version source, P8-C pinning, P8-D release slimming | ~2 weeks | P8-A after P0-A; others later |
| **P9** | Test-suite right-sizing | P9-A prune, P9-B high-value tests, P9-C hooks and flakiness | ongoing | After P0-A; P9-B alongside P2 and P3 |

Sizes assume an expert agent under Fable-level review, one package in flight per checkout.

## Part 3. Packages

### P0: Stop the bleeding

**P0-A. Trustworthy local gates and ship-blockers.** Closes REL-01, TST-01, TST-02, TST-03, TST-04, TST-05, TST-06, REL-02 (reframed), REL-09 (gate half), TST-12 (app-smoke half).
1. REL-01: scope `umask 077` to the secrets it protects, or normalise modes after archive (`chmod -R u+rwX,go+rX` on the app). Add a mode check to the release smoke script. Cut a preview and verify launch from a second macOS account. See [release-dependencies.md](release-dependencies.md) WP1.
2. TST-03 and TST-04: add a test resource helper that works under Swift Build. Make the app identity or home directory injectable in tests instead of hard-coding `.lungfish`. Fix the roughly 12 real drift failures the tests catch (`runModal`, committed `.superpowers/` scratch, README and Tools-menu drift, manifest drift) at their source, not by relaxing the tests. See [testing-ci.md](testing-ci.md).
3. TST-05: add per-test and overall timeouts to `full-suite-gate.sh`. Reproduce `CLIImportRunnerTests/testCancelTerminatesCLIProcessTree` in isolation. If `cancel()` really leaves a live child, open it as a product bug in P1-B.
4. TST-02 and D6:
   - `release.py` refuses to package unless a green unit tier result exists for the exact release commit. The existing `gate_evidence.py` parser already fails closed.
   - `appSmokeRequired: true` for both channels, and the smoke launches the packaged app.
   - `scripts/install-git-hooks.sh` runs from `setup-worktree.sh`, so the hook is always installed.
   - Optional: a nightly launchd job for the full, integration and real-tool tiers, writing results where `release.py` can read them.
5. TST-06 and REL-02: make `ci.yml` `workflow_dispatch`-only or delete it. No hosted checks.

Acceptance:
- the unit tier is green twice in a row at HEAD;
- a deliberately failing test makes `release.py package` exit non-zero;
- the smoke catches an app with 0700 modes;
- a push produces no failed workflow run.

**P0-B. Stop destroying user data.** Closes FEA-01, FEA-02, WFL-02, REC-02, WFL-01, SCI-08 (default behaviour), REC-01.
1. FEA-01: `BundleManifest` rewrites must round-trip every field. Remove or deprecate the convenience initialisers that drop tracks. Test that deleting variant rows on a bundle with BAM tracks keeps them.
2. FEA-02:
   - the duplicate check targets the real destination (`Imports/`);
   - `--force` is passed only after an explicit Replace;
   - Keep Both and sample-sheet names reach the CLI (new `--name`).

   Test that two imports of `S1_R1.fastq.gz` leave two bundles.
3. WFL-02 and REC-02: in `TreeCommand` and `MSACommand`, never delete the shared `.tmp`, only the operation's own staging directory. On refusal, delete nothing. With `--force`, publish to staging, then atomically replace. Read the process pipes before waiting for exit. Apply the rule to every `--force` site found by a search query (rule 2).
4. WFL-01 and SCI-08 (depends on D1): derived FASTQ outputs are never re-binned or re-trimmed on re-import. Clumping never silently falls back to Trim Galore. Quality binning follows D1, is named correctly ("illumina4" really keeps 7 levels) and is recorded in provenance. Originals are deleted only after a read-count check.
5. REC-01: move `VariantSampleMetadataMutationService` and `SequenceAnnotationTrackWorkflow` onto the existing `VariantMutationPublication` recovery path.

Acceptance: a fault-injection test for each path proves that previous data survives; the golden FASTQ bytes of an operation output are unchanged by re-import.

**P0-C. Stop reporting wrong numbers.** Closes PERF-04, SCI-01, SCI-02, SCI-03, SCI-04 ([scientific-integrity.md](scientific-integrity.md) package A, [concurrency-performance.md](concurrency-performance.md) WP1).
1. PERF-04:
   - add a streaming unique-read counter (position and strand key, no `maxReads` cap, no SAM buffering);
   - use it for TaxTriage and EsViritu;
   - bump the unique-reads cache version so persisted batch values are recomputed;
   - have the science reviewer sign off on the dedup key.
2. SCI-01 and SCI-02: the GFF exporter writes one line per CDS segment with the correct phase, through a shared `CDSSegmentPhases` helper in LungfishCore. The iVar TSV-to-VCF conversion removes duplicate records from overlapping CDS.
3. SCI-03: pass AF and depth thresholds to LoFreq, bcftools, Medaka and Clair3, or filter after calling. Provenance records only what was actually applied.
4. SCI-04: viral bcftools runs haploid (`--ploidy 1`) with a depth cap suited to amplicon data, set explicitly and recorded.

Acceptance:
- the SARS-CoV-2 fixture calls 14401 as L>P;
- no duplicate VCF records;
- the 4% LoFreq variant is filtered at AF 0.05;
- the 2000× synthetic case reports its true depth and a haploid GT;
- a synthetic contig with 250,000 unique reads reports 250,000.

Release note: variant and unique-read numbers change, and old results should be re-run.

### P1: Operation contract and failure visibility

**P1-A. An operation start that cannot be ignored.** Closes ARC-04 and FEA-07 (corrected). Also covers the ownership half of the prior ARCH-01 audit finding. See [architecture.md](architecture.md) WP2 and [features-data-viewers.md](features-data-viewers.md) WP-2.
- Replace `start(...) -> UUID` with `run(spec) throws -> OperationHandle`, or a refusal type the caller must switch on.
- Migrate every `targetBundleURL:` caller (rule 2). The seven known ignorers are annotation import, annotation drop, MSA export and four MSA/tree viewer actions.
- Acceptance: for each caller family, a test shows that the transport or subprocess is never invoked when the bundle is locked.

**P1-B. Cancellation and quit.** Closes PERF-13, WFL-12, FEA-06, PERF-11, plus TST-05 if it proves to be a product bug.
- Cancellation signals the whole process tree and waits for acknowledgement.
- Quit and window close warn when operations are running.
- Interrupted outputs are visible in Manage Project Storage.
- Process-tree termination avoids a `ps` call per PID.
- Build a shared cancellation harness with a fake tool that ignores SIGTERM, then assert that no child survives.

**P1-C. Failures the user can see.** Closes UX-02, UX-09, WFL-19.
- Add a `ResultExportCoordinator` in LungfishKit (see [consistency-ux.md](consistency-ux.md) WP1).
- Migrate the export paths in EsViritu, TaxTriage (3), NAO-MGS and NVD, then Kraken2 and 12S.
- Fix the silent 12S load failure and the raw enum error text.

### P2: Dead ends and option fidelity

Each GUI package starts and ends with a Computer Use walkthrough (rule 6).

**P2-A. Edits that persist.** Closes FEA-03, UX-01, REC-05, FEA-05, FEA-10 (the max-undo part).
- Route viewer and Inspector annotation delete and edit through the drawer's persistent deletion coordinator, using the P1-A handle.
- Import every BAM or VCF in a multi-file import, queued if necessary, with honest Import Center status.
- Either wire or remove the "Max undo levels" and "Default zoom window" settings.

**P2-B. Result routing from metadata.** Closes WFL-05, WFL-06, part of WFL-20.
- Route by `analysis-metadata.json`, not by folder-name prefix.
- Put pbAA output in a visible analysis folder, and route Savont batches.
- Add a table-driven routing test over fixture projects.

**P2-C. Remove or finish dead-end features.** Closes WFL-03 (D4), WFL-07, WFL-14 (D5), WFL-15 (the CZ ID part), UX-08, FEA-08, FEA-13, WFL-16 (gating).
- Add controls for alignment sort and colour modes, since they are already implemented and tested.
- Variant table: make the Het Only chip work or remove it. Load Match Any presets faithfully.
- Hide or finish user-registered workflows and GATK phasing, following D4.

**P2-D. Options reach the tools, and dependencies are checked up front.** Closes WFL-10, WFL-08, WFL-04, WFL-13, WFL-09, SCI-16 (if it reproduces).
- For every wizard option, a fixture test proves that the option changes the tool's argv or its output:
  - EsViritu minimum length;
  - TaxTriage classifiers;
  - demux options;
  - subsample and IQ-TREE seeds.
- Map BAM primer-trim contigs to the BAM's `@SQ` names.
- Viral Recon caller overrides produce results or fail loudly.
- Add a shared `WorkflowDependencyPreflight` with an install path, used by every wizard. See [features-workflows.md](features-workflows.md) WP4 and WP5.

### P3: Remaining scientific correctness

This phase can run in a second worktree in parallel with P2, because it mostly touches LungfishIO, LungfishCore and LungfishWorkflow.

- **P3-A. Mapping and coverage statistics.** Closes SCI-05, SCI-09, SCI-17. Count primary reads, not alignment records. Record the true reference length for NAO-MGS, or label coverage as unavailable. The markdup pipeline gets `pipefail`, correct quoting, and duplicate fraction computed over reads. Consider a "recompute statistics" action for existing bundles.
- **P3-B. Extraction orientation and coordinates.** Closes SCI-06, SCI-07, SCI-13, SCI-15, SCI-21, FEA-09.
  - Make annotation extraction strand- and splice-aware.
  - Mirror and complement variants when a region is reverse-complemented.
  - Add one `GenomicRegion.displayString` (1-based, closed) used everywhere.
  - Add one `LocusQueryParser` that accepts what the ruler displays.
- **P3-C. Translation and GFF export.** Closes SCI-10, SCI-11. Honour `/codon_start`, GFF phase and `/transl_table`. Write correct phase and `Parent` links on export. Depends on the P0-C helper.
- **P3-D. Robustness.** Closes SCI-12, SCI-14, SCI-19, SCI-20, SIMP-07. Handle CRLF in the bgzip FASTA reader. Replace length-based chromosome matching with the existing `ChromosomeAliasResolver`, and surface any aliasing to the user. Remove `--fasta-input`. Fix IUPAC handling in assembly statistics, which also closes the prior audit's DATA-07 criterion.
- **P3-E. Genotyping scientific review (D7).** A focused review of `ONTGenotyping`, which is about 24% of recent churn and unreviewed by either audit. Its output is a findings report, not code.

### P4: Main-thread and actor performance

See [concurrency-performance.md](concurrency-performance.md) WP2 to WP9.

- **P4-A. Freezes.** Closes PERF-01, PERF-05, PERF-07, ARC-13, PERF-03. Hash off the main actor, cached by size and mtime. Use the existing async sidebar scan at all eight call sites. Move TaxTriage discovery and samtools off main, reading stderr and stdout concurrently.
- **P4-B. Process runner.** Closes PERF-02, PERF-12, PERF-14. Add one async `ToolProcess` utility so that `NativeToolRunner.shared` never blocks during a child's lifetime. Fold in the racy drain idioms. This is the foundation for P6-A and ARC-15.
- **P4-C. Memory.** Closes PERF-06, PERF-08, PERF-15. Stream GFF3 export without loading the genome. Stream orient maps. Put a bound on operation logs.
- **P4-D. Rendering.** Closes PERF-09, PERF-10, UX-16. Redraw only the loading badge, throttle panning, cache MSA glyph runs, fix the gutter width bug and the dark-mode fills. Confirm each change visually.

### P5: Deletion and hygiene (low risk, parallelisable)

- **P5-A. Verified dead code.** Closes SIMP-05 (rows cleared in [simplification.md](simplification.md) WP-A), ARC-08, ARC-14, ARC-16 (dead notifications), WFL-21, FEA-15, UX-13 (dead wizards), REL-15, REL-16, PERF-16 (the `runModal` part).
  - About 5K production and 2.5K test lines.
  - Check the report's "looks dead but is used" list before deleting anything.
  - Rewrite the source-text tests that break, as behavioural tests or ratchet-script rules (rule 4).
  - Update `features.yaml` (FEA-16) in the same change.
- **P5-B. Docs per [docs-strategy.md](docs-strategy.md).** Closes SIMP-08, SIMP-09, SIMP-14, SIMP-15.
  1. Delete the unreferenced `.source.png` files and duplicate illustrations.
  2. Move test-read fixtures to `Tests/Fixtures`.
  3. Delete finished plans, specs, reviews and archives.
  4. Create the media repo and `media.lock`, pinned per release.
  5. Add a local pre-commit size guard.
  6. Move one-off research scripts out of `scripts/`.

  Needs no Swift builds except step 2, so it can run beside any Swift package.
- **P5-D. Small shared helpers.** Closes SIMP-10, SIMP-12, SIMP-16. One `FileDigest` and one `DelimitedText` escaper in LungfishCore replace the 49 SHA-256 helpers and 15 CSV/TSV escapers. Remove the duplicate container-runtime factory and the unused Docker fallback. Move the Python embedded in Swift string literals into resource files.
- **P5-C. Decided removals.**
  - SIMP-02: workbook-transaction recovery code, following D2.
  - SIMP-03: PrimalScheme research modes, following D3. Verify the lge.5 contract-version suspicion first.
  - SIMP-06: `SequencingPlatform` and `AlignmentFilter` name collisions. Use a codable migration so saved values stay readable.

### P6: One path per action (the structural core)

This phase gives the most lasting value and carries the most risk. Do one family per PR, each with a GUI walkthrough.

- **P6-A. One CLI event schema and one transport.** Closes ARC-02, SIMP-04, SIMP-13 (tree runners). Add typed `CLIEvent` values in LungfishWorkflow and one `CLISubprocessTransport` on P4-B's `ToolProcess`, bridged to the P1-A handle. Start with the two near-identical tree runners.
- **P6-B. Argv as the source of truth.** Closes ARC-03, ARC-09, SIMP-01, WFL-11, FEA-12, REC-03, part of ARC-07.
  - A typed request builds a `CLIInvocation`. The same value is executed, displayed as "Copy CLI command", and written to provenance.
  - Add a test that parses every displayed command back through the CLI's ArgumentParser.
  - Remove the internal `--*-import-helper` strings from user-visible commands.
- **P6-C. Shared run services, GUI to CLI.** Closes ARC-01, ARC-07, WFL-17, WFL-18, ARC-10 (partly).
  - Lift orchestration and provenance into LungfishWorkflow run services (classification first, then EsViritu, TaxTriage, mapping, assembly, orient, demux).
  - The GUI invokes them through the CLI transport. Each migration deletes the matching `AppDelegate+*` orchestration.
- **P6-D. Window context.** Closes ARC-05, ARC-06, FEA-11. Add a `WindowContext` owned by `MainWindowController`, a scoped event bus that fails closed, and remove the `DocumentManager.shared` mirror readers and the `mainWindowController` fallbacks.
- **P6-E. Import router.** Closes FEA-04, FEA-14, WFL-20, REC-04. One `GenomicsImportRouter` and one `ProjectLayout` decide what a file is and where it goes, whatever the entry point. Add a target-bundle chooser for BAM and VCF. This is a behaviour change, so it needs a release note.
- **Later (only after P6-C and P6-D):**
  - ARC-10: `AppDelegate` decomposition;
  - ARC-12 and ARC-11: `GenotypeResultViewController` split with hook migration, scheduled between genotype releases;
  - ARC-15: the remaining `Process()` sites moved onto `ToolProcess`.

### P7: Consistency and accessibility

See [consistency-ux.md](consistency-ux.md) WP3 to WP8.

- **P7-A. Converge on the shared table.** Closes UX-05, UX-06, UX-10, UX-14, UX-18. Order:
  1. extract `ColumnHeaderFilterMenu`;
  2. move NAO-MGS to `BatchTableView`;
  3. give the Kraken2 and viral outline tables the shared menu and typography;
  4. add `TableColumnStateStore`;
  5. add empty and no-match states.
- **P7-B. Responder and keyboard contract.** Closes UX-03 (reproduce first), UX-04, FEA-17, UX-17. Implement `copy:` and Find in data views, move controller shortcuts to menu items, and resolve the ⌘0 collision.
- **P7-C. Vocabulary.** Closes UX-07, UX-15. One canonical label set for BLAST, NCBI lookup, Copy TaxID and Extract. Sweep alert copy and ellipses. Update the manual and screenshots together.
- **P7-D. Accessibility.** Closes UX-11. Make the sequence viewer and track headers readable by VoiceOver, using the MSA and tree viewers as the model. Cap the number of child elements.
- **P7-E. Inspector rows.** Closes UX-12. One key/value row component.

### P8: Release and dependency hardening

See [release-dependencies.md](release-dependencies.md) WP2 to WP7.

- **P8-A. Licensing and publish robustness (do early).** Closes REL-03, REL-04, REL-05, REL-14.
  - Generate THIRD-PARTY-NOTICES from what is actually bundled, bundle it in the app, and include the kernel's GPL notice and source offer.
  - Add a `release.py yank` command and a forward-fix runbook.
  - Give the DMG upload its own time budget and a draft-then-publish flow.
  - Remove the stale "Stable triggers CI" claim.
- **P8-B. Single version source.** Closes REL-06, REL-07. `AppVersion.swift` is the only hand-edited site, via `bump-version.py`. Take the app version out of the hashed dependency manifest. Move the Sparkle build number off `rev-list --count`, which is also a precondition for any future history slimming.
- **P8-C. Pinning.** Closes REL-11, REL-12, REL-13. Add explicit conda locks, database digests, a viralrecon commit SHA and the EuPathDB rename. Pin `pages.yml` actions by SHA (a deploy, not CI, so it is outside the local-only rule).
- **P8-D. Release slimming, in slices, each ending with a real preview.** Closes REL-09 (machinery half), REL-10, REL-17, REL-08. Build from a clean worktree export. Adopt single notarization and delta updates. Remove cache fingerprinting and fork configuration if unused. Retire the legacy alpha bridge after a VM test.

### P9: Test-suite right-sizing

- **P9-A. Prune.** Closes TST-07, TST-08, TST-14, SIMP-11 (the tests half).
  - Replace the roughly 300 source-text tests with behavioural tests, or with ratchet rules in a lint script.
  - Delete tautologies and the 44 `testCommandName` / `testHelpTextIsNonEmpty` stubs.
  - Record the before and after test counts and unit-tier runtime.
- **P9-B. Add high-value tests.** Runs alongside P2 and P3.
  - Parser fuzzing for FASTA, FASTQ, VCF, GFF and SAM.
  - Scientific golden outputs that need no conda.
  - The shared cancellation harness from P1-B.
  - Three XCUI journeys (import to view, classify to open results, VCF to table), run by the release app-smoke gate.
- **P9-C. Hooks and flakiness.** Closes TST-09, TST-10, TST-11, TST-13, ARC-11. Move test hooks behind `#if DEBUG` or into test-support types. Replace wall-clock budgets. Make tool-gated tests honour `LUNGFISH_REQUIRE_TOOLS`. Bring warnings to zero in Sources.

## Part 4. Dependency graph (critical path)

```
P0-A ─┬─> P1-A ─> P2-A, P2-C ─────────────┐
      │     └──> P6-A ─> P6-B ─> P6-C     │
      ├─> P1-B ─> P4-B ─> P6-A            ├─> P7-A/B
      ├─> P0-B (parallel with P0-C)       │
      ├─> P0-C ─> P3-* (second worktree)  │
      ├─> P5-A, P5-B (any time)           │
      └─> P8-A (any time) ─> P8-B ─> P8-C/D
P1-A + P5-A ─> P6-D, P6-E
```

P0-A comes first, because every later package relies on a green, fail-closed gate to prove it did not break anything.

## Part 5. Explicitly not doing

Both reviewers and owner decisions converged on leaving these alone:

- **No UI framework migration, no rewrite of the module graph, no scientific algorithm rewrite.**
- **No window restoration, and no Save or Save As.** The write-through project model with "About Saving…" is coherent once P2-A makes it true.
- **Kept deliberately:**
  - Workflow singletons for genuinely process-wide registries;
  - the CLI's `print` output;
  - cohesive large files, which are not findings on size alone;
  - the single-conformer protocols that serve as test seams;
  - the distinct Preview bundle ID;
  - commit-count build numbers until P8-B;
  - the bundled Containerization kernel (only its notice is missing);
  - `liveSnapshot` labels for rolling databases;
  - the deliberate consensus policies;
  - the Bracken 150 bp distribution (SCI-18: document it and warn on short reads, don't engineer around it).
- **No hosted CI,** and no git history rewrite for now.
- **SIMP-17 (project-storage cleanup, 9.3K source and 15.7K test lines) is not scheduled.** It is Suspected overengineering and needs a design review before anything is removed. Revisit after P6.

## Part 6. Exit criteria for the whole programme

- Every P0 and P1 finding is closed in `ledger.md` with commit and verification evidence, or accepted with a written reason.
- The unit tier is green at every release commit. The app-smoke and file-mode checks pass on the packaged DMG. The nightly full tier has been green for 7 consecutive nights.
- The 15 GUI journeys pass a Computer Use walkthrough on the release candidate.
- Ratchet counts, recorded before and after, have only gone down:
  - unchecked `targetBundleURL:` callers;
  - raw `Process()` sites;
  - source-text tests;
  - production test hooks;
  - dead-code line count;
  - `docs/` size.
- A fresh reviewer who did not implement the work re-audits the P0 and P1 areas at the final commit.
