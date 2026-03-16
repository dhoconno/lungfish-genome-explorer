## FASTQ/FASTA Stabilization And Validation Plan

Date: March 13, 2026
Branch context: `fastq-features`
Status: In progress

### Purpose

This plan resets the FASTQ/FASTA work to a simpler and more robust model:

- one demultiplexing operation at a time
- one primer-trimming operation at a time
- every derived result remains a child bundle of a parent real or virtual bundle
- trim-oriented operations stay virtual by storing sidecar evidence rather than rewriting sequence payloads unless materialization is explicitly required

The immediate goals are:

1. remove dormant code from the abandoned multi-step and structure-aware demultiplexing experiment
2. verify the current FASTQ/FASTA derivative model end to end with realistic simulated projects
3. lock in regression coverage for virtual bundle lineage, materialization, metadata, and parameter validation
4. identify and fix branch-level rough edges before any further feature expansion

### Scope

Included:

- FASTQ virtual derivative creation and materialization
- FASTA-compatible derivative behavior where supported
- FASTQ metadata drawer and FASTQ operation request building
- demultiplex, orient, subset, trim, primer trim, and FASTA reference picker paths
- simulated `.lungfishfastq` and `.lungfishref` project fixtures
- targeted source deletion for unreachable or misleading code

Excluded from this pass:

- new multi-stage demultiplex UX
- AI-guided structure inference
- migrating internal storage from FASTQ bundles to BAM
- bulk rewrites of unrelated document or bundle systems

### Working Assumptions

- The current product direction is intentionally simpler than the recent branch experiments.
- Existing broken on-disk virtual bundles are treated as stale artifacts and are not expected to self-heal without rerun.
- User-facing correctness is defined by the materialized sequence, the preview sequence, the cached statistics, and the derivative provenance all agreeing with each other.
- FASTA operations should only be exposed where the operation is actually supported without quality scores.

### Review Lenses And Phase Gates

Each phase must satisfy all three sign-off lenses before the next phase starts.

#### Swift/runtime sign-off

- no dead request paths remain reachable
- metadata encoding and decoding stay backward-tolerant where necessary
- build passes cleanly enough for targeted work
- tests cover new invariants instead of relying on manual reasoning

#### UX/workflow sign-off

- the visible UI matches the supported operation model
- buttons and labels do not imply removed capabilities
- save/import/export behavior is coherent for the remaining tabs
- virtual child outputs appear as separate datasets with understandable provenance

#### Genomics/file-format sign-off

- sequence lengths, headers, trims, and orientations remain consistent before and after virtual operations
- demultiplex and primer trim outputs preserve evidence needed for correct rematerialization
- FASTA-compatible operations reject or avoid quality-dependent behavior
- simulated bundles reflect realistic edge cases: truncated reads, descriptions, reverse complements, paired metadata, and reference-bundle lookup

### Phase 1: Inventory And Durable Plan

Deliverables:

- this plan document
- confirmed deletion target inventory
- validation matrix for FASTQ/FASTA operations

Sign-off criteria:

- dormant code surface is enumerated
- operation matrix is explicit
- simulation strategy is concrete enough to implement without redesign

### Phase 2: Remove Dormant Structure-Aware And Multi-Step Demux Code

Objective:

Physically remove source, metadata, resources, tests, and package hooks that only supported the abandoned structure-aware or multi-step demux model.

Deletion targets:

- `Sources/LungfishIO/Formats/FASTQ/FASTQStructureDemux.swift`
- `Sources/LungfishWorkflow/Demultiplex/StructureAwareDemuxPlanner.swift`
- `Tests/LungfishWorkflowTests/StructureAwareDemuxPlannerTests.swift`
- structure-demux state, controls, persistence, import/export, and preview logic in `FASTQMetadataDrawerView.swift`
- `structureDemuxConfigJSON` from `FASTQDemultiplexMetadata`
- any remaining `currentStructureDemuxConfiguration` or related drawer/controller APIs
- any unused multi-step demux helpers still present in `FASTQDerivativeService.swift`
- package resource hooks that were only added for the removed structure-demux tests

Required checks:

- no visible tab, button, menu, tooltip, or save path refers to Structure Demux
- no request-building path references multi-step demux
- saved FASTQ metadata still round-trips for the remaining tabs
- compile-time references to deleted types are eliminated, not commented out

Phase 2 sign-off:

- Swift/runtime: removed code is unreachable and physically deleted
- UX/workflow: drawer presents only supported concepts
- Genomics/file-format: removing the planner does not change active demux semantics

### Phase 3: Simplify Remaining Operation Contracts

Objective:

Make the surviving FASTQ/FASTA operations explicit, validated, and mutually coherent.

Tasks:

- review each FASTQ operation entry in `FASTQDatasetViewController`
- verify parameter validation and defaults for:
  - subsample proportion
  - subsample count
  - length filter
  - search text
  - search motif
  - deduplicate
  - quality trim
  - adapter trim
  - fixed trim
  - contaminant filter
  - primer removal
  - orient
  - demultiplex
- confirm which derivative kinds support FASTA and keep tests aligned with actual implementation
- remove or tighten any UI affordance that promises behavior not implemented by the service layer

Required checks:

- invalid parameter ranges fail early and clearly
- FASTA-compatible operation list matches actual service behavior and tests
- primer trimming remains a single-operation workflow with virtual trim sidecars
- demultiplex remains a single-operation workflow producing child bundles

Phase 3 sign-off:

- Swift/runtime: request validation is deterministic and testable
- UX/workflow: no hidden prerequisites remain for common operations
- Genomics/file-format: the chosen defaults are plausible for real sequencing data and do not silently rewrite semantics

### Phase 4: Simulated Project Harness

Objective:

Create representative temp-project tests that exercise the virtual dataset model instead of isolated helper functions.

Test harness requirements:

- generate a temp project directory
- create at least one `.lungfishfastq` bundle with:
  - read descriptions
  - heterogeneous lengths
  - motifs for search
  - trim/orient/demux-friendly synthetic barcodes or adapters
  - at least one reverse-complement orientation case
- create at least one `.lungfishref` bundle with a minimal FASTA payload suitable for orient/reference-picker flows
- exercise operations as child bundles, not loose files

Project scenarios:

1. Root FASTQ bundle
2. Length-filter child bundle
3. Fixed-trim child bundle
4. Orient child bundle
5. Demux child group with per-barcode virtual children
6. Primer-trim child bundle with optional unmatched sibling output
7. FASTA reference bundle used by orient-related flows

Required assertions:

- each child bundle contains the expected manifest and payload files
- `FASTQBundle.resolvePrimaryFASTQURL` returns the correct preview or payload path
- cached statistics agree with rematerialized content
- read descriptions survive subset, trim, orient, demux, and primer-trim paths where expected
- parent/root lineage stays correct
- reference-bundle resolution works from a project context

Phase 4 sign-off:

- Swift/runtime: bundle creation and loading work in temp projects
- UX/workflow: simulated outputs mirror what a user sees in the sidebar
- Genomics/file-format: sequence content and metadata stay coherent through chained virtual operations

### Phase 5: Operation Matrix And Edge-Case Coverage

Objective:

Add or extend tests to cover common and edge-case parameter combinations.

FASTQ operation matrix:

- `subsampleProportion`
  - valid: 0.1, 0.5
  - invalid: 0, >1
- `subsampleCount`
  - valid: 1, less than read count
  - edge: larger than read count
- `lengthFilter`
  - valid: min only, max only, min and max
  - invalid: min > max, both nil
- `searchText`
  - identifier and description
  - regex and literal
- `searchMotif`
  - literal and regex
  - no-hit and multi-hit cases
- `deduplicate`
  - identifier
  - description
  - sequence
- `qualityTrim`
  - high-quality no-op
  - low-quality trimming
- `adapterTrim`
  - literal adapter
  - FASTA adapter source
- `fixedTrim`
  - 5' only
  - 3' only
  - both ends
  - trim-to-empty rejection or handling
- `contaminantFilter`
  - bundled PhiX mode
  - custom reference mode
- `primerRemoval`
  - literal forward primer
  - linked forward/reverse primers
  - `keepUntrimmed` enabled
  - reverse-complement default behavior
- `orient`
  - forward reads
  - reverse-complement reads
  - unmatched reads with `saveUnoriented`
- `demultiplex`
  - single barcode kit
  - asymmetric sample assignments
  - empty/unassigned bucket

FASTA validation matrix:

- confirm supported operations on FASTA-derived records match `supportsFASTA`
- confirm unsupported operations are not advertised as FASTA-safe
- verify reference bundle handling for common FASTA extensions

Phase 5 sign-off:

- Swift/runtime: tests pin down parameter validation and edge-case behavior
- UX/workflow: error messaging and accepted ranges are reasonable
- Genomics/file-format: sequence transformations match biological expectations

### Phase 6: Build, Test, Review, And Cleanup

Objective:

Run the targeted verification set, fix regressions, and remove stale scaffolding that no longer serves the simplified model.

Verification set:

- `swift build`
- targeted existing tests relevant to FASTQ/FASTA derivatives
- new project-simulation tests
- targeted workflow integration tests for tool-backed operations

Expected outputs:

- concise implementation summary
- explicit list of deleted files and dead paths
- residual risks, if any

Phase 6 sign-off:

- Swift/runtime: build and targeted tests pass
- UX/workflow: visible flow is internally consistent
- Genomics/file-format: virtual and materialized outputs agree across the tested matrix

### Implementation Notes

- Prefer deletion over feature flags for abandoned paths.
- Preserve backward tolerance only when old metadata may still be encountered from existing bundles.
- Do not silently broaden FASTA support without proving the service path exists.
- When possible, test virtual derivatives by exporting materialized output and comparing it to the expected sequence text.

### Completion Criteria

This effort is complete when:

- all phases above are implemented
- the active UI only exposes supported FASTQ/FASTA workflows
- dormant structure-aware and multi-step demux code is removed
- simulated project tests cover representative virtual bundle workflows
- targeted build and test verification passes
