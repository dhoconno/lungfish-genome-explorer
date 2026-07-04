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
  separate rather than being deduped into a misleading shared map.

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
- Follow-up hardening implemented several previously deferred ambiguity reducers:
  ProjectStore transactions and negative-index guards, ProjectFile atomic metadata writes,
  fail-closed Core BCF/reference-bundle conversion stubs, fail-closed NativeBundleBuilder VCF
  conversion behavior, fail-closed NativeBundleBuilder non-BigWig signal handling, gzipped
  annotation metadata that no longer fabricates zero feature counts, Markdup and scrub-human
  explicit-vs-resolved provenance options, extract-contigs manifest-based bundle payload
  provenance, callback-hop cleanup in Kit/App, FASTQ stale UI-state cleanup, GATK `.auto`
  recursion removal, VariantDatabase no-op scaffold pruning, VCF parser hardening for invalid
  quality fields plus empty FORMAT/sample genotype fields, and GFF3/GTF parser hardening for
  invalid score/phase fields.
- 2026-07-04 follow-up: `ProcessManager.runAndWait` now propagates Swift task cancellation to the
  spawned native process tree and throws `CancellationError` after cancellation.
- 2026-07-04 follow-up: SRA Toolkit downloads now propagate cancellation into the active
  `prefetch`/`fasterq-dump` process and surface `CancellationError` instead of a generic toolkit
  failure.
- 2026-07-04 follow-up: NCBI genome/annotation/report HEAD probes now use the injected
  `HTTPClient`, keeping tests deterministic and preserving cancellation semantics for optional
  lookups.
- 2026-07-04 follow-up: ENA batch read lookup now rethrows cancellation from child tasks while
  preserving the intended per-accession failure tolerance for ordinary lookup failures.
- 2026-07-04 follow-up: Generic Pathoplexus search/fetch now fail closed when the caller omits
  an organism id, avoiding a misleading implicit `mpox` lookup at accession-only boundaries.
- 2026-07-04 follow-up: The Pathoplexus browser now starts with the default `mpox` organism
  visibly selected and no longer validates a nil organism as a hidden browse default.
- 2026-07-04 follow-up: BLAST URL API submissions now use strict
  `application/x-www-form-urlencoded` escaping so read IDs and extra parameters cannot inject
  additional form fields.
- 2026-07-04 follow-up: BLAST read extraction now fails closed on nonzero gzip exits instead of
  accepting partial FASTQ/Kraken output as successful verification input.
- 2026-07-04 follow-up: Sample metadata CSV/TSV import now rejects rows whose column count differs
  from the header before scanning or persisting metadata, avoiding silent misalignment in scientific
  import workflows.

## Still Deferred

- Large structural splits that require access-promotion choices or selector/protocol reachability
  review.
- Additional concurrency follow-ups only where a real forbidden notification/progress hop remains
  after the 2026-07-04 hardening pass.
- Public API removals without an owner decision or out-of-tree compatibility check.
- Scientific correctness or provenance behavior changes that still need native-tool integration
  or tests beyond this hardening pass.
