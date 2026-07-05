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
- 2026-07-04 follow-up: BLAST gzip extraction retry backoff now uses cancellation-aware
  `Task.sleep` instead of blocking the `BlastService` actor with `Thread.sleep`.
- 2026-07-04 follow-up: SRA runinfo CSV parsing is centralized across `SRAService` and
  `NCBIService`, keeping quote handling and date-only release-date parsing consistent.
- 2026-07-04 follow-up: ENA `first_public` date decoders now use POSIX locale consistently
  with Pathoplexus while preserving their existing date-only timezone semantics.
- 2026-07-04 follow-up: `TaxTriagePipeline` now fails closed when result metadata or
  run provenance sidecars cannot be saved, preventing successful scientific workflow returns
  without durable reproducibility metadata.
- 2026-07-04 follow-up: `ProjectStore.reconstructSequence` now rejects version indexes past
  the available history instead of silently clamping to the latest sequence content.
- 2026-07-04 follow-up: Legacy FASTQ batch import now fails closed on unsupported recipe
  steps instead of skipping them, and the stale `amplicon` import recipe advertisement was
  removed until primer removal is executable in that path.
- 2026-07-04 follow-up: Project lock acquisition now uses exclusive file creation so
  racing CLI lock attempts cannot both overwrite `project.lock`; stale/forced replacement
  uses a short-lived replacement guard and rechecks the original record before unlinking it.
- 2026-07-04 follow-up: `MiniPileupView` now lives in its own LungfishKit source file while
  `MiniBAMViewController.swift` retains the pinned `loadTask = Task.detached` loader literal.
- 2026-07-04 follow-up: metagenomics database actor singletons now use immutable `static let`
  storage, and tests use injected registry/manager instances instead of replacing global actors.
- 2026-07-04 follow-up: `ManagedStorageConfigStore.shared` is now public read-only API; tests
  use an explicit internal override when they need a temporary managed-storage home.
- 2026-07-04 follow-up: Sample metadata CSV/TSV import now rejects rows whose column count differs
  from the header before scanning or persisting metadata, avoiding silent misalignment in scientific
  import workflows.
- 2026-07-04 follow-up: TaxTriage's bottom action-bar BLAST Verify button is no longer a deceptive
  no-op; single-row selections now enable it and route through the same selected-row verification
  context used by row-level BLAST actions.
- 2026-07-04 follow-up: FASTQ bundle `metadata.csv` parsing now reads the quoted commas, escaped
  quotes, and embedded newlines that the serializer already writes, so per-bundle sample metadata
  round-trips without silently splitting records.
- 2026-07-04 follow-up: `ProcessManager` stdout/stderr streams now buffer partial pipe reads into
  logical lines, so line-oriented progress parsers and `runAndWait` output collection no longer see
  arbitrary chunk boundaries as separate lines.
- 2026-07-04 follow-up: `CLIVariantCallingRunner` now guards stdout/stderr buffering across
  asynchronous readability callbacks, waits for process exit without blocking the actor executor,
  and cancels the full native process tree while surfacing `CancellationError` for user-initiated
  cancellation.
- 2026-07-04 follow-up: `lungfish build-db` now writes canonical provenance for TaxTriage,
  EsViritu, and Kraken2 SQLite database builds, including replay argv, resolved options,
  checksummed source reports/retained inputs, final SQLite outputs, and retained relocated or
  compacted classifier payloads.
- 2026-07-04 follow-up: Core `ReferenceBundleBuilder` now dispatches bundle copy/index/manifest
  work to a non-main executor while keeping observable progress on the main actor. The Core
  fallback rejects provenance-bearing configurations, and CLI wrappers using fallback bundle
  creation now fail closed on final provenance write failures while excluding stale provenance
  sidecars from output records.
- 2026-07-04 follow-up: Managed database downloads now bridge Swift cancellation through a
  shared lock-backed URLSession task box, removing unsafe cross-isolation task references from
  the general and metagenomics database registries.
- 2026-07-04 follow-up: Standalone GUI FASTA sequence exports and phylogenetic subtree Newick
  exports now write canonical scientific file provenance sidecars and fail closed if sidecar
  creation fails, instead of producing ambiguous untracked deliverables.
- 2026-07-04 follow-up: Tools > FASTQ/FASTA Operations > Reverse Complement/Translate now route
  to dataset-operation dialogs instead of the active sequence viewer, while Sequence-menu
  visible-region transforms are disabled outside visible genomics content and the stale CLI
  reference wording was clarified.
- 2026-07-04 follow-up: Find Previous now keeps the standard `Cmd-Shift-G` shortcut, Go to Gene
  moved to non-conflicting `Cmd-Option-G`, the active shortcut manual was updated, and sequence
  navigation menu items now disable when their viewer/annotation prerequisites are absent.

## Still Deferred

- Large structural splits that require access-promotion choices or selector/protocol reachability
  review.
- Additional concurrency follow-ups only where a real forbidden notification/progress hop remains
  after the 2026-07-04 hardening pass.
- Public API removals without an owner decision or out-of-tree compatibility check.
- Scientific correctness or provenance behavior changes that still need native-tool integration
  or tests beyond this hardening pass.
