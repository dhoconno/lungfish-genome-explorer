# Wave 5 Source Test Hygiene 2 Plan

> **For agentic workers:** Keep this task scoped to the listed workflow/CLI provenance tests and `ManagedMappingPipelineTests`. Do not broaden into unrelated app source-string assertions.

**Goal:** Replace fragile source-file substring assertions with behavior tests that execute provenance or mapping behavior and decode emitted outputs.

**Architecture:** Classification and TaxTriage provenance tests will run against fake managed-tool fixtures and decode `.lungfish-provenance.json`. Mapping tests will call narrow `@testable` hooks for staging/preflight behavior and keep existing streaming subprocess behavior tests. CLI regression source reads will be replaced by parser/help/provenance behavior checks.

**Tech Stack:** Swift XCTest, Swift Package Manager, `ProvenanceRecorder`, `CondaManager` fake roots, existing LungfishWorkflow/LungfishCLI test fixtures.

---

## Scope

- Modify `Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineProvenanceSourceTests.swift`.
- Modify `Tests/LungfishWorkflowTests/TaxTriagePipelineProvenanceSourceTests.swift`.
- Modify source-read assertions only in `Tests/LungfishCLITests/CLIRegressionTests.swift`.
- Modify source-read assertions only in `Tests/LungfishWorkflowTests/Mapping/ManagedMappingPipelineTests.swift`.
- Add narrow production testability hooks only where behavior is otherwise private.

## Tasks

- [x] Draft this plan in `docs/reviews/wave5-source-test-hygiene-2-plan.md`.
- [x] Replace classification provenance source checks with fake Kraken2/Bracken runs and decoded provenance assertions:
  - Assert input/report/output file records include checksum and size.
  - Assert Bracken failure records no absent Bracken output.
- [x] Replace TaxTriage provenance source checks with a fake Nextflow/micromamba run and decoded provenance assertions:
  - Assert run name/status, TaxTriage step, command, FASTQ inputs, output records, exit status, wall time, and stderr.
- [x] Replace mapping source checks:
  - Use a behavior hook to verify `prepareExecution` stages SAM-safe FASTA inputs before mapping.
  - Use a behavior hook to verify conda mapper preflight checks the requested tool environment.
  - Keep and strengthen existing streaming stdout tests for stderr drain/cancellation/process termination behavior.
- [x] Replace CLI regression source checks:
  - Managed assembly aliases are covered by parse/help behavior and provenance emitted by `AssembleCommand.writeProvenance`.
  - Managed mapping materialization command is covered by decoded `MappingProvenance` canonical envelope and materialization step assertions.
- [x] Run targeted `rg` on the four listed files to prove no source-file assertions remain there.
- [x] Run focused tests:
  - `swift test --filter ClassificationPipeline`
  - `swift test --filter TaxTriagePipeline`
  - `swift test --filter ManagedMappingPipelineTests`
  - `swift test --filter AssembleCommandRegressionTests`
  - `swift test --filter MapCommandRegressionTests`
  - `swift test --filter CLIRegressionTests` (confirmed this filename-shaped filter matches zero tests)
- [x] Run `git diff --check`.
- [ ] Commit the scoped change.

## Notes

- Red/green constraint: the migrated tests target existing behavior, so production changes are limited to dependency injection/test hooks required to observe behavior without real scientific tools.
- Provenance coverage must remain scientific: tests decode emitted provenance rather than scanning source text.
