# Wave 5 Metadata Provenance Remediation Plan

**Goal:** Make `lungfish metadata set` and `lungfish metadata import` write canonical reproducibility provenance for every metadata payload they mutate.

**Scope:** Limit edits to `Sources/LungfishCLI/Commands/MetadataCommand.swift`, metadata CLI tests, and this review plan. Use existing `CLIProvenanceSupport.recordSingleStepRun` and canonical `ProvenanceRunBuilder` output rather than adding a new metadata-specific format.

## Requirements

- `metadata set` records a completed `lungfish metadata set` run in the target bundle and includes the final stored `metadata.csv` payload, checksum, size, argv, resolved/default options, runtime identity, exit status, and wall time.
- `metadata import` records a completed `lungfish metadata import` run in the destination folder and includes the input CSV, final `samples.csv`, and each synced bundle `metadata.csv` when `--sync-bundles` is used.
- File sidecars must point at final stored payloads (`metadata.csv` and `samples.csv`) and must not reference temp or staging-only paths.
- If provenance writing fails after metadata mutation, the command must throw instead of reporting success.

## TDD Steps

1. Add failing XCTest coverage for `metadata set` provenance, including canonical envelope fields and the `metadata.csv` sidecar.
2. Add failing XCTest coverage for `metadata import --sync-bundles`, including `samples.csv`, synced bundle metadata outputs, input CSV metadata, and no temp/staging paths.
3. Implement small provenance helpers in `MetadataCommand.swift` that collect final output `FileRecord`s after mutation and call `CLIProvenanceSupport.recordSingleStepRun`.
4. Run focused metadata CLI tests, `swift build --product lungfish-cli`, and `git diff --check`.
5. Commit the scoped remediation on `codex/wave5-metadata-provenance`.
