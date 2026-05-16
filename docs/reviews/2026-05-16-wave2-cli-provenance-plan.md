# Wave 2 CLI Provenance Remediation Plan

## Scope

Worker A owns the `classify` and `map` CLI sequence-input lane, plus a feasible non-XCUITest check for GUI minimap2 provenance. This wave follows the Wave 1 assembly finding: virtual derived `.lungfishfastq` bundles must be materialized before scientific tools run, and provenance must preserve both the original bundle input and the durable execution payload path.

## Issue IDs

- `W2-CLI-PROV-001` / `docs-027` / `FND-026`: `lungfish classify` must not classify a virtual derived FASTQ by silently resolving to the root payload.
- `W2-CLI-PROV-002` / `docs-027` / `FND-026`: `lungfish map` must not map a virtual derived FASTQ by silently resolving to the root payload.
- `W2-CLI-PROV-003` / `docs-027`: classify/map provenance must record original bundle inputs, materialized execution payloads, checksums, sizes, argv, defaults, runtime identity, exit status, wall time, and useful stderr at the final output location.
- `W2-CLI-PROV-004` / `docs-014`: GUI minimap2 mapping must preserve provenance when virtual-bundle inputs are routed through app helpers.
- `W2-CLI-PROV-005` / `docs-027`: ONT GUI import provenance or stale command text must be audited within this lane if it does not cross dialog-worker scope.

## Red Tests

Planned failing tests before production edits:

- `CLIRegressionTests.testClassifyMaterializesVirtualDerivedBundleInsteadOfRootPayload`
- `CLIRegressionTests.testClassifyProvenanceRecordsOriginalVirtualBundleAndMaterializedExecutionInput`
- `CLIRegressionTests.testMapMaterializesVirtualDerivedBundleInsteadOfRootPayload`
- `CLIRegressionTests.testMapProvenanceRecordsOriginalVirtualBundleAndMaterializedExecutionInput`
- `UnifiedClassifierRunnerTests.testRunMinimap2MappingKeepsDurableVirtualInputProvenanceBeforeResolvedExecutionInputs`
- `GUIRegressionTests.testONTImportOperationShowsAvailableCLICommand`

Red output from:

`swift test --filter 'ClassifyCommandMaterializationRegressionTests|MapCommandRegressionTests/testMapMaterializesVirtualDerivedBundleInsteadOfRootPayload|MapCommandRegressionTests/testMapProvenanceRecordsOriginalVirtualBundleAndMaterializedExecutionInput'`

Expected failures before production changes:

```text
Tests/LungfishCLITests/CLIRegressionTests.swift:261:50: error: type 'ClassifyCommand' has no member 'resolveExecutionInputs'
Tests/LungfishCLITests/CLIRegressionTests.swift:315:46: error: type 'ClassifyCommand' has no member 'writeProvenance'
Tests/LungfishCLITests/CLIRegressionTests.swift:2185:45: error: type 'MapCommand' has no member 'resolveExecutionInputs'
Tests/LungfishCLITests/CLIRegressionTests.swift:2215:37: error: extra argument 'originalInputFASTQURLs' in call
Tests/LungfishCLITests/CLIRegressionTests.swift:2238:32: error: cannot find 'CLISequenceInputMaterialization' in scope
Tests/LungfishCLITests/CLIRegressionTests.swift:2637:55: error: cannot find type 'CLISequenceInputMaterializing' in scope
error: fatalError
```

## Implementation

1. Added `CLISequenceInputMaterialization`, a small shared CLI helper under `Sources/LungfishWorkflow/Extraction`. It detects virtual derived `.lungfishfastq` payloads (`subset`, `trim`, `demuxedVirtual`, `orientMap`), rejects container-only demux groups, delegates durable materialization to `FASTQCLIMaterializer`, and exposes descriptor/`FileRecord` helpers that preserve original bundle/root payload lineage.
2. Updated `ClassifyCommand` to materialize virtual derived bundles into `.lungfish-classify-inputs` under the final output directory before building `ClassificationConfig`.
3. Updated classify provenance to write a canonical `ProvenanceEnvelope` at the final output directory with original input descriptors, materialized execution descriptors, defaults/resolved options, runtime identity, exact argv, durable replay argv, materialization step, Kraken2 step, checksums, file sizes, exit status, wall time, and stderr.
4. Updated `MapCommand` to materialize virtual derived bundles into `.lungfish-map-inputs` under the final output directory before creating `MappingRunRequest`, and to route missing/unsupported/materialization/pipeline failures through `CLIError`.
5. Extended `MappingRunRequest` with optional original-input and materialization timing fields, preserving compatibility for existing callers.
6. Updated `ManagedMappingPipeline` so mapper steps record the actual execution inputs, top-level mapping provenance records original bundle/root payload plus materialized execution payload and reference, and a `lungfish.map.input-materialization` step is emitted when map consumed a materialized virtual bundle.
7. Added an app-level source regression that guards `AppDelegate.runMinimap2Mapping` provenance wiring: it resolves execution files, preserves durable provenance inputs/records, then swaps in resolved execution inputs for the pipeline.
8. Updated GUI ONT import operation text to the real `lungfish fastq import-ont` command and added a regression guard against the stale "CLI command not yet available" text.
9. Reviewer follow-up moved classify/map validation ahead of virtual FASTQ materialization where possible, writes materialization-only provenance immediately after durable payload creation, cleans partial materialization outputs on failure, rewrites relative virtual input argv for durable replay, and records materialization steps with the real `lungfish fastq materialize <bundle> --output <payload>` command.
10. Reviewer follow-up fixed nested GUI CLI command rendering so `OperationCenter.buildCLICommand(subcommand: "fastq import-ont", ...)` displays copy-pasteable `lungfish fastq import-ont ...` instead of shell-quoting the nested subcommand as one token.

## Verification

Required commands:

- `swift build --product lungfish-cli`
- `swift test --filter 'ClassifyCommandMaterializationRegressionTests|MapCommandRegressionTests/testMapMaterializesVirtualDerivedBundleInsteadOfRootPayload|MapCommandRegressionTests/testMapProvenanceRecordsOriginalVirtualBundleAndMaterializedExecutionInput'`
- `swift test --filter 'UnifiedClassifierRunnerTests/testRunMinimap2MappingKeepsDurableVirtualInputProvenanceBeforeResolvedExecutionInputs|GUIRegressionTests/testONTImportOperationShowsAvailableCLICommand'`
- `swift test --filter 'Minimap2ResultSidecarTests/testPipelineRunUsesStoredReplayInputWhenDurableInputIsVirtualBundle'`
- `git diff --check`

Current results:

- Red CLI test pass was captured before implementation; compile failed on the intentionally missing classify/map materialization/provenance seams shown above.
- Focused CLI regression filter is green after implementation: 4 tests, 0 failures.
- App/GUI focused filter is green: 2 tests, 0 failures.
- Existing minimap2 virtual replay sidecar guard is green: 1 test, 0 failures.
- `swift build --product lungfish-cli` passed.
- `git diff --check` passed.

Reviewer follow-up results:

- `swift test --filter 'ClassifyCommandMaterializationRegressionTests|MapCommandRegressionTests/testManagedMappingMaterializationProvenanceUsesRealFastqMaterializeCommand|MapCommandRegressionTests/testMapProvenanceRecordsOriginalVirtualBundleAndMaterializedExecutionInput'` passed: 7 tests, 0 failures.
- `swift test --filter 'DownloadCenterTests/testBuildCLICommand|GUIRegressionTests/testONTImportOperationShowsAvailableCLICommand|ClassifierExtractionInvariantTests'` passed: 27 tests, 1 skipped, 0 failures.
- `swift build --product lungfish-cli` passed.
- `swift build --target LungfishApp` passed.
- `git diff --check` passed.

## Residual Risk

- Full end-to-end tool execution depends on managed conda/native tool availability; unit-level provenance and resolver tests will cover durable paths without requiring Kraken2/minimap2 installs.
- Full XCUITest coverage remains deferred. The app path has source-level guard coverage plus existing `Minimap2Pipeline` replay tests, but no fragile UI automation was added in this lane.
- GUI ONT import now shows a reproducible CLI command, and the CLI import writes provenance. This lane did not refactor GUI ONT import to rehydrate CLI provenance because that would cross broader dialog/import workflow ownership.
