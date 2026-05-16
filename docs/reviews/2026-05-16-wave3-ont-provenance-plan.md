# Wave 3 Slice A: ONT Import Provenance Plan

Date: 2026-05-16
Worktree: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/wave3-ont-provenance`
Branch: `codex/wave3-ont-provenance`
Base design: `docs/reviews/2026-05-16-wave3-next-phase-design.md`

## Slice Spec

Close the GUI ONT import provenance gap by moving ONT import provenance from the
CLI subcommand into a shared `LungfishWorkflow` API. The low-level
`ONTDirectoryImporter` remains responsible for layout detection and bundle
creation; the new workflow wrapper owns canonical provenance for the final
output directory and created `.lungfishfastq` bundles.

The CLI keeps existing user behavior and delegates to the workflow. The GUI uses
the same workflow through an app coordinator that owns Operation Center command,
progress, completion, and failure updates. GUI provenance must be CLI-equivalent
and must point at durable final payload paths, not temporary staging paths.

Required provenance fields for this slice:

- workflow/tool name and version
- exact argv, durable replay argv, and reproducible command
- explicit options, resolved options, and defaults
- caller identity (`cli` or `gui`)
- runtime identity
- original ONT chunk input paths with checksums and file sizes
- final manifest and bundle payload output paths with checksums and file sizes
- exit status, wall time, and useful stderr when present
- root `.lungfish-provenance.json`, bundle root `.lungfish-provenance.json`,
  bundle rollup provenance, and focused bundle output sidecars

On provenance write failure, the workflow should roll back created ONT bundles
and the demultiplex manifest so missing provenance cannot leave imported
scientific data behind.

## TDD And Red-Test Plan

Add failing tests before production code:

- `ONTImportWorkflowTests.testImportWritesRootAndFocusedBundleProvenance`
  verifies root and bundle provenance layouts.
- `ONTImportWorkflowTests.testProvenanceDescriptorsUseOriginalInputsAndFinalOutputs`
  verifies source chunk inputs and final manifest/bundle output descriptors have
  checksums and sizes.
- `ONTImportWorkflowTests.testProvenanceWriteFailureRollsBackCreatedBundlesAndManifest`
  verifies all-or-nothing rollback on provenance write failure.
- `FastqImportONTProvenanceTests.testCLIImportONTDelegatesToWorkflowProvenance`
  verifies CLI argv/default/runtime behavior is preserved through the shared
  workflow.
- `ONTImportOperationCoordinatorTests.testCoordinatorRunsWorkflowAndCompletesOperationCenter`
  verifies GUI coordinator command context, Operation Center command/progress,
  completion, and bundle URL reporting.

Initial red-test attempt before adding tests:

```text
swift test --filter 'ONTImportWorkflowTests|FastqImportONTProvenanceTests|ONTImportOperationCoordinatorTests'
Build complete! (852.92s)
warning: No matching test cases were run
Executed 0 tests, with 0 failures
```

This proved the slice tests were not present yet. After adding the red tests,
rerunning the same filter produced the expected missing API failures:

```text
swift test --filter 'ONTImportWorkflowTests|FastqImportONTProvenanceTests|ONTImportOperationCoordinatorTests'
Tests/LungfishWorkflowTests/ONTImportWorkflowTests.swift:139:65: error: cannot find type 'ONTImportWorkflow' in scope
Tests/LungfishWorkflowTests/ONTImportWorkflowTests.swift:24:24: error: cannot find 'ONTImportWorkflow' in scope
Tests/LungfishWorkflowTests/ONTImportWorkflowTests.swift:113:24: error: cannot find 'ONTImportWorkflow' in scope
Tests/LungfishWorkflowTests/ONTImportWorkflowTests.swift:144:16: error: cannot find 'ONTImportWorkflow' in scope
error: fatalError
```

## Implementation Plan

1. Add the workflow tests, CLI test, and app coordinator test.
2. Add `ONTImportWorkflow` in `Sources/LungfishWorkflow/Ingestion` with an
   explicit command context and injectable provenance writer for rollback tests.
3. Make the workflow call `ONTDirectoryImporter.importDirectory`, collect
   original chunk input descriptors, collect concrete final output descriptors,
   build a canonical `ProvenanceEnvelope`, write output-root provenance, then
   write bundle-root provenance so rollup and focused sidecars are generated.
4. Replace `FastqImportONTSubcommand` inline provenance recording with a shared
   workflow call while preserving stderr progress and summary output.
5. Add `ONTImportOperationCoordinator` in `LungfishApp` to construct GUI command
   context, start/update/complete/fail Operation Center, and return the workflow
   result.
6. Route `MainSplitViewController.performONTImport` through the coordinator and
   keep existing viewer/sidebar/drop-completion behavior.
7. Run focused tests, affected product builds, `git diff --check`, review the
   diff, and commit the slice.

## Verification Commands

```bash
swift test --filter 'ONTImportWorkflowTests|ONTDirectoryImporterTests'
swift test --filter 'FastqImportONTProvenanceTests|ONTImportOperationCoordinatorTests'
swift build --product lungfish-cli
swift build --product Lungfish
git diff --check
```

## Residual Risks

- Existing broad app tests emit Swift 6 actor-isolation warnings unrelated to
  this slice; focused verification should not introduce new warnings in touched
  files.
- Bundle output enumeration must exclude provenance sidecars to avoid
  self-referential output descriptors.
- The GUI coordinator records a CLI-equivalent command but still runs in-process;
  context construction must stay aligned with CLI option/default changes.
