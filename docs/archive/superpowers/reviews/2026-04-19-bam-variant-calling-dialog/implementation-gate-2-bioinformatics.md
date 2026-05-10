# Implementation Gate 2 Bioinformatics Review

## Decision

- No blocking-now bioinformatics issues remain in Task 2.
- Task 3 must carry forward Medaka-specific execution validation and caller-parameter enforcement.

## Basis

- Workflow/state layer verification passed after the latest fixes:
  - `xcrun xctest -XCTest VariantDatabaseGenotypeTests/testNoSampleVCFInViralFrequencyModeKeepsSamplesEmpty,VariantDatabaseGenotypeTests/testNoSampleVCFInViralFrequencyModeKeepsSampleCountAndGenotypesEmpty,BAMVariantCallingPreflightTests,BundleVariantTrackAttachmentServiceTests,VariantSQLiteImportCoordinatorTests .../LungfishGenomeBrowserPackageTests.xctest`
  - Result: 14 tests, 0 failures on 2026-04-19.
- Expert bioinformatics review concluded there are no remaining blockers in the workflow/state/provenance layer.

## Blocking-Now Findings

- None.

## Carry-Forward To Task 3

- `BAMVariantCallingPreflight.swift` only verifies that `medakaModel` is non-empty. Platform-aware Medaka validation must happen once the CLI/pipeline layer has caller-execution context.
- `BundleVariantCallingRequest.minimumAlleleFrequency` and `.minimumDepth` are request knobs only until the CLI pipeline consumes them and records the effective caller arguments in provenance.
- Multi-contig or segmented viral references still cannot get checksum validation stronger than the current whole-FASTA model because `GenomeInfo` only stores a bundle-level checksum.
