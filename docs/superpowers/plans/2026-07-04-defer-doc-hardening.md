# 2026-07-04 Defer/Doc Hardening Plan

## Objective

Clean up stale and misleading codebase-quality defer inventory, then implement maintainability
changes that reduce future ambiguity across the codebase.

## Scope

1. Remove or relabel stale defer-doc entries that describe already-applied work as pending.
2. Clarify deceptive source constructs that encode intentional behavior in confusing ways.
3. Fix hard deferred issues with focused regression coverage:
   - scientific provenance option correctness,
   - forbidden callback/progress `Task { @MainActor }` hops where the defer docs already
     identified them as violations,
   - `VariantColorTheme(name:)` not preserving the caller-provided name,
   - non-atomic project metadata writes,
   - ProjectStore partial-write durability and negative-index traps,
   - Core scientific-output stubs that fabricated BCF/CSI/bgzip/BigWig/BigBed paths,
   - inert FASTQ operation sidebar expansion state,
   - embedded script/file splits where verification stays straightforward.
4. Keep larger scientific-output blockers explicit if native-tool integration cannot be safely
   completed in the same batch.
5. Run focused tests first, then build and broader module tests.
6. Commit the reviewed result.

## Completed Scope

- Implemented CLI provenance explicit/resolved option merging and Markdup regression coverage.
- Fixed `conda classify` provenance option separation so resolved database paths, detected
  formats, materialized execution inputs, and defaulted flags are no longer reported as
  explicit user options.
- Made executed `workflow run` fail closed unless at least one `--expected-output` is declared,
  and updated `run-headless` to forward workflow-run flags so CI can satisfy the same final-output
  provenance contract.
- Fixed the targeted Kit/App callback hops without introducing the forbidden
  progress/notification `Task { @MainActor }` pattern.
- Removed stale FASTQ sidebar accordion state and made Custom Fields visibility explicit.
- Added Core storage hardening: atomic metadata writes, ProjectStore transactions,
  unsupported-bind errors, negative-version rejection, and structured `queryError`
  failures for corrupted ProjectStore row identifiers/payloads.
- Hardened remaining ProjectStore read/mutation invariants: checkout rejects negative
  indexes and missing sequences before mutation, non-UTF-8 stored sequence payloads
  throw instead of decoding to empty content, and shared queries require terminal
  `SQLITE_DONE`.
- Made direct reference-bundle annotation imports fail closed on zero-feature inputs:
  empty or malformed GFF3/BED files now throw before publishing a manifest entry, generated
  SQLite artifacts are removed, and successful import provenance records zero-feature
  rejection as enabled.
- Aligned NCBI and ENA batch fetch streams with Pathoplexus cancellation semantics
  so abandoned consumers cancel the producer task before it continues issuing
  network requests.
- Made Core bundle/variant conversion stubs fail closed rather than writing misleading
  scientific outputs.
- Made NativeBundleBuilder fail closed on unavailable/failed VCF-to-BCF conversion instead of
  copying VCFs and writing empty CSI placeholders.
- Made NativeBundleBuilder fail closed for non-BigWig signal inputs until bedGraph-to-BigWig
  conversion has complete native-tool provenance.
- Avoided fabricated Core gzipped-annotation metadata by leaving compressed feature counts unknown
  when the Core fallback builder cannot inspect the payload.
- Updated extract-contigs bundle provenance coverage to use the manifest's actual genome payload
  path, including the Core builder's uncompressed FASTA fallback.
- Removed stale/deceptive docs: obsolete continuation handoff, no-deferral baseline note,
  superseded queued IO notes, and deferred bullets for items now implemented.
- Removed the remaining BLAST gzip retry `Thread.sleep` in favor of cooperative cancellation-aware
  retry backoff, and updated the stale defer entry that still listed it as pending.
- Centralized SRA runinfo CSV parsing across the direct SRA service and the NCBI service, including
  consistent quote handling and timestamp/date-only release-date parsing.
- Made ENA `first_public` date parsing POSIX-locale-stable in both ENA search and read-record
  decoders without changing their date-only timezone semantics.
- Made `TaxTriagePipeline` fail closed when result metadata or run provenance sidecars cannot be
  saved, with source-policy and fake-runtime coverage.
- Made `ProjectStore.reconstructSequence` reject version indexes past available history instead
  of returning latest content for nonexistent historical requests.
- Made legacy FASTQ batch import fail closed on unsupported recipe steps and removed the stale
  `amplicon` recipe advertisement from the import CLI/manual until primer removal is executable
  in that path.
- Made project lock acquisition use exclusive file creation so racing CLI lock attempts cannot
  both overwrite the same lock file.
- Made corrupted project lock metadata a typed Core read result, with CLI lock/unlock failing
  closed by default and App read-only warnings distinguishing corrupted lock files from generic
  read errors.
- Moved Core reference-bundle file work behind a non-main executor while keeping
  the observable builder as the main-actor progress adapter; the Core fallback now rejects
  provenance-bearing configurations instead of silently ignoring them.
- Hardened Core-fallback reference bundle CLI wrappers: `extract contigs --bundle` and
  `bundle create` remove created bundles if final provenance cannot be written, and their
  output records exclude stale provenance sidecars while including final bundle payloads.
- Extracted `ONTBarcodeDemuxGenotypingPipeline`'s embedded Python payloads into a dedicated
  scripts extension while preserving the public script-writer APIs and byte-identical script
  contents.
- Split `ONTDirectoryImporter`'s public header parser and import model declarations into
  dedicated files while leaving scan/import/gzip behavior unchanged.
- Moved the VCF `createFromVCF` pipeline out of `VariantDatabase+Bookmarks.swift` into
  `VariantDatabase+CreateFromVCF.swift`, leaving bookmark CRUD in the bookmark extension.
- Removed stale defer wording that still listed `TwelveSAmpliconResultBundle`'s
  models-vs-IO split as pending after the split had already landed.
- Split `MiniPileupView` out of `MiniBAMViewController.swift` into a dedicated LungfishKit
  renderer file while preserving the pinned `loadTask = Task.detached` source-string location.
- Replaced mutable `nonisolated(unsafe)` metagenomics database actor singletons with immutable
  `static let` singletons and moved root-change coverage to injected test instances.
- Narrowed `ManagedStorageConfigStore.shared` from publicly replaceable global state to public
  read-only API with an explicit internal test override for temporary-home isolation.
- Deduplicated genotype haplotype leading-run-number token stripping behind one internal
  helper, with public matcher/locus coverage for numeric-prefix normalization.
- Collapsed `NvdDatabase`'s duplicated read-side migration blocks and repeated BLAST-hit
  SELECT projection, with legacy-schema coverage for the post-release columns.
- Moved `AlignmentDataProvider` samtools process waits off the caller executor by delegating
  the blocking process lifecycle to a detached worker, with behavioral fake-samtools coverage.
- Extracted BlastService gzip decompression process setup into one helper while keeping Kraken
  byte residual parsing, FASTQ string residual parsing, retry behavior, and failure mapping
  separate and covered.
- Narrowed `ProjectStore` metadata and WAL-checkpoint maintenance APIs to internal after
  cross-module grep confirmed no production caller outside LungfishCore.
- Removed `FASTQMetadataDrawerView`'s dead no-op table-selection delegate stub and its
  never-written suppression flag after verifying selection changes had no implemented behavior.
- Removed the unused standalone `TaxTriageConfidenceView` chart, kept the live compact
  confidence cell with tested shared TASS thresholds, and corrected stale manual/review docs that
  described the removed chart as the result viewport.
- Made DemultiplexingPipeline fail closed when required derived FASTQ manifests cannot be written:
  affected demux bundles are removed and the run throws instead of returning lineage-less bundles.
- Made EsViritu result sidecar persistence fail closed and recorded the required JSON sidecar
  as a Lungfish wrapper provenance step after final output files exist.
- Made classification result sidecars required inside `ClassificationPipeline`, with a Lungfish
  wrapper provenance step, rollback if final provenance cannot be saved, and App cleanup for
  project-owned analysis directories that fail before durable result metadata exists.
- Made GUI-triggered Kraken2 batch database builds pass explicit successful sample directories
  to `build-db kraken2`, with replay argv/provenance options recording that success set so stale
  sibling result directories cannot contaminate `kraken2.sqlite`.
- Made Kraken2 lazy database rebuilds use the batch manifest's successful sample directories,
  reject empty success manifests, and avoid unfiltered GUI rebuilds for manifest-bearing batches.
- Made project `Analyses/` directory creation use exclusive timestamp allocation with deterministic
  suffixes, preventing failed-run cleanup from deleting another run that started in the same second.
- Added failed Lungfish result-sidecar provenance steps for Classification and EsViritu when their
  required JSON sidecars cannot be written.
- Made `lungfish project migrate` stage rewritten manifest bytes, write migration provenance for
  the final manifest checksum, and only then atomically publish `manifest.json`.
- Made GUI FASTQ direct-output imports remove newly-created final `.lungfishfastq` bundles when
  CLI provenance rehydration fails.
- Made analysis manifest appends fail closed on corrupt existing manifests, and made legacy
  analysis migration roll back moved directories if bundle manifest recording fails.
- Made `variants extract-sample` and `variants query` stage exported VCFs, write provenance for
  the final output checksum, and only then publish the VCF.
- Made completed managed GATK executions remove newly-created declared outputs if final
  provenance persistence fails.
- Replaced Plugin Manager storage/progress callback-context `Task { @MainActor }` hops with
  the established main-queue `MainActor.assumeIsolated` bridge, and source-guarded the pattern.
- Replaced stale `MainSplitViewController+*.swift` split-extension headers with file-specific
  responsibilities and source-guarded against the monolithic header returning.
- Removed stale user-manual migration guidance that told users to copy provenance by hand;
  the manual now explains current migration provenance and manifest-backup behavior.
- Updated the technical-gap issue ledger so shipped project lock and CLI migration work is
  marked resolved/partial instead of remaining indistinguishable from unimplemented gaps.
- Made newly constructed canonical `ProvenanceRuntimeIdentity` values include the current
  OS user by default, closing the remaining new-sidecar user-attribution gap while preserving
  decode compatibility for historical sidecars that lack a user field.
- Retired the stale GenotypeOutline `handleClick` follow-up after verifying the materialized
  row-recognizer test covers the current identifier-bearing click target, and marked the July 2
  GUI performance plan/audit as historical rather than an active unchecked backlog.
- Wired `AssemblyContigDetailPane` quick-copy fields to the controller's injected pasteboard so
  detail metrics behave consistently with summary-strip and contig-table scalar copy actions.
- Added provenance-publication rollback snapshots for plain metadata payloads: GUI sample
  metadata imports, `lungfish import metadata`, `lungfish metadata set`, and
  `lungfish metadata import --sync-bundles` now restore or remove metadata files if root,
  file, or bundle provenance publication fails.
- Made standalone MSA file outputs fail closed: `lungfish msa export`, `consensus`
  FASTA, `extract` FASTA, and `distance` matrix outputs are restored or removed if
  their provenance sidecar cannot be published.

## Verification

- Add source/behavior tests before or alongside each targeted fix.
- Run focused affected tests.
- Run `swift build --skip-update`.
- Run practical affected module test filters.
- Run `git diff --check` before committing.
