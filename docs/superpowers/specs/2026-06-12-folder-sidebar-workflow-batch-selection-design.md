# Folder Sidebar Workflow Batch Selection Design

## Context

Workflow Operations currently resolves read inputs from concrete bundle rows selected in the left sidebar. Selecting a folder row contributes only the folder URL, which is not an eligible read bundle, so workflows behave as if no read bundle was selected.

Users organize FASTQ bundles into folders and expect selecting a folder to be equivalent to selecting all eligible bundle rows directly inside that folder. The behavior must remain reproducible: workflow requests and CLI previews must contain concrete bundle paths, not folder shortcuts.

## Approved UX Semantics

Folder rows are selection shortcuts. They expand into concrete `.lungfishfastq` bundle URLs before the workflow operation is configured or launched.

One selected folder processes all eligible FASTQ bundles directly inside that folder as one batch. It does not traverse subfolders by default.

Multiple selected folders are combined into one deduplicated batch. The operation behaves like the user selected every eligible direct bundle child across those folders plus any explicit selected bundle rows.

A selected parent folder with eligible bundles in subfolders processes only direct eligible bundle children by default. The Workflow Operations input section exposes an `Include subfolders` checkbox when descendant folder bundles exist. Enabling it recursively includes eligible FASTQ bundles in descendant folders and flattens them into the same batch.

Recursive expansion traverses user folder/project rows only. It must not walk inside bundle rows. This preserves the "same as selecting visible files in the folder" model and avoids accidentally including demux or derivative bundle children nested under a selected FASTQ bundle.

## UI Design

The existing Workflow Operations window remains the main confirmation surface. No separate preflight modal is needed for normal folder selections.

The existing `FASTQ Bundles` input area shows a concise resolved-input summary:

- `Folder "Runs" expands to 12 eligible FASTQ bundles.`
- `3 folders selected: 42 eligible FASTQ bundles. They will run as one batch.`
- `18 FASTQ bundles selected from 2 folders and 3 explicit bundles.`

When descendant bundles are available but not included, the section also shows:

- `Subfolders contain 9 additional eligible FASTQ bundles.`
- Checkbox label: `Include subfolders`
- Help text: `When enabled, all eligible bundles in descendant folders are added to this batch.`

When a selected folder contributes no direct bundles:

- `No eligible FASTQ bundles were found directly in "Runs".`
- If descendants exist: `Subfolders contain 9 eligible FASTQ bundles. Enable "Include subfolders" to use them.`

When duplicates are removed:

- `Skipped 4 duplicate bundles already included by another selected item.`

The details list should be available as real text rather than color-only feedback, with rows formatted relative to the project when possible.

## Scope

This change targets the Workflow Operations path:

- `AppDelegate.showWorkflowOperations(_:)`
- `WorkflowOperationsWindowController`
- `WorkflowOperationDialogState`
- `WorkflowOperationsDialog`

The shared low-level FASTQ/FASTA Operations dialogs may keep their current selection behavior in this slice unless the implementation finds a trivial shared resolver hook. The acceptance criteria are for Workflow Operations.

Imported workflow packages currently bind only the first read bundle into a local workflow parameter map. Folder batches must not silently drop read bundles for packages. If a package workflow is selected while more than one read bundle is resolved, the Run button is disabled with explicit readiness text. Built-in workflow operations continue to support folder batches.

## Architecture

Add a small testable resolver in `Sources/LungfishApp/Services/WorkflowSidebarInputSelection.swift`. It accepts selected `SidebarItem` values and returns a value model containing direct-mode read URLs, recursive-mode read URLs, folder counts, explicit bundle counts, duplicate counts, descendant availability, and user-facing summary strings.

`AppDelegate.showWorkflowOperations(_:)` will build this selection model from `sidebarController.selectedItems()` and pass it to `WorkflowOperationsWindowController.show(...)`.

`WorkflowOperationDialogState` will store the optional selection model and an `includeSubfolderBundles` boolean. Toggling the boolean recalculates `selectedReadURLs` from the model. Existing request builders continue to receive only concrete bundle URLs, preserving CLI/provenance reproducibility.

`WorkflowOperationsDialog` will render the resolver summary in the existing `FASTQ Bundles` section and show the `Include subfolders` checkbox only when the resolver reports additional descendant bundles.

## Provenance Requirements

No workflow command may receive a folder URL as a scientific input. All launch requests produced by this feature must contain concrete `.lungfishfastq` bundle URLs after expansion and deduplication. Existing CLI provenance then records the reproducible command with exact input paths, file sizes, checksums, exit status, runtime, and stderr where available.

The UI may show folder-origin context, but the reproducibility source of truth remains the concrete argv and bundle paths passed to the workflow runner.

## Acceptance Criteria

1. Selecting one folder containing two direct `.lungfishfastq` bundles resolves the same two read URLs as selecting both bundles directly.
2. Selecting multiple folders combines all eligible direct bundle children into one deduplicated batch.
3. Selecting a parent folder does not include bundles in subfolders by default.
4. If a selected folder has descendant folder bundles, the dialog exposes `Include subfolders`; enabling it updates `selectedReadURLs` to include those descendant bundles.
5. Folder expansion never recurses into `.lungfishfastq` bundle children.
6. Duplicate bundle URLs from overlapping selections are removed and surfaced in summary text.
7. Built-in workflow launch requests use all resolved bundle URLs.
8. Imported workflow packages are not runnable with more than one resolved read bundle until package array input support exists.
9. Tests cover resolver semantics, dialog state toggling, request construction, package guard behavior, and UI source/queryability for the subfolder checkbox text.

## Out Of Scope

- Independent per-folder workflow runs.
- Persisting folder-origin metadata into a new provenance schema.
- Recursive selection enabled by default.
- Broad FASTQ/FASTA Operations dialog redesign.
- Workflow package multi-read array input support.

## Self Review

No placeholders remain. The design chooses one default for multiple selected folders and one default for parent folder traversal. The architecture keeps folder expansion out of workflow execution and preserves concrete input paths for provenance. The imported-package limitation is explicit rather than silently lossy.
