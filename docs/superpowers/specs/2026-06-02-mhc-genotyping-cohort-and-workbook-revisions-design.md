# MHC Genotyping Cohorts and Workbook Revisions Design

## Summary

Selecting multiple FASTQ bundles for MHC amplicon genotyping should create a cohort result by genotyping each selected source independently, then merging the per-source genotype outputs into one displayable `.lungfishgenotype` bundle. The current behavior passes every selected FASTQ bundle into one `lungfish-cli fastq genotype` command and one `minimap2 -x sr` invocation, which fails for more than two short-read query files and does not match the expected per-sample workflow.

The generated Excel workbook in a `.lungfishgenotype` bundle should remain a managed report artifact, not the canonical genotype data source. Lungfish should support collaborator-edited `.xlsx` files through a provenance-recorded workbook revision workflow that promotes an imported workbook as the current report artifact while retaining previous workbook versions.

## Goals

- Run multi-FASTQ MHC genotyping as a cohort of independent source/sample jobs.
- Keep every minimap2 short-read invocation scoped to one logical sample input, with no more than one single-end FASTQ or one R1/R2 pair.
- Produce one final `.lungfishgenotype` cohort bundle that native Lungfish views can display and analyze.
- Preserve reproducibility provenance for child sample runs and the parent cohort merge.
- Allow users to import a revised Excel workbook artifact while retaining prior workbook revisions.
- Make clear that imported workbook revisions do not alter canonical genotype calls, CSV summaries, run stats, haplotype analysis, or analyst annotations.

## Non-Goals

- Do not parse collaborator-edited Excel workbooks back into genotype calls in this feature.
- Do not rely on Excel for Mac local file history for Lungfish bundle artifact recovery.
- Do not silently overwrite the generated workbook without retaining a prior copy and provenance.
- Do not change the single-source ONT barcode-demux or Illumina genotyping experience beyond routing through compatible request types.

## Current Genotyping Behavior

The app creates one `ONTBarcodeDemuxGenotypingRunRequest` whose `inputFASTQURLs` contains every selected FASTQ bundle. `WorkflowOperationExecutionService.ontGenotypingArguments(for:)` serializes that request as:

```sh
lungfish-cli fastq genotype <bundle-1> <bundle-2> ... <bundle-n> --mode illumina-paired ...
```

The CLI forwards all positional inputs into one `ONTBarcodeDemuxGenotypingPipeline.run` call. In Illumina mode, `prepareIlluminaInputs` stages one sample-prefixed FASTQ per selected bundle and returns all staged FASTQs as `mappingFASTQURLs`. `runMapping` then appends every staged FASTQ to one `minimap2 -x sr` command. Minimap2 short-read mode accepts at most two query files, so the command fails when the cohort has more than two source bundles.

Relevant files:

- `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift`
- `Sources/LungfishApp/Services/WorkflowOperationExecutionService.swift`
- `Sources/LungfishCLI/Commands/FastqGenotypingSubcommand.swift`
- `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`

## Cohort Genotyping Design

Add an explicit cohort workflow layer with this stable CLI surface:

```sh
lungfish-cli fastq genotype-cohort <bundle-1> <bundle-2> ... <bundle-n> \
  --mode illumina-paired \
  --read-type illumina \
  --reference <reference> \
  --output-dir <final.lungfishgenotype> \
  --output-name <name> \
  [shared genotyping options]
```

The app should use this cohort command whenever the user selects more than one FASTQ bundle for MHC genotyping. A single selected bundle should continue to use the existing `fastq genotype` path unless the implementation naturally reuses the cohort service for one item without changing behavior.

### Execution Model

1. Validate the selected FASTQ bundles, reference, haplotype settings, comparison workbook, and output location once at the cohort level.
2. Create a hidden support directory inside the final output bundle, such as `.amplicon-genotyping/cohort-runs/`.
3. For each selected source bundle, create one child output directory under the support directory.
4. Run the existing single-source genotyping pipeline for each child with:
   - one source bundle as the child input;
   - the same reference and shared options;
   - an output name derived from the cohort output and source sample ID;
   - child provenance written into the child output.
5. Merge the child genotype outputs into the final top-level `.lungfishgenotype` bundle:
   - concatenate long summary CSV rows with one header;
   - concatenate sample summary CSV rows with one header;
   - aggregate stats JSON by summing count fields and recomputing percentages from summed denominators;
   - regenerate or merge haplotype analysis using the final merged call set and selected haplotype definition;
   - generate one final workbook from the merged CSV/stats/haplotype artifacts;
   - write one final manifest pointing at the final top-level artifacts.
6. Remove heavy child alignment intermediates according to the existing policy for generated BAM/BAI intermediates. Retain child manifests, CSVs, stats JSON, workbooks, and provenance in the support directory because they are scientific provenance inputs to the merge.

### Failure Behavior

- If any child genotyping run fails, the cohort operation fails and reports the failed sample/source bundle.
- Completed child runs should remain in the support directory only when useful for diagnostics and clearly marked as partial; the final top-level manifest must not be written unless the final cohort merge succeeds.
- The operation log should show child progress, including the current sample index and sample ID.
- If the merge or provenance write fails, roll back the top-level final artifacts and manifest.

### Provenance

The final cohort bundle must satisfy the Lungfish provenance requirements.

Child run provenance must include:

- child workflow/tool name and version;
- exact child argv or reproducible command;
- user-visible options and resolved defaults;
- conda/runtime identity;
- source bundle path and resolved FASTQ payload paths;
- reference, comparison workbook, haplotype definition, and other inputs;
- minimap2/samtools/filter/report commands with stderr, exit status, wall time;
- file checksums and sizes for child outputs.

Parent merge provenance must include:

- cohort workflow/tool name and version;
- exact cohort argv or reproducible command;
- selected source bundle list;
- child output bundle paths;
- child provenance paths and checksums;
- merge options and resolved defaults;
- final top-level output paths, checksums, and sizes;
- runtime identity, exit status, wall time, and useful stderr.

The final canonical provenance envelope should point at final stored payloads and retained child provenance inputs, not temporary staging paths that are removed.

### UI Behavior

- Selecting multiple FASTQ bundles should enable MHC genotyping.
- The run dialog should label the run as a cohort when more than one source bundle is selected.
- The command preview should show `fastq genotype-cohort` for multi-source runs.
- The completed operation should select the final cohort `.lungfishgenotype` bundle.
- The Inspector should show cohort-level sample counts and artifacts from the final merged bundle.

## Workbook Revision Design

Excel `.xlsx` output is currently one primary artifact referenced by `ONTGenotypeResultBundleManifest.primaryWorkbookPath`. Native Lungfish display loads genotype calls from the long summary CSV, sample summary CSV, stats JSON, haplotype analysis JSON, and annotation sidecar. Therefore, importing an edited workbook should change the workbook artifact Lungfish opens and shares, but should not change canonical genotype data.

### Excel Versioning Assumption

Excel for Mac Version History is a Microsoft 365 feature for files stored in OneDrive or SharePoint. Microsoft documents that AutoSave is disabled for local paths. Apple and Numbers support macOS document versions for Numbers spreadsheets, but Lungfish should not rely on that behavior for local `.xlsx` artifacts inside a `.lungfishgenotype` bundle.

References:

- Microsoft: `https://support.microsoft.com/en-us/office/view-previous-versions-of-office-files-5c1e076f-a9c9-41b8-8ace-f77b9642e2c2`
- Microsoft: `https://support.microsoft.com/en-us/office/what-is-autosave-6d6bd723-ebfd-4e40-b5f6-ae6e8088f7a5`
- Apple: `https://support.apple.com/en-mide/guide/mac-help/mh40710/mac`
- Apple Numbers: `https://support.apple.com/en-au/guide/numbers/tan7f1de6ec5/mac`

### Manifest Model

Extend `ONTGenotypeResultBundleManifest` in a backward-compatible way:

```swift
public let currentWorkbookPath: String?
public let workbookRevisions: [ONTGenotypeWorkbookRevision]?
```

`primaryWorkbookPath` remains the generated workbook path for old bundles and compatibility. `currentWorkbookPath` is the workbook Lungfish should reveal, Quick Look, and include when the user asks for the current workbook artifact. If `currentWorkbookPath` is absent, readers use `primaryWorkbookPath`.

Each revision record should include:

- stable revision ID;
- role: generated, imported, or restored;
- relative path inside the bundle;
- user-visible label;
- source filename for imports;
- imported/restored timestamp;
- imported/restored user;
- predecessor revision ID or path;
- SHA-256 checksum;
- file size;
- provenance path.

Store revision files under a bundle-owned path such as:

```text
artifacts/workbooks/<timestamp>-<safe-label>.xlsx
```

### Import Revised Workbook Flow

Add a UI action named `Import Revised Workbook...` in the genotype result artifact area.

Confirmation text:

```text
This changes the Excel report Lungfish opens and shares. It does not change genotype calls, CSV summaries, stats, haplotype analysis, or analyst annotations. The current workbook will be retained in Workbook History.
```

On confirmation:

1. Validate that the selected file is an `.xlsx` file that can be opened as a ZIP/OpenXML workbook.
2. Copy it into the bundle revision directory using an atomic temporary file and final rename.
3. Add a workbook revision entry.
4. Set `currentWorkbookPath` to the new revision path.
5. Write workbook-revision provenance.
6. Rewrite the manifest atomically.
7. Refresh the Inspector and any Quick Look workbook view.

If any step fails, restore the old manifest/current workbook state.

### Workbook History UI

The Inspector should show:

- current workbook row;
- generated workbook row;
- imported revision rows with timestamp and user;
- reveal/open actions for each stored revision;
- restore action for an older revision.

Restoring an older revision should create a new `restored` revision event/provenance record that points `currentWorkbookPath` back to the retained workbook. It should not delete the later revision.

### Workbook Provenance

Workbook import/restore provenance must include:

- workflow/tool name and version;
- exact app/CLI action and reproducible command if invoked from CLI;
- old current workbook path, checksum, and size;
- imported source workbook path, checksum, and size;
- new stored workbook path, checksum, and size;
- updated manifest path/checksum;
- user-visible options and defaults;
- runtime identity;
- exit status, wall time, and stderr or validation failure details when useful.

## Testing Strategy

### Cohort Genotyping

- Add a workflow regression test with a fake minimap2 that fails if `-x sr` receives more than two query files; selecting three source bundles must produce three child minimap2 invocations, each within the query limit.
- Add a regression test that exactly two selected source bundles are not treated as the R1/R2 query files of one sample.
- Add app execution tests verifying multi-source MHC genotyping uses the cohort command/request, not a single `fastq genotype` request with multiple selected source bundles.
- Add merge tests proving two child genotype bundles produce one displayable final bundle with combined calls, samples, stats, workbook, and haplotype analysis.
- Add provenance tests for child and parent envelopes, including child provenance checksums and final output paths.

### Workbook Revisions

- Load old bundles with only `primaryWorkbookPath`.
- Import a revised workbook and verify `currentWorkbookPath` changes while `primaryWorkbookPath` remains the generated workbook.
- Verify the previous workbook remains stored and listed in history.
- Verify native genotype calls, sample counts, stats, and annotations do not change after workbook import.
- Verify provenance includes old/new workbook checksums and no removed temporary paths.
- Force provenance or manifest write failure and verify rollback.
- Verify Quick Look/reveal targets use the current workbook.

## Implementation Choices

- Child cohort runs should execute sequentially in the first implementation to keep progress, logging, and conda tool contention simple.
- The multi-source workflow should use a new `fastq genotype-cohort` CLI subcommand. A separate subcommand is clear in logs and avoids overloading current positional input semantics.
- Child workbooks should be retained in the support directory along with child CSVs, stats, manifests, and provenance. Heavy child BAM/BAI intermediates should still follow the existing removal policy.

## Recommended First Implementation

Implement `lungfish-cli fastq genotype-cohort` as the authoritative multi-source entry point. Route the app to that command for multi-source selections. Keep the first version sequential and provenance-heavy. Add workbook revision support as a separate implementation plan after cohort genotyping, because it changes manifest compatibility, artifact UI, and provenance for user-managed report artifacts.
