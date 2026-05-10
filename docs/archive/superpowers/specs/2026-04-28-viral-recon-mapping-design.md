# Viral-recon in FASTQ/FASTA Mapping Operations Design

Date: 2026-04-28
Status: Approved design, pending implementation plan

## References

- nf-core/viralrecon usage documentation: https://nf-co.re/viralrecon/usage
- nf-core/viralrecon 3.0.0 schema: https://raw.githubusercontent.com/nf-core/viralrecon/3.0.0/nextflow_schema.json
- nf-core/viralrecon 3.0.0 Illumina samplesheet example: https://raw.githubusercontent.com/nf-core/viralrecon/3.0.0/assets/samplesheet_illumina.csv
- nf-core/viralrecon 3.0.0 Nanopore samplesheet example: https://raw.githubusercontent.com/nf-core/viralrecon/3.0.0/assets/samplesheet_nanopore.csv

## Context

The current generic nf-core app surface adds a top-level `Tools > nf-core Workflows...` item backed by `NFCoreWorkflowDialogController`, `NFCoreWorkflowDialogModel`, `NFCoreSupportedWorkflowCatalog`, and tests that make workflows such as `fetchngs` user-visible. That is too generic for Lungfish users and exposes workflows that are not useful in the current app.

Viral-recon should instead be treated as a named operation in the existing `Tools > FASTQ/FASTA Operations > Mapping...` dialog. Users should not have to know that the implementation is nf-core. They should select Lungfish read bundles from the project sidebar/file sidecar, choose SARS-CoV-2 viral analysis settings, and see a normal Operations Panel item with logs, progress, completion, and failure details.

## Goals

1. Add `Viral Recon` as a first-class tool under the FASTQ/FASTA Operations Mapping category.
2. Support selecting and processing multiple `.lungfishfastq` bundles in a single run when all selected bundles use the same supported platform.
3. Support both Illumina and Oxford Nanopore SARS-CoV-2 amplicon data.
4. Build nf-core/viralrecon 3.0.0-compatible samplesheets and parameters from Lungfish bundle metadata and selected `.lungfishprimers` bundles.
5. Run through `lungfish-cli` into a `.lungfishrun` bundle, not by launching Nextflow directly from the app.
6. Propagate preparation, Nextflow output, progress, completion, and failure details into the Operations Panel.
7. Remove the generic nf-core Tools menu category, generic nf-core UI functionality, and associated generic tests.

## Non-goals

- Do not keep `fetchngs` or other generic nf-core workflows visible in the app.
- Do not build a generic nf-core parameter editor.
- Do not support mixed Illumina and ONT samples in one viral-recon run. Viral-recon has a single `--platform` parameter, so mixed selections must be split into separate runs.
- Do not require users to supply raw CSV samplesheets for the normal path. Lungfish generates them from selected bundles.

## User Workflow

1. User selects one or more `.lungfishfastq` bundles in the project sidebar.
2. User opens `Tools > FASTQ/FASTA Operations > Mapping...`.
3. User selects the `Viral Recon` tool in the Mapping sidebar.
4. The Viral Recon pane shows the selected sample bundles, inferred platform, reference, primer scheme, and run parameters.
5. User chooses a SARS-CoV-2 reference source and a `.lungfishprimers` bundle. Built-in primer bundles and project-local `Primer Schemes/*.lungfishprimers` bundles are both available.
6. User starts the run.
7. The app creates a `.lungfishrun` bundle under the project `Analyses/` area, stages generated inputs, starts `lungfish-cli`, and updates the Operations Panel until completion or failure.

## UI Placement

Add a new `FASTQOperationToolID.viralRecon` case:

- `categoryID`: `.mapping`
- `title`: `Viral Recon`
- `subtitle`: `Run SARS-CoV-2 viral consensus and variant analysis.`
- `usesEmbeddedConfiguration`: `true`
- readiness text: `Complete the viral recon settings to continue.`

`FASTQOperationDialogState.toolIDs(for: .mapping)` will return existing mapping tools plus `viralRecon`. `FASTQOperationToolPanes` will route this tool to a new `ViralReconWizardSheet`.

The pane should follow the existing embedded wizard style used by `MappingWizardSheet`, `AssemblyWizardSheet`, and classification panes. It should not present itself as "nf-core". User-visible labels should use "Viral Recon" and "SARS-CoV-2 viral analysis".

## Input Model

Introduce a focused workflow model in `LungfishWorkflow`, separate from generic catalog metadata:

- `ViralReconPlatform`: `.illumina`, `.nanopore`
- `ViralReconProtocol`: `.amplicon` for this increment
- `ViralReconSample`: sample name, source bundle URL, FASTQ URLs, optional barcode, optional sequencing summary
- `ViralReconPrimerSelection`: selected `PrimerSchemeBundle`, resolved BED URL, derived or bundled primer FASTA URL, left/right suffix values
- `ViralReconRunRequest`: samples, platform, reference inputs, primer selection, output directory, executor/profile, version, resource settings, and analysis toggles

The app state will store `pendingViralReconRequest` and `pendingLaunchRequest = .viralRecon(...)` when the embedded pane captures a valid request.

## Multiple Bundle Handling

Multiple selected bundles are first-class, not a batch loop of separate app runs.

For Illumina:

- Each selected `.lungfishfastq` bundle becomes one sample row.
- Resolve FASTQ files with `FASTQBundle.resolveAllFASTQURLs(for:)`.
- If two files are present, write `sample,fastq_1,fastq_2`.
- If one file is present, write `sample,fastq_1,` for single-end Illumina.
- Sample names come from `FASTQSampleMetadata.sampleName` when available, then bundle display name.

For ONT:

- Each selected `.lungfishfastq` bundle becomes one sample row.
- A staging directory is created inside the `.lungfishrun` bundle, shaped like a Nanopore `fastq_pass` directory.
- Each selected sample is assigned or loaded as a barcode. If barcode metadata is present, use it; otherwise assign stable numeric barcodes in selected order and allow user edits before run.
- Write `sample,barcode` samplesheet.
- Pass `--fastq_dir` to the staged `fastq_pass` directory.
- Pass `--sequencing_summary` only when a valid sequencing summary file is discoverable from the bundle or selected by the user.

Mixed Illumina and ONT selections block the Run button with a clear message instructing the user to run the platforms separately.

## Platform Detection

Detection order:

1. Persisted FASTQ metadata (`sequencingPlatform`, `assemblyReadType`, ingestion metadata).
2. FASTQ header inspection through existing `MappingReadClass.detect` and `LungfishIO.SequencingPlatform.detect`.
3. User override in the Viral Recon pane.

The override is retained in the request and logged because platform choice changes the generated samplesheet and viral-recon parameters.

## Primer Scheme Handling

Primer schemes are selected from real `.lungfishprimers` bundles:

- Built-in schemes from `BuiltInPrimerSchemeService.listBuiltInSchemes()`.
- Project-local schemes from `PrimerSchemesFolder.listBundles(in:)`.
- Optional browse/import remains a separate existing workflow; this pane only chooses available bundles.

Validation:

- The selected primer scheme must contain a BED file.
- The selected reference accession or FASTA contig name must match the primer scheme's canonical or equivalent accessions. Existing `PrimerSchemeResolver` behavior should be reused where possible.
- `--primer_bed` is always passed for amplicon runs.
- If the primer bundle includes `primers.fasta`, pass it as `--primer_fasta`.
- If `primers.fasta` is absent, derive it from the selected reference FASTA and primer BED during input staging, then pass the derived FASTA. This supports the built-in QIAseq Direct SARS-CoV-2 bundle whose primer sequences are derivable from reference coordinates.
- Default suffix parameters are `_LEFT` and `_RIGHT`, exposed only in advanced settings.

## Reference Handling

Default SARS-CoV-2 behavior:

- Prefer project or built-in reference assets matching `MN908947.3` or `NC_045512.2`.
- Use `--genome MN908947.3` when the run uses nf-core's known SARS-CoV-2 reference key.
- Use `--fasta` and optional `--gff` when the user selects a local reference bundle or standalone FASTA.

The UI should present the same reference discovery behavior as mapping operations, but filter and annotate candidates that match the selected primer scheme.

## Viral-recon Parameters

Core generated parameters:

- `--input <generated samplesheet>`
- `--outdir <run output directory>`
- `--platform illumina|nanopore`
- `--protocol amplicon`
- reference parameters: `--genome` or `--fasta` plus optional `--gff`
- primer parameters: `--primer_bed`, `--primer_fasta`, `--primer_left_suffix`, `--primer_right_suffix`

Visible controls:

- executor/profile: default Docker, with available existing executor choices
- viral-recon version: default `3.0.0`
- maximum CPUs and memory
- minimum mapped reads: default `1000`
- variant caller: `ivar` default for amplicon
- consensus caller: `bcftools` default
- skip toggles for assembly, Kraken2, FastQC, MultiQC, and other heavy optional outputs

Advanced options accept additional key/value viral-recon parameters, but validation rejects keys that would conflict with generated inputs (`input`, `outdir`, `platform`, `protocol`, `primer_bed`, `primer_fasta`, `fastq_dir`).

## Execution Path

The GUI must not spawn `nextflow` directly.

Execution flow:

1. `ViralReconWizardSheet` captures a validated `ViralReconRunRequest`.
2. `AppDelegate` calls `ViralReconWorkflowExecutionService`.
3. The service allocates a `.lungfishrun` bundle under `Analyses/`.
4. The service writes manifest/provenance, generated samplesheet, staged primer files, staged ONT directories when needed, and a command preview.
5. The service starts an Operations Panel item with a new specific operation type, `viralRecon`.
6. The service launches `lungfish-cli workflow run nf-core/viralrecon --bundle-path <bundle> --version 3.0.0 ...`.
7. `lungfish-cli` owns the Nextflow invocation, updates the run bundle logs, and exits with a code the app can report.

The implementation should keep or adapt narrowly scoped existing `NFCoreRunBundleStore`, `NFCoreRunRequest`, and CLI workflow-run plumbing as internal infrastructure for the direct viral-recon path. The generic catalog, generic dialog, and generic app menu surface should be removed.

## Operations Panel Logging

The Operations Panel must show:

- operation title: `Viral Recon`
- detail: selected platform, sample count, and reference
- log entry for generated samplesheet path
- log entry for selected primer scheme and derived primer FASTA path when derivation occurs
- command preview, with paths shell-escaped
- streamed `lungfish-cli` stdout/stderr lines, including Nextflow process progress when available
- completion detail with output directory and run bundle path
- failure detail with exit code and stderr tail

The run bundle should retain full logs under `logs/`, and the Operations Panel should include enough detail to diagnose common failures without opening the bundle manually.

## Generic nf-core Removal

Remove or retire:

- `Tools > nf-core Workflows...` menu item
- `ToolsMenuActions.showNFCoreWorkflows(_:)`
- generic app dialog/controller/model files
- generic nf-core XCUITest and model/service tests centered on `fetchngs`
- catalog-driven About acknowledgements listing all supported nf-core workflows

Replace the acknowledgement with a specific credit for `nf-core/viralrecon` where appropriate. Do not keep a user-facing "nf-core workflows" category.

## Test Fixtures

Use real fixtures rather than synthetic-only smoke inputs:

- Existing SARS-CoV-2 Illumina fixtures in `Tests/Fixtures/sarscov2`.
- A small ONT SARS-CoV-2 fixture vendored from nf-core/test-datasets or an equivalent public test fixture, with license/provenance noted under `Tests/Fixtures`.
- `.lungfishfastq` bundle fixtures constructed by `LungfishProjectFixtureBuilder`, including multi-bundle projects for Illumina and ONT.
- `.lungfishprimers` bundle fixtures from existing QIAseq and MT192765 primer scheme bundles.

The deterministic UI backend should avoid running the full Nextflow workflow while still verifying that the app creates the expected request, samplesheet, run bundle, operation item, and event log entries.

## Test Coverage

Unit tests:

- Viral-recon Illumina samplesheet builder supports multiple bundles and paired/single-end rows.
- Viral-recon Nanopore samplesheet builder supports multiple bundles, barcode assignment, and staged `fastq_pass` layout.
- Platform detection accepts metadata and header-based detection and rejects mixed-platform runs.
- Primer selection loads built-in and project-local `.lungfishprimers` bundles.
- Primer FASTA derivation works when a scheme contains BED but no FASTA.
- Request-to-CLI argument generation includes viral-recon 3.0.0 parameters and blocks conflicting advanced keys.
- Generic nf-core catalog/menu tests are removed or rewritten to assert the menu item is absent.

App/UI tests:

- `Viral Recon` appears under FASTQ/FASTA Mapping operations.
- The old `nf-core Workflows...` menu item is absent.
- Selecting multiple Illumina bundles produces a single multi-sample run request.
- Selecting multiple ONT bundles produces a Nanopore request with barcode samplesheet.
- Deterministic execution creates a `.lungfishrun` bundle and Operations Panel item with viral-recon logs.

Integration or CLI tests:

- `lungfish-cli workflow run nf-core/viralrecon --prepare-only` writes the run bundle, generated samplesheet, manifest, and command preview.
- The app runner can invoke the CLI deterministic path and capture stdout/stderr into OperationCenter logs.

## Success Criteria

- Users no longer see a generic nf-core category in the Tools menu.
- `Viral Recon` is available inside FASTQ/FASTA Operations Mapping.
- Multiple selected Lungfish FASTQ bundles become one valid multi-sample viral-recon run for a single platform.
- Project-local and built-in `.lungfishprimers` bundles drive `--primer_bed` and `--primer_fasta`.
- The app starts viral-recon through `lungfish-cli` and a `.lungfishrun` bundle.
- Operations Panel status and logs reflect preparation, execution, completion, and failure.
- Tests cover generated inputs with real SARS-CoV-2 Illumina and ONT fixtures.
