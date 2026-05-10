# BAM Variant Calling Dialog Design

Date: 2026-04-19
Status: Proposed

## Summary

Introduce a bundle-scoped, CLI-backed BAM variant-calling workflow for viral datasets. The first release exposes three Apple Silicon-installable callers:

- `LoFreq`
- `iVar`
- `Medaka`

The app adds a BAM-native dialog launched from the alignment inspector. The app remains a configuration, readiness, and progress surface only. `lungfish-cli` becomes the execution boundary for caller preflight, pipeline execution, VCF normalization, SQLite import, and bundle track attachment.

The v1 product is intentionally narrow:

- `LoFreq` for short-read viral calling
- `iVar` for primer-trimmed tiled amplicon viral calling
- `Medaka` for Oxford Nanopore viral calling when the BAM preserves enough ONT/basecaller metadata to support Medaka model resolution

This pass does not attempt general germline or somatic variant discovery.

## Goals

- Activate a viral-focused `variant-calling` micromamba pack for Apple Silicon.
- Support exactly the approved v1 callers:
  - `LoFreq`
  - `iVar`
  - `Medaka`
- Launch variant calling from bundle-owned BAM/alignment tracks, not the FASTQ dialog.
- Reuse `DatasetOperationsDialog` so the UX matches the modern classifier and assembler flows.
- Make `lungfish-cli` the canonical execution path.
- Persist real `VCF.gz` plus `.tbi` artifacts for every successful run.
- Import every result into the existing SQLite-backed variant-track system.
- Keep bundle viewing consistent by attaching a normal `VariantTrackInfo` and reloading the bundle on success.
- Record caller, version, parameters, alignment provenance, and reference provenance in SQLite metadata.
- Preserve bundle safety through `OperationCenter` locking, cancellation, and manifest-safe atomic promotion.
- Add TDD and fixture-backed coverage for pack activation, CLI validation, viral import semantics, bundle attachment, and GUI routing.

## Non-Goals

- Do not add general-purpose human germline or somatic callers in v1.
- Do not add `FreeBayes`, `GATK4`, `DeepVariant`, `Clair3`, `VarDict`, `Longshot`, or `Sniffles` in this pass.
- Do not add standalone BAM variant calling outside a loaded reference bundle in v1.
- Do not redesign the FASTQ operations dialog.
- Do not move duplicate marking into this dialog.
- Do not add primer trimming, consensus generation, lineage calling, or post-call annotation workflows to this dialog.
- Do not solve optional-pack deduplication beyond tolerating shared `iVar` ownership.
- Do not silently invent diploid genotype semantics for sample-less viral callsets.
- Do not promise iVar `ANN=` consequence annotations in v1.

## Current State

The repository already contains the main building blocks:

- `PluginPack` defines a dormant `variant-calling` pack but it is not active and still uses the older flat `packages` shape.
- `PluginPack.activeOptionalPacks` currently exposes only `assembly` and `metagenomics`.
- `DocumentCapability.analysisReadyAlignment` already models the sorted/indexed alignment requirement variant calling needs.
- The alignment inspector already owns BAM-facing workflows.
- `DatasetOperationsDialog` already provides the reusable modal shell used by modern operations.
- The true VCF import path already handles helper-based SQLite import, resume, optional post-import materialization, chromosome remapping, duplicate-track replacement, and manifest update, but that orchestration lives in the app target.
- `VariantDatabase.createFromVCF` is shared code, but its current no-sample fallback creates synthetic sample rows and synthetic `1/1` genotype rows that are misleading for viral AF-first callsets.
- Bundle variant browsing is already SQLite-first, with file-path fallbacks only when no database exists.

This means the new work is primarily about:

1. activating the right tool pack,
2. moving resilient variant import/attach orchestration behind `lungfish-cli`,
3. defining viral-specific import semantics, and
4. adding a BAM-native inspector dialog.

## Tool Selection And Pack Strategy

### Included In V1

The active `variant-calling` pack should expose exactly these three tools:

- `LoFreq`
- `iVar`
- `Medaka`

`samtools`, `bcftools`, `bgzip`, and `tabix` continue to come from the required setup pack.

### Selection Rationale

- `LoFreq` is the clearest short-read viral caller in scope.
- `iVar` is an explicit requirement and is the amplicon-specific viral path.
- `Medaka` covers the approved ONT viral path without broadening v1 into generic long-read variant calling.

### Explicit Deferrals

- `FreeBayes`, `GATK4`, `DeepVariant`, `Clair3`, `VarDict`, `Longshot`, and `Sniffles` are solver-valid locally on Apple Silicon but not part of the approved viral-first surface.
- `Octopus` is excluded because the local Apple Silicon micromamba solve failed.

### Pack Ownership

The new active `variant-calling` pack should own the three v1 callers even though `iVar` already appears in `amplicon-analysis`.

For v1, duplicate ownership is acceptable because:

- readiness is executable-based,
- environment names remain stable, and
- pack deduplication is broader than this feature.

The pack description should be narrowed from generic variant discovery to viral BAM variant calling.

## User-Facing Scope

### Entry Point

Add `Call Variants…` to the alignment inspector near the existing BAM workflows.

The action is enabled only when:

- a reference bundle is loaded,
- the bundle has at least one analysis-ready alignment track, and
- the bundle exposes a reference genome and index.

### Dialog Model

The workflow uses a dedicated BAM/alignment dialog built on `DatasetOperationsDialog`.

It should not reuse `FASTQOperationDialogState`. Instead it defines BAM-specific state for:

- selected alignment track id
- selected caller id
- output track display name
- caller-specific options
- readiness messages
- required acknowledgements
- the prepared CLI request payload

There is no standalone output-directory mode in v1. The target is always the selected bundle.

### Tool Sidebar

The sidebar exposes exactly three tools:

- `LoFreq`
- `iVar`
- `Medaka`

Availability rules:

- if the `variant-calling` pack is unavailable, all tools remain visible but disabled with `Requires Variant Calling Pack`
- if the pack is available, the tools become selectable

### Detail Pane Sections

The detail pane follows the same structure as the modern operations shell:

1. `Overview`
2. `Inputs`
3. `Primary Settings`
4. `Advanced Settings`
5. `Output`
6. `Readiness`

### Output Naming And Rerun Semantics

Every launch creates a new track id and a new artifact set. v1 does not implicitly replace an existing track by name.

- `trackId` is generated independently of the display name and is used for filenames.
- `track name` is user-editable display text.
- if the default display name already exists, the dialog auto-suffixes it (`(2)`, `(3)`, ...).

Default display names:

- `<alignment-track-name> • LoFreq`
- `<alignment-track-name> • iVar`
- `<alignment-track-name> • Medaka`

## Bundle And Caller Preconditions

### Bundle Scope

The initial GUI and CLI surface is bundle-scoped only. The canonical v1 CLI inputs are:

- `--bundle <bundle path>`
- `--alignment-track <track id>`
- `--caller <lofreq|ivar|medaka>`

This avoids duplicating reference-resolution and attach logic for arbitrary BAM paths.

### Required Preflight Matrix

Every run must pass a concrete CLI preflight before any caller executes.

Common checks:

- the bundle exists and loads
- the alignment track exists in the manifest
- the alignment is sorted and indexed
- the bundle exposes a reference genome and index
- the `variant-calling` pack is installed
- BAM `@SQ` contigs match the bundle reference after alias normalization
- BAM `@SQ` lengths match the bundle reference lengths exactly
- if BAM `@SQ M5` checksums are present, they match checksums computed from the staged reference sequences

Caller-specific checks:

- `LoFreq`
  - no extra biological gate beyond the common BAM/reference checks
- `iVar`
  - requires explicit confirmation that the alignment is primer-trimmed, unless existing provenance can prove primer trimming
- `Medaka`
  - requires evidence that the BAM came from ONT data
  - requires CLI-side inspection proving the BAM preserves enough ONT/basecaller metadata for Medaka model resolution
  - if that proof cannot be established, Medaka is blocked rather than run optimistically

### Reference Staging Rule

Bundle references are stored as `genome/sequence.fa.gz`. v1 should not assume every caller accepts that form directly.

The CLI should always stage an uncompressed temporary reference FASTA plus any required indexes for caller execution. Viral bundles are small enough that this avoids tool-specific ambiguity without meaningful cost.

## CLI-Backed Architecture

### Command Surface

Add a new CLI family:

- `lungfish-cli variants call`

The command owns bundle-scoped variant calling for the three supported callers.

### App Responsibility

The GUI only:

- collects configuration
- performs obvious UI validation
- starts the CLI-backed run
- forwards progress into `OperationCenter`
- reloads the bundle on success
- surfaces actionable failures

The app must not implement caller pipelines itself.

### OperationCenter Integration

Bundle-mutating variant calls must use the existing long-running operation system.

The inspector launch path must:

- register an `OperationCenter` item before the CLI starts
- set `operationType` to a new variant-calling-appropriate value or reuse a clearly named existing type only if it truly fits
- lock `targetBundleURL`
- expose cancellation through `onCancel`
- keep the run visible in the Operations Panel even though it started from an inspector sheet

Variant calling is not allowed to bypass bundle locking.

### CLI Responsibility

The CLI should:

- resolve the bundle and alignment track
- run the full preflight matrix
- stage the reference and caller workspace
- run the selected caller pipeline
- normalize the result into sorted `VCF.gz` plus `.tbi`
- import the normalized VCF into SQLite using the resilient helper/resume/materialization flow
- attach the new track to the bundle manifest
- emit structured progress and final result payloads

### Structured Progress Contract

`lungfish-cli variants call --format json` should emit one JSON object per line to stdout with an `event` field.

Required v1 events:

- `runStart`
- `preflightStart`
- `preflightComplete`
- `stageStart`
- `stageProgress`
- `stageComplete`
- `importStart`
- `importComplete`
- `attachStart`
- `attachComplete`
- `runComplete`
- `runFailed`

Every event includes a human-readable message. Progress-bearing events also include a normalized fraction in `[0, 1]`.

`runComplete` includes at minimum:

- bundle path
- variant track id
- variant track name
- caller
- persisted VCF path
- persisted TBI path
- persisted SQLite path
- imported variant count

## Shared Import And Attachment Architecture

### Why A Two-Part Extraction Is Required

The current app-side `performVCFImport` flow is not a thin wrapper around `VariantDatabase.createFromVCF`. It already owns:

- helper-based import subprocess execution
- resume of interrupted indexing
- resume of interrupted materialization
- chromosome remapping
- duplicate-track handling
- manifest mutation

The CLI path must preserve that resilience instead of replacing it with a simplified one-shot import.

### Shared Responsibilities

Split the work into two shared pieces:

1. `VariantSQLiteImportCoordinator`
   - owns normalized-VCF to SQLite import
   - preserves the current helper/resume/materialization behavior
   - runs in a CLI-visible layer rather than only inside the app target

2. `BundleVariantTrackAttachmentService`
   - owns provenance writes, chromosome remapping, artifact promotion, duplicate-safe manifest update, and rollback on failure

The CLI command composes these two pieces. The app only launches and observes them.

### Persisted Artifact Layout

New variant tracks use real file paths, not placeholder BCF paths:

- `variants/<track-id>.vcf.gz`
- `variants/<track-id>.vcf.gz.tbi`
- `variants/<track-id>.db`

The attached `VariantTrackInfo` must point at those real artifact paths.

### Provenance Storage

Required `db_metadata` keys:

- `variant_caller`
- `variant_caller_version`
- `variant_caller_parameters_json`
- `source_alignment_track_id`
- `source_alignment_track_name`
- `source_alignment_relative_path`
- `source_alignment_checksum_sha256`
- `reference_bundle_id`
- `reference_bundle_name`
- `reference_staged_fasta_sha256`
- `artifact_vcf_path`
- `artifact_tbi_path`
- `call_semantics`
- `created_at`

For v1, `call_semantics` should be `viral_frequency`.

Manifest-level fields:

- `source`: caller display name
- `version`: caller version string when available

### Viral Import Semantics

The shared SQLite import path must add an explicit viral import mode for sample-less caller outputs.

For `LoFreq`, `iVar`, and `Medaka` sample-less VCFs:

- do not create synthetic sample rows
- do not create synthetic `1/1` genotype rows
- leave `sample_count` at `0`
- still import INFO fields and structured INFO expansions normally

The viewer must treat these tracks as sample-less viral callsets rather than synthetic diploid callsets.

## Caller Pipelines

### Common Tail

All three caller pipelines converge on the same tail:

1. run caller-specific work in staging
2. obtain caller-native VCF or normalize caller output into VCF without inventing new semantics
3. sort with `bcftools sort`
4. compress with `bgzip`
5. index with `tabix -p vcf`
6. import the normalized VCF into staged SQLite via the resilient coordinator
7. promote the completed `VCF.gz`, `.tbi`, and `.db`
8. attach the track to the bundle

All final artifacts are staged first and promoted only after the normalized VCF, index, and SQLite database are complete.

### LoFreq

`LoFreq` is the short-read viral path.

The v1 pipeline should:

- use the selected bundle alignment track as input
- use the staged reference FASTA
- default to `lofreq call-parallel`
- support caller threads

Indel handling:

- v1 exposes `Include Indels`
- if indel calling is enabled and the BAM lacks indel-quality tags, the pipeline runs `lofreq indelqual` in staging first
- if indel preparation fails, the run stops with an actionable error rather than silently dropping indels

`LoFreq` already emits VCF, so this path only needs normalization and import after calling.

### iVar

`iVar` is the tiled amplicon viral path.

The v1 pipeline should:

- run `samtools mpileup` on the selected BAM against the staged reference
- pipe that into `ivar variants`
- request native VCF output with `--output-format vcf`

Important v1 limits:

- v1 does not perform primer trimming
- launch is blocked until the user confirms the alignment is primer-trimmed, unless provenance already proves it
- v1 does not pass `-g <annotations.gff3>` and therefore does not promise `ANN=` consequence annotations

This avoids a custom TSV-to-VCF translation path and keeps iVar output scientifically aligned with the caller's native VCF representation.

### Medaka

`Medaka` is the ONT viral path.

The BAM remains the primary source, but the pipeline must not use naive `samtools fastq -T '*'` reconstruction because that can silently drop read classes.

Instead, v1 should:

- use the shared `BAMToFASTQConverter` to reconstruct a single FASTQ without losing READ1, READ2, READ_OTHER, or singleton classes
- run Medaka only after CLI preflight proves the BAM preserves enough ONT/basecaller metadata for Medaka model resolution
- use the staged reference FASTA

Important v1 limit:

- v1 does not expose manual Medaka model selection in the dialog because the current bundle/alignment model does not durably preserve enough model provenance to make that safe

If Medaka cannot prove model-resolvable input from the BAM, the run must fail at preflight with an actionable message. It must not attempt a best-guess execution.

## GUI State And Routing

### Presenter

Add a dedicated presenter that mirrors the FASTQ presenter shape:

- create dialog state from the loaded bundle context
- host the SwiftUI dialog in an `NSPanel`
- return the prepared CLI request to the inspector controller

### Inspector Wiring

`InspectorViewController` should own:

- launch validation
- dialog presentation
- `OperationCenter` registration
- CLI run kickoff
- progress updates
- bundle reload on success
- alert presentation on failure

This keeps BAM workflows consistent in one controller family.

## Error Handling And Recovery

### Failure Types

The CLI should map failures into typed categories:

- missing bundle
- missing alignment track
- missing reference or reference index
- BAM/reference mismatch
- missing variant-calling pack
- caller-specific preflight failure
- caller execution failure
- VCF normalization failure
- SQLite import failure
- manifest update failure
- cancellation

### Actionable Messages

Examples:

- `Variant Calling Pack is not installed. Install it from Plugin Manager and retry.`
- `This BAM does not prove primer-trimmed amplicon processing. Confirm primer trimming or choose a different caller.`
- `Medaka could not verify ONT/basecaller metadata in this BAM. Use a BAM that preserves ONT model information or choose a different caller.`
- `The BAM header contigs do not match this bundle's reference genome. Re-import the alignment against the correct bundle reference.`

### Atomicity

No partially completed run may mutate the live manifest.

The sequence is:

1. stage reference and caller workspace
2. generate staged normalized `VCF.gz` and `.tbi`
3. build the staged SQLite DB
4. promote completed artifacts into `variants/`
5. create `VariantTrackInfo` pointing at final paths
6. save the updated manifest

If manifest save fails after artifact promotion, the promoted files must be removed before returning the error.

### Cancellation

Cancellation must:

- terminate the running CLI subprocess
- terminate any child helper process used for SQLite import or materialization
- remove staged artifacts
- preserve the existing manifest
- unlock the bundle through `OperationCenter`

## Testing Strategy

### Pack And Tool Tests

Add tests for:

- activation and metadata of the `variant-calling` pack
- `PackToolRequirement` definitions for `lofreq`, `ivar`, and `medaka`
- readiness evaluation for ready and missing-tool cases
- `NativeTool` and `NativeToolRunner` coverage for the new managed executables

### CLI Tests

Add tests for:

- `lungfish-cli variants call` argument validation
- bundle and alignment-track resolution
- the BAM/reference preflight matrix
- iVar primer-trim acknowledgement gating
- Medaka metadata gating
- JSON event order and payload shape
- typed failure mapping

### Shared Import Tests

Add tests for:

- normalized VCF import into SQLite
- helper/resume/materialization orchestration from the CLI-visible import coordinator
- chromosome remapping against bundle chromosome names
- provenance metadata writes
- real `VCF.gz`/`.tbi`/`.db` manifest paths
- rollback on manifest-save failure

### Viral-Semantics Tests

Add tests proving that sample-less viral caller VCFs:

- create no synthetic sample rows
- create no synthetic genotype rows
- retain INFO field import and structured INFO expansion
- remain queryable and viewable as sample-less tracks

### Caller Fixture Tests

Use fixture-backed adapter tests rather than full external inference runs:

- a `LoFreq`-style VCF fixture entering normalization and attach
- an `iVar` native VCF fixture entering normalization and attach
- a `Medaka` VCF-style fixture entering normalization and attach
- a Medaka-negative fixture proving missing ONT metadata blocks launch

### App Tests

Add tests for:

- inspector routing to the new dialog
- dialog readiness for pack-missing and alignment-missing cases
- `OperationCenter` registration and cancellation wiring
- success-path bundle reload behavior

## Review Gate Notes

This revised spec intentionally closes the major issues found in expert review:

- variant calling is required to use `OperationCenter` bundle locking
- the import architecture preserves helper/resume/materialization instead of replacing it with a thin attach helper
- iVar uses native VCF output, not TSV reconstruction
- iVar primer-trim safety is a launch gate, not just a warning
- Medaka is narrowed to BAMs that prove ONT/model-resolvable metadata
- viral sample-less callsets import without synthetic diploid genotype rows
- artifact paths are real `VCF.gz`/`.tbi` paths, not placeholder BCF paths
