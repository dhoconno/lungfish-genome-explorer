# Batch Results Grouping — Results

**Date:** 2026-08-09 · **Branch:** `worktree-batch-results-grouping` (13 commits over `main`/2108e5f6) · **Status:** merge-ready, green bar verified.

Spec: `docs/superpowers/specs/2026-08-09-batch-results-grouping-design.md`. Plan: `docs/superpowers/plans/2026-08-09-batch-results-grouping.md`.

## What shipped

Multi-dataset tool runs now write ONE `Analyses/<tool>-batch-<timestamp>/` folder containing per-sample results named by source bundle, matching the existing classification-batch convention, on every fan-out surface. Previously each child produced its own sibling `<tool>-<timestamp>/` folder at the Analyses root (the SPAdes symptom the user reported).

- **BG1** — Shared helpers in `AnalysesFolder` (LungfishIO): `batchSampleDirectory(named:in:)` (sanitize + `-2`/`-3` dedup, creates dir), `batchSampleFileURL(named:extension:in:)` (flat-file variant, no create), and — hoisted in BG4 — `removeBatchDirectoryIfEffectivelyEmpty(_:)` (one-level-deep emptiness check). Sanitizer replicates `MetagenomicsSampleGrouper.sanitizeSampleId` verbatim.
- **BG2** — Classification/EsViritu batches refactored onto the shared helper (behavior-preserving; failure-path semantics restored after review).
- **BG3** — Mapping fan-out: one batch dir, per-child dirs precomputed in request order, empty-batch cleanup with the one-level-deep check (added after a review caught pre-created empty dirs defeating a shallow check).
- **BG4** — Assembly fan-out: same, with the folder/projectName suffix-agreement invariant; teardown-safe cleanup (`break` not `return` on weak-self guard, caught in review).
- **BG5** — Savont `.perInput`: one batch dir of bundle-named `.fasta` files, children stay concurrent, a completion barrier gates only the cleanup (teardown-safe, captures no self).
- **BG6** — Sidebar renders the generic batch groups (previously dead code) as expandable groups, including Savont's flat-file children.

pbaa confirmed out of scope (no multi-bundle path exists). Classification single-run flat layout, MAFFT/ONT/12S fixed-name folders, and result migration explicitly non-goals.

## Verification

Every task passed an independent reviewer (Sonnet; Opus for the final whole-branch review). 4 tasks required one fix round each — all converged. Reviewer catches that mattered: BG2 failure-path regression, BG3 empty-dir-defeats-cleanup, BG4 teardown cleanup-skip. Final whole-branch review (Opus): READY-FOR-MERGE, no blockers. Final full suite: **12,701 XCTest + 563 swift-testing, 0 failures**, 33 environmental skips.

## Deferred (safely, per final review)

Non-blocking: mapping op-title suffix not deduped (cosmetic; spec §3 invariant does not bind mapping); cleanup-gating asymmetry (mapping gates on `!anySucceeded`, assembly/savont unconditional — equivalent, readability only); `claimedNames` duplicates `batchSampleFileURL`'s suffix format in the Savont precompute (fold into a `reservedNames:` helper param if a 3rd caller appears); `savont` absent from `AnalysesFolder.knownTools` (sidecar-recognized, pre-existing); flat-file child `sampleId` retains extension vs directory children's bare name (pre-existing asymmetry, Savont sampleId consumers untouched); minor report/test-count typos in task reports.

## Separate item found during this work (NOT part of this branch)

A minimap2 reference-viewer regression was root-caused during this session: mapping viewer bundles symlink their `genome/` dir out to the source bundle, and a 2026-07-05 validator hardening (`e5a01250`) now rejects the resolved-outside-the-bundle target — breaking reference display for all minimap2 bundles. Fix is validator-side and tracked separately (handoff prompt prepared for the user).
