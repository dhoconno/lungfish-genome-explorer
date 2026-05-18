# Slice C IO Fixture Implementation Note

Worker: C
Branch: `codex/wave2-io-fixtures`
Date: 2026-05-16

## Scope

Replace Desktop-only GFF3 and VCF real-file tests with committed package
fixtures under `Tests/LungfishIOTests/Resources`. Remove silent skips from the
owned tests and keep assertions at parser behavior level: header metadata,
feature/variant counts, strand/filter/genotype parsing, grouping, and
annotation coordinate conversion.

## Approach

- Run the focused GFF3/VCF tests first to confirm the current Desktop-path
  behavior.
- Prefer existing `sample.gff3` and `sarscov2_*.vcf` resources when their
  contents cover the assertions.
- Add tiny synthetic fixtures only for coverage that existing resources do not
  express, especially VCF sample genotypes and filtered records.
- Verify no owned IO tests retain `/Users/dho/Desktop`, `Desktop/test`,
  `testProjectPath`, or `skipIfTestDirectoryMissing`.
