# 12S Amplicon Matching Implementation Plan

> **For dho:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan.

**Goal:** Add a separate, provenance-complete 12S rRNA amplicon matching workflow for merged FASTQ inputs, backed by a new `.lungfish12s` result bundle, structured 12S taxonomy metadata, CLI-backed export/append/review actions, and an AppKit viewport that follows existing LGE table/Inspector/bottom-drawer patterns.

**Architecture:** Implement this as a distinct workflow/result type, not an extension of MHC/KIR genotyping. Reuse Lungfish FASTQ/provenance/native-tool infrastructure where it is already shared, but keep 12S matching, unresolved sequence review, chimera review, and UI routing independently evolvable.

## Constraints And Invariants

- Every data-writing CLI/app pathway must write canonical `.lungfish-provenance.json` into the final output bundle.
- The workflow consumes merged FASTQ files or `.lungfastq` bundles containing merged FASTQ payloads; paired-end read merging remains a separate import recipe.
- Exact target support requires full-reference-span evidence, zero mismatches, and both-end soft-clipped sample sequence. Indels are tolerated only when the full target can still be aligned without substitutions.
- Reference FASTA is deduplicated, so one retained read should map to one target sequence. Ambiguous hits are still recorded defensively as `ambiguous_exact`.
- Output tables must orient biological targets as rows. The GUI must not create unbounded dynamic sample columns for large collections; per-sample evidence belongs in detail/drawer views and collection indexes.
- Track mapped read counts, exact-match percent, unresolved/non-exact percent, unresolved sequences, and chimera review status.
- Taxonomic filters such as mammals, fish, and human exclusion must use structured metadata, not display-string heuristics.
- GUI actions that create scientific outputs must shell out to `lungfish-cli` commands and preserve CLI provenance.

## Expert Review Revisions

The initial implementation plan was table-first and did not account for taxonomy metadata, incremental collections, or existing BLAST drawer conventions. Independent reviewers identified these blocking changes:

1. Add a CLI-backed metadata preparation step for the `/Users/dho/Downloads/32308` assets. The deduplicated FASTA keeps `n_refs`, `n_species`, and `also_matches`, but drops `group`, `taxid`, `name_source`, and `taxonomy` from `intermediate/12s_reference.tsv`.
2. Extend `.lungfish12s` bundles with structured target taxonomy and alternate-match tables before building filter UI.
3. Add CLI-backed unresolved FASTA export/BLAST preparation and collection append/index operations. Collections should append immutable result bundles by reference and key unresolved sequences by sequence SHA-256.
4. Replace the current bespoke 12S viewport with existing LGE idioms: AppKit tables/outlines, Inspector-controlled filters, action bar exports, and the shared bottom BLAST drawer.
5. Close provenance gaps before GUI polish: actual executable name should be `lungfish-cli`, vsearch steps need inputs and tool version, reference metadata prep needs sidecar provenance, and GUI exports must be CLI-backed.

## Task 0: Reference Metadata Preparation And Structured Bundle Fields

**Files**
- `Sources/LungfishWorkflow/TwelveS/TwelveSReferenceMetadata.swift`
- `Sources/LungfishWorkflow/TwelveS/TwelveSReferenceIndex.swift`
- `Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconMatchingWorkflow.swift`
- `Sources/LungfishIO/Bundles/TwelveSAmpliconResultBundle.swift`
- `Sources/LungfishCLI/Commands/FastqTwelveSReferenceMetadataSubcommand.swift`
- `Sources/LungfishCLI/Commands/FastqTwelveSMatchSubcommand.swift`
- `Sources/LungfishCLI/Commands/FastqCommand.swift`
- `Tests/LungfishWorkflowTests/TwelveSReferenceMetadataTests.swift`
- `Tests/LungfishWorkflowTests/TwelveSAmpliconMatchingWorkflowTests.swift`
- `Tests/LungfishIOTests/TwelveSAmpliconResultBundleTests.swift`
- `Tests/LungfishCLITests/FastqTwelveSMatchSubcommandTests.swift`

**Steps**
1. Add failing tests for preparing a `12s-target-metadata.tsv` sidecar from a deduplicated FASTA and MIDORI metadata TSV.
2. Add structured target fields: `taxid`, `taxonGroup`, `taxonomy`, `nameSource`, and `[TwelveSAlternateMatch]`.
3. Add `target-alternate-matches.tsv` to `.lungfish12s` bundles and keep loading backward compatible for older bundles.
4. Add `lungfish-cli fastq 12s-reference-metadata --dedup-fasta ... --midori-metadata ... --output ...`.
5. Add optional `--reference-metadata` to `fastq 12s-match`; if supplied, metadata is included in target tables and provenance inputs.
6. Fix 12S provenance to use `lungfish-cli` in generated argv and to record vsearch input FASTA plus parsed vsearch version.

**Verification**
- `swift test --skip-update --filter TwelveSReferenceMetadataTests`
- `swift test --skip-update --filter TwelveSAmpliconMatchingWorkflowTests`
- `swift test --skip-update --filter FastqTwelveSMatchSubcommandTests`

## Task 1: Add 12S Result Models And Bundle Loader

**Files**
- `Sources/LungfishIO/Bundles/TwelveSAmpliconResultBundle.swift`
- `Tests/LungfishIOTests/TwelveSAmpliconResultBundleTests.swift`

**Steps**
1. Write tests for decoding a synthetic `.lungfish12s` directory containing:
   - `12s-result.json`
   - `sample-target-counts.tsv`
   - `targets.tsv`
   - `samples.tsv`
   - `read-fate.json`
   - `.lungfish-provenance.json`
2. Implement manifest, sample, target, count, read-fate, unresolved, and bundle structs.
3. Add robust TSV parsing with clear errors for missing required columns and non-integer counts.
4. Include convenience summaries for:
   - target rows sorted by total exact reads
   - sample totals
   - unresolved/non-exact percent
   - chimera candidate counts

**Verification**
- `swift test --filter TwelveSAmpliconResultBundleTests`

## Task 2: Add Matching Engine And Workflow Writer

**Files**
- `Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconMatchingWorkflow.swift`
- `Sources/LungfishWorkflow/TwelveS/TwelveSReferenceIndex.swift`
- `Sources/LungfishWorkflow/TwelveS/TwelveSFastqReader.swift`
- `Sources/LungfishWorkflow/TwelveS/TwelveSChimeraReview.swift`
- `Tests/LungfishWorkflowTests/TwelveSAmpliconMatchingWorkflowTests.swift`

**Steps**
1. Write tests with tiny synthetic FASTQ/reference fixtures covering:
   - both-end soft-clipped exact target match
   - exact reference sequence with no soft clip remains unresolved
   - one-substitution read remains unresolved
   - insertion/deletion relative to the target is accepted when no substitutions occur
   - unresolved sequence table aggregates identical unresolved reads
   - vsearch chimera review can be supplied by a fake runner
   - canonical provenance is written and references final bundle payload paths
2. Implement FASTA parsing and reference metadata extraction from pipe-delimited headers.
3. Implement merged FASTQ iteration for plain and gzip FASTQ.
4. Implement a bounded short-amplicon alignment classifier:
   - prefilter by shared k-mers/length window for real references
   - semiglobal dynamic programming to align the full target to a read, counting substitutions and indels
   - require soft clip length `>= minimumSoftClipBases` on both read ends
5. Write all planned bundle files atomically under `<output-name>.lungfish12s`.
6. Write canonical provenance using `ProvenanceRunBuilder`, including CLI/workflow version, replayable argv, resolved defaults, input/output paths, checksums, file sizes, runtime identity, exit status, wall time, and vsearch stderr when applicable.

**Verification**
- `swift test --filter TwelveSAmpliconMatchingWorkflowTests`

## Task 3: Add CLI Subcommand

**Files**
- `Sources/LungfishCLI/Commands/FastqTwelveSMatchSubcommand.swift`
- `Sources/LungfishCLI/Commands/FastqCommand.swift`
- `Tests/LungfishCLITests/FastqTwelveSMatchSubcommandTests.swift`
- `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift`

**Steps**
1. Add `lungfish fastq 12s-match INPUT... --reference REF.fa --output-dir DIR --output-name NAME`.
2. Expose options for minimum soft clip bases, unresolved sequence reporting, chimera review mode, vsearch abundance threshold, and force overwrite.
3. Ensure argument validation rejects missing reference/input files and existing output bundle unless `--force` is set.
4. Register command help and provenance policy coverage.

**Verification**
- `swift test --filter FastqTwelveSMatchSubcommandTests`

## Task 4: Add LGE-Pattern App Viewport, Inspector Filters, And CLI-Backed Actions

**Files**
- `Sources/LungfishApp/Views/Results/TwelveS/TwelveSAmpliconResultViewController.swift`
- `Sources/LungfishApp/Views/Results/TwelveS/TwelveSTargetTableView.swift`
- `Sources/LungfishApp/Views/Results/TwelveS/TwelveSUnresolvedTableView.swift`
- `Sources/LungfishApp/Views/Results/TwelveS/TwelveSResultDisplayState.swift`
- `Sources/LungfishApp/Views/Inspector/Sections/TwelveSResultDisplaySection.swift`
- existing result routing/import files found by search
- `Tests/LungfishAppTests/TwelveSAmpliconResultViewControllerTests.swift`

**Steps**
1. Add a result-route detector for `.lungfish12s` bundles.
2. Replace the current one-table custom viewport with the existing classifier-style information architecture:
   - top summary strip
   - central fixed-column table or outline
   - selection detail pane for per-sample evidence and alternate matches
   - `ClassifierActionBar` for export and BLAST/search actions
   - shared bottom BLAST drawer using `BlastResultsDrawerContainerView` / `BlastResultsDrawerTab`
3. Implement progressive disclosure for alternate matches using `NSOutlineView` or a detail pane, not a semicolon-only cell.
4. Expand Inspector state and controls:
   - minimum exact reads
   - text search
   - taxon group include/exclude chips or pop-up controls
   - exclude human
   - has alternate matches
   - minimum unresolved reads
   - chimera status
5. Make export and unresolved FASTA/BLAST preparation shell out to CLI commands.
6. Keep the GUI scalable by avoiding one dynamic table column per sample in the primary target view.

**Verification**
- `swift test --filter TwelveSAmpliconResultViewControllerTests`

## Task 5: End-To-End Verification With Example Data

**Commands**
- `swift test --filter TwelveS`
- `swift test --filter Provenance`
- `swift run lungfish fastq 12s-match /Users/dho/Downloads/HI_Hilo_WWTP_20260511__12S_F09_S69_L001_R1_001.fastq.gz --reference /Users/dho/Downloads/amplicons_12s_deduplicated.fa --output-dir /tmp/lge-12s --output-name hilo-f09 --force`

**Notes**
- The example command uses one FASTQ only if no merged FASTQ bundle is available; if the R1/R2 example has not been merged, use a synthetic merged fixture for correctness tests and leave paired-end merge to the existing recipe.
- Inspect the output bundle for required payloads and `.lungfish-provenance.json`.
- For UI verification, open the generated `.lungfish12s` bundle through the app route if a local GUI test harness is available.
