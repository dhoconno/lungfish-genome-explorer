# Continuation prompt — codebase-quality refactor

Paste the block below into a fresh Claude Code session (run from anywhere; it
points at the worktree explicitly) to resume the autonomous refactor.

---

Resume the autonomous codebase-quality refactor of the Lungfish genome explorer.

Worktree: /Users/dho/Documents/lungfish-worktrees/codebase-quality
Branch: worktree-fable-codebase-quality (off main). Work ONLY in this worktree.

Read first (in the worktree):
- docs/superpowers/specs/2026-07-03-codebase-quality-refactor-design.md
- docs/superpowers/plans/2026-07-03-codebase-quality-refactor.md
- docs/reports/2026-07-03-codebase-quality-results.md
- docs/reports/2026-07-03-codebase-quality-defer/*.md
Then `git log --oneline main..HEAD` to see exactly what has landed.

BINDING RULES:
- Behavior-preserving ONLY (no feature/behavior/API changes). Anything that
  changes a failure path, Codable schema, or is cross-file-risky => defer doc,
  do NOT apply.
- Per batch: expert audit -> apply (one implementer at a time) ->
  `swift build --package-path <this-worktree> --skip-update` then
  `swift test --package-path <this-worktree> --skip-update --filter <Module>Tests`
  -> INDEPENDENT adversarial review of the diff -> revert-on-uncertainty into the
  defer doc -> commit. Audits/reviews are read-only and may run in parallel;
  builds/implementers must be SERIALIZED (single .build lock — a concurrent build
  aborts with "input file was modified during the build").
- Green = 0 non-environmental XCTest failures AND swift-testing = 0. Clean
  baseline is 9558 XCTest / 487 swift-testing, 0 failures. Run the FULL suite at
  each MODULE boundary.
- NEVER introduce the literal `Task {` immediately followed by `@MainActor`, even
  in a comment (a source-scanning lint greps for it).
- Tiered batching: files >~800 lines get solo audit/apply/review; smaller files
  are clustered by directory/concern.

STATE AT HANDOFF:
- Baseline clean (fixed 2 pre-existing main bugs first).
- Phase 1 (LungfishCore) partially done: 21 files across 5 committed refactor
  batches. Tree clean, scoped LungfishCoreTests 1158/0. The Core-boundary FULL
  green-bar has NOT been run yet.

NEXT STEPS, in order:
1. FIRST: run the full green-bar suite once to confirm the 21-file Core work is
   green across ALL targets (not just scoped). If green, continue; if not,
   bisect to the offending batch and fix/revert.
2. Finish remaining LungfishCore files (NOT yet audited): remaining Models
   (Sequence, AlignedRead, SequenceAnnotation, GenomicDocument, TaxaCollection,
   SemanticColors, SequenceAppearance, VariantColorTheme, GenomicRegion,
   SelectionState, SequenceAlphabet, LungfishError, BundleAttachmentStore,
   HexColor, ClassifierSamplePickerState, AlignedReadDedup), Storage (ProjectFile,
   ProjectLock, KeychainSecretStorage, ManagedStorage*), Editing, Extraction,
   Capabilities, Genotype, Services/DatabaseService, Services/TempFileManager,
   Services/RuntimeResourceLocator, Services/OperationMarker,
   Services/SRA/SRAAccessionParser, Services/AI/AIProviderHelpers, remaining
   Bundles. Cluster by directory; same gate.
3. Dedicated MECHANICAL file-split pass for the big Core files (BundleManifest,
   NCBIService, BlastService) — pure git-mv/extension moves, one reviewed diff.
4. Phase-1 module-boundary FULL green-bar; update results table row for Core.
5. Proceed UP the dependency graph, one module per phase, same protocol, full
   green-bar per module: LungfishIO -> LungfishWorkflow -> LungfishKit -> the 9
   leaf UI modules -> LungfishApp -> LungfishCLI.
6. Finalize: final full green-bar, complete
   docs/reports/2026-07-03-codebase-quality-results.md, confirm clean tree, report
   the worktree is ready for the downstream LLM (whole diff = git diff
   main...worktree-fable-codebase-quality; per-module rationale in the defer docs).

Keep the defer docs rich — the deliverable is a clean, green, reviewable worktree
plus a precise punch list of everything intentionally NOT done and why.
