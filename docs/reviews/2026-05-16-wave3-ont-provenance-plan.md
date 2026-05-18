# Wave 3 Slice A ONT Provenance Plan

Date: 2026-05-16
Worktree: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/wave3-ont-provenance`
Branch: `codex/wave3-ont-provenance`

## Slice Spec

Close the GUI ONT import provenance gap by moving `lungfish fastq import-ont`
provenance writing out of `FastqImportONTSubcommand` and into a shared
`LungfishWorkflow` API. `ONTDirectoryImporter` remains the low-level ONT layout
detector and `.lungfishfastq` bundle creator. The new workflow wrapper imports
the directory, writes canonical `.lungfish-provenance.json` at the final output
directory, and writes focused bundle provenance for every created
`.lungfishfastq` payload.

The workflow API must accept caller context for CLI and GUI:
tool/workflow name and version, exact argv, durable replay argv when useful,
copy-pasteable reproducible command, explicit options, defaults, resolved
options, runtime identity, and caller kind. Inputs are the durable source chunk
FASTQs. Outputs are the final demultiplex manifest and final bundle payload
files, never temporary staging paths. Provenance includes checksums, file sizes,
exit status, wall time, and useful stderr. If provenance writing fails after
bundles or the manifest are created, the workflow rolls back created bundles and
the manifest so missing provenance is blocking.

The CLI keeps existing `lungfish fastq import-ont` behavior and user-visible
stderr output, but delegates import and provenance writing to the workflow. The
GUI routes ONT import through `ONTImportOperationCoordinator`, which owns
Operation Center start/progress/completion/failure updates and keeps the
copy-pasteable `lungfish fastq import-ont ...` command visible without shelling
out to the CLI.

## TDD And Red-Test Plan

1. Add `Tests/LungfishWorkflowTests/ONTImportWorkflowTests.swift`.
   - Test successful import writes root canonical provenance and per-bundle
     focused provenance.
   - Test provenance inputs are original chunk files with checksum/size and
     outputs are final manifest plus final bundle payloads.
   - Test injected provenance writer failure rolls back created bundles and the
     demultiplex manifest.

2. Add `Tests/LungfishCLITests/FastqImportONTProvenanceTests.swift`.
   - Test `FastqImportONTSubcommand` still writes argv, defaults, resolved
     options, runtime identity, and final output descriptors through the new
     workflow path.

3. Add `Tests/LungfishAppTests/ONTImportOperationCoordinatorTests.swift`.
   - Test the coordinator passes GUI workflow context, records the equivalent
     `lungfish fastq import-ont ...` command, updates progress, and completes
     Operation Center with created bundle URLs.

4. Run the focused tests before production code and capture the failing output:
   `swift test --filter 'ONTImportWorkflowTests|FastqImportONTProvenanceTests|ONTImportOperationCoordinatorTests'`

Red output will be appended below after the tests are written and before
production implementation.

## Implementation Plan

1. Create `Sources/LungfishWorkflow/Ingestion/ONTImportWorkflow.swift`.
   - Define `ONTImportWorkflow.Context` for workflow/tool identity, caller kind,
     argv, durable replay argv, reproducible command, explicit/default/resolved
     options, runtime identity, and optional stderr.
   - Define `ONTImportWorkflow.Result` that wraps `ONTImportResult`, detected
     layout details, root provenance URL, and bundle provenance URLs.
   - Inject `ONTDirectoryImporter` and a provenance writer closure for tests.
   - Detect layout before import, run `importDirectory`, build
     `ProvenanceEnvelope` with `ProvenanceRunBuilder`, write root provenance to
     the output directory, then write the same envelope to each created bundle so
     `ProvenanceWriter` creates focused bundle sidecars.
   - Roll back created bundle directories and `demultiplex-manifest.json` if
     provenance writing fails.

2. Modify `Sources/LungfishCLI/Commands/FastqCommand.swift`.
   - Keep validation, layout summary, progress lines, and final summary.
   - Build CLI command context equivalent to the current inline provenance.
   - Replace inline `CLIProvenanceSupport.recordSingleStepRun` with
     `ONTImportWorkflow.importDirectory`.

3. Create `Sources/LungfishApp/Services/ONTImportOperationCoordinator.swift`.
   - Accept `OperationCenter`, `ONTImportWorkflow`, optional route context, and
     output callbacks.
   - Build the same visible CLI command string as the current GUI path.
   - Start an ingestion operation, call the workflow with caller kind `gui`,
     forward progress to Operation Center, complete with bundle URLs, and fail
     the operation on errors.

4. Modify `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`.
   - Keep the existing unclassified prompt and viewer progress UI.
   - Replace the detached direct `ONTDirectoryImporter.importDirectory` call with
     `ONTImportOperationCoordinator`.
   - Preserve sidebar reload, drop completion notification, first-bundle display,
     and alert behavior.

5. Run focused tests after each green step and keep edits scoped to Slice A.

## Verification Commands

- `swift test --filter 'ONTImportWorkflowTests|ONTDirectoryImporterTests'`
- `swift test --filter 'FastqImportONTProvenanceTests|ONTImportOperationCoordinatorTests'`
- `swift build --product lungfish-cli`
- `swift build --product Lungfish`
- `git diff --check`

## Residual Risks

- Existing signing configuration may add provenance signature sidecars in some
  environments; tests should assert required canonical/focused provenance rather
  than exact directory listings.
- `FASTQBundle.resolvePrimaryFASTQURL(for:)` can return `source-files.json` for
  virtual imports, so tests should verify final bundle-owned payload descriptors
  and not assume `reads.fastq.gz`.
- GUI tests should use an injected `OperationCenter` and workflow closure to
  avoid AppKit window dependencies; `MainSplitViewController` behavior remains
  covered by narrow routing changes plus build verification.
- Rollback covers bundles and the manifest created by this import. It will not
  remove unrelated pre-existing files in the output directory.

## Red-Test Output

Pending. This section will be updated after the red tests are added and run.
