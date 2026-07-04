# Codebase-Quality Expert Review Addendum

Date: 2026-07-04
Branch: `worktree-fable-codebase-quality`
Review base: `origin/main` @ 56e3a21d

Five expert review teams inspected the branch by module/commit slice: Core+IO, Workflow
provenance, Kit+UI+App, CLI provenance, and release/docs. The review agreed with the main
direction of the refactor: mechanical file splits, dead private-code removals, local deduplication,
and behavior-preserving simplifications are useful and appropriate.

## Changes Kept

- Core, IO, Workflow, Kit, leaf UI, App, and CLI mechanical splits and grep-verified dead-code
  removals remain in place.
- Deferred large file splits remain deferred unless they were already landed in the branch.
- Public command/GUI surfaces that are user-facing remain protected from caller-count-only removal.
- Provenance-sensitive helper pairs such as Markdup explicit-vs-resolved option builders remain
  deferred rather than deduped.

## Corrections Applied

- Restored public API in Core: `BlastService.submit`, `BlastService.checkStatus`,
  `BlastService.getResults`, `SequenceDiff.computeDetailed(from:to:)`, and
  `Version.computeHash(_:)`.
- Restored public API in IO: `MultipleSequenceAlignmentBundle.ColumnStat` and
  `FormatRegistryError`.
- Fixed taxonomy extraction provenance so saved sidecars record actual `.fastq.gz` outputs,
  checksums, sizes, current Lungfish version, resolved options, and replay argv.
- Removed dead CLI leftovers: `FastqCommand.writeWorkflowRun` and the discarded quality-trim
  wall-time local.
- Removed the trailing blank line at EOF in `NaoMgsResultViewController.swift`.
- Updated stale results/defer docs that still said items were pending, in progress, or clean when
  the final reviewed state was more nuanced.

## Still Deferred

- Large structural splits that require access-promotion choices or selector/protocol reachability
  review.
- Pre-existing concurrency follow-ups such as `Task { @MainActor }` from notification/progress
  contexts.
- Public API removals without an owner decision or out-of-tree compatibility check.
- Scientific correctness or provenance behavior changes that need dedicated tests beyond a
  simplification refactor.
