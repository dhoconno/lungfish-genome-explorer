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
- Fixed the targeted Kit/App callback hops without introducing the forbidden
  progress/notification `Task { @MainActor }` pattern.
- Removed stale FASTQ sidebar accordion state and made Custom Fields visibility explicit.
- Added Core storage hardening: atomic metadata writes, ProjectStore transactions,
  unsupported-bind errors, negative-version rejection, and structured `queryError`
  failures for corrupted ProjectStore row identifiers/payloads.
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

## Verification

- Add source/behavior tests before or alongside each targeted fix.
- Run focused affected tests.
- Run `swift build --skip-update`.
- Run practical affected module test filters.
- Run `git diff --check` before committing.
