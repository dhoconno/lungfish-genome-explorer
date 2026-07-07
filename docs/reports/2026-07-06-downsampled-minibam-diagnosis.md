# Issue #22 Downsampled MiniBAM Diagnosis

Date: 2026-07-07

## Finding

The confirmed failure is a database hydration gap in `lungfish-cli build-db taxtriage`, not a FASTQ materialization gap.

The app TaxTriage path already routes every sample through `AppDelegate.resolveInputFiles(...)` before running the pipeline. That resolver installs `FASTQDerivativeService.shared.materializeDatasetFASTQ(...)` as the bundle materializer, then substitutes the resolved file URLs back into `resolvedConfig.samples[i].fastq1/.fastq2` before `TaxTriageSerialBatchRunner` starts. This rejects the H1 concern that the app intentionally passes a virtual bundle `preview.fastq` directly into TaxTriage.

The durable output policy also does not strip BAM or BAI files. `TaxTriageOutputArtifactPolicy` only prunes known intermediate directories (`work`, `download`, and `workflow-source`). BAM/BAI files under the retained result tree survive collection and provenance descriptor generation.

The concrete bug was narrower: `BuildDbCommand.TaxTriageSubcommand.resolveTaxTriageBAMPaths(...)` only accepted the exact canonical upstream filename:

```text
minimap2/<sample>.<sample>.dwnld.references.bam
```

When TaxTriage output contains a retained downsampled or renamed MiniBAM under `minimap2/`, the SQLite builder created taxonomy rows with `bam_path = NULL` and `bam_index_path = NULL`. Because `updateUniqueReadsInDB(...)` only processes rows with both `bam_path` and `primary_accession`, those rows also kept `unique_reads = NULL`.

The UI reads these exact columns from `taxtriage.sqlite`: `TaxTriageResultViewController` resolves relative `bam_path` values against the TaxTriage result directory, uses them to populate `bamFilesBySample`, then computes or displays unique-read values. Nil `bam_path` therefore removes the MiniBAM viewer path and prevents `unique_reads` from being populated.

## Evidence

- Red regression test:
  - `BuildDbCommandTests/testBuildDbTaxTriageResolvesDownsampledMiniBAMNames`
  - The test renames `Tests/Fixtures/taxtriage-mini/minimap2/SRR35517702.SRR35517702.dwnld.references.bam` to `SRR35517702.downsampled.minibam.bam` and runs `build-db taxtriage`.
  - Before the fix, the test failed because `bamPath`, `bamIndexPath`, and `uniqueReads` were all nil.

- Green regression test:
  - The same test now asserts:
    - `bam_path = minimap2/SRR35517702.downsampled.minibam.bam`
    - `bam_index_path = minimap2/SRR35517702.downsampled.minibam.bam.bai`
    - `unique_reads = 25`
    - `reads_aligned = 31`
  - A separate hardening test verifies that a single unmatched BAM in `minimap2/` is not assigned to a different sample merely because it is the only BAM present.
  - Another hardening test verifies that two equally scored same-sample fallback BAMs are treated as ambiguous rather than choosing lexicographically.

- Broader TaxTriage build-db verification:
  - Canonical TaxTriage fixture import still populates BAM paths and unique reads.
  - Top-report fallback without BAMs still succeeds without requiring samtools.
  - Serial sample subdirectory parsing still prefixes relative BAM paths correctly.
  - Cleanup and samtools provenance tests still pass.

## Fix Applied

`resolveTaxTriageBAMPaths(...)` now:

1. Prefers the canonical upstream BAM path when present.
2. Falls back to scanning retained `minimap2/` BAMs for filenames containing the sample token.
3. Preferentially chooses downsampled/MiniBAM filenames, then canonical reference BAMs, then other sample-token matches.
4. Returns `bam_path` and `bam_index_path` relative to the TaxTriage result directory.
5. Resolves adjacent `.bam.bai`, `.bam.csi`, `.bai`, and `.csi` index naming styles.
6. Leaves BAM fields nil when no retained BAM filename contains the sample token, avoiding cross-sample misassignment.
7. Leaves BAM fields nil when same-score fallback candidates are ambiguous.

This keeps the final database paths portable and allows the existing UI and unique-read updater to work without changing the result browser.

## Verification

Focused commands run:

```sh
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/weekly-issues-plans --skip-update --filter BuildDbCommandTests/testBuildDbTaxTriageResolvesDownsampledMiniBAMNames
```

Result: 1 XCTest executed, 0 failures.

```sh
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/weekly-issues-plans --skip-update --filter BuildDbCommandTests/testBuildDbTaxTriage --filter BuildDbCommandTests/testBuildDbTaxTriageResolvesDownsampledMiniBAMNames --filter BuildDbCommandTests/testBuildDbTaxTriageFallsBackToTopReportsWithoutConfidenceFileOrSamtools --filter BuildDbCommandTests/testBuildDbTaxTriageParsesSerialSampleSubdirectories --filter BuildDbCommandTests/testBuildDbTaxTriageCleansSerialSampleIntermediates --filter BuildDbCommandTests/testTaxTriageNoCleanupPreservesAll --filter BuildDbCommandTests/testBuildDbTaxTriageProvenanceRecordsSamtoolsSubsteps --filter BuildDbCommandMarkdupTests/testBuildDbTaxTriageRunsMarkdup
```

Result: 11 XCTest tests executed, 0 failures.

Additional hardening command:

```sh
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/weekly-issues-plans --skip-update --filter BuildDbCommandTests/testBuildDbTaxTriageResolvesDownsampledMiniBAMNames --filter BuildDbCommandTests/testBuildDbTaxTriageDoesNotAssignUnmatchedSingleBAMToSample
```

Result: 2 XCTest tests executed, 0 failures.

## Residual Risk

This diagnosis used the repository's TaxTriage mini fixture and the build-db boundary that creates `taxtriage.sqlite`; it did not run a live Nextflow TaxTriage job in this pass. The fixed boundary is the one the app invokes immediately after TaxTriage completion, and it is the boundary that controls UI-visible `bam_path`, `bam_index_path`, and `unique_reads`.
