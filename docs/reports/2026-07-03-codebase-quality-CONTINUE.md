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
- Phase 1 (LungfishCore) COMPLETE: all ~70 files audited (7 big-file solos +
  wave-2/3 directory clusters), every safe behavior-preserving finding applied
  across 7 committed batches, and the 3 largest files split into focused files.
  A full green-bar was verified mid-Core at 9558/487, 0 failures; a FINAL
  Core-boundary full green-bar was run after the split (check
  docs/reports/2026-07-03-codebase-quality-results.md Core row for its result —
  if it shows GREEN, Core is certified; if the run had not finished at handoff,
  RE-RUN the full suite first before starting IO).
- Tree clean. `git log --oneline main..HEAD` shows the batch history.

NEXT STEPS, in order:
1. FIRST: confirm the final Core-boundary full green-bar was GREEN (see results
   doc). If not recorded/green, run `swift test --package-path <wt> --skip-update`
   and confirm 0 non-environmental failures before proceeding.
2. Phase 2 = LungfishIO (139 files, ~66K LOC). Same per-batch protocol, tiered.
   Big files (>~1000 lines) solo, rest clustered by directory. Big files, largest
   first: Formats/NaoMgs/NaoMgsDatabase.swift (2620),
   Search/ProjectUniversalSearchIndex.swift (2483),
   Bundles/GenotypeHaplotypeAnalysis.swift (1966),
   Bundles/MultipleSequenceAlignmentBundle.swift (1940),
   Bundles/PhylogeneticTreeBundle.swift (1808), Bundles/AnnotationDatabase.swift
   (1718), Formats/FASTQ/FASTQDerivatives.swift (1672),
   Bundles/ONTGenotypeResultBundle.swift (1494), Formats/GenBank/GenBankReader.swift
   (1133), Formats/FASTQ/FASTQReader.swift (970), + the NaoMgs/TaxTriage/Nvd/EsViritu
   databases. Clusters: Bundles/ (47 files), Formats/FASTQ/ (34), the smaller format
   parsers (VCF/SAM/GFF/BED/FASTA/Kraken), Registry/, Services/, Search/.
   IO CAUTION: heavily correctness-sensitive format parsing. PRESERVE the bgzip
   `readUncompressedRange` infinite-loop fix (break when nextOffset <= current or
   findBlock returns nil) in both async and sync readers. NEVER save alignment as
   SAM. Defer parsing/coordinate/format-logic changes; apply only dedup/dead-code/
   clarity/access-control that is provably behavior-preserving. Defer doc: create
   docs/reports/2026-07-03-codebase-quality-defer/02-io.md. Full green-bar at the
   IO module boundary.
3. Then up the graph, one module per phase, same protocol, full green-bar per
   module: LungfishWorkflow (03-workflow.md — preserve OperationCenter
   update()+log(), materialization, no-SAM) -> LungfishKit (04-kit.md — no
   LungfishApp refs) -> the 9 leaf UI modules (05-leaves.md, one full green-bar
   after all leaves) -> LungfishApp (06-app.md — keep composition roots in App) ->
   LungfishCLI (07-cli.md — no LungfishKit import, CLI/GUI parity).
4. Finalize: final full green-bar, complete
   docs/reports/2026-07-03-codebase-quality-results.md, confirm clean tree, report
   the worktree is ready for the downstream LLM (whole diff = git diff
   main...worktree-fable-codebase-quality; per-module rationale in the defer docs).

REVIEW GOTCHA (learned this session): when dispatching an independent reviewer to
compare against "pristine originals", point it at the PRIOR COMMIT (HEAD~1) or use
`git diff HEAD`, NOT the sibling main worktree — main is pre-refactor and will make
the reviewer attribute earlier already-committed batches to the current diff.

Keep the defer docs rich — the deliverable is a clean, green, reviewable worktree
plus a precise punch list of everything intentionally NOT done and why.
