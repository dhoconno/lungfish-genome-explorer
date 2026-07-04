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
- Embedded script/file splits remained deferred because the reviewed same-batch wins were in
  provenance/output correctness rather than large mechanical relocation.

## Verification

- Add source/behavior tests before or alongside each targeted fix.
- Run focused affected tests.
- Run `swift build --skip-update`.
- Run practical affected module test filters.
- Run `git diff --check` before committing.
