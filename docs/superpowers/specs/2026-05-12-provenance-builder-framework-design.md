# Provenance Builder Framework Design

**Date:** 2026-05-12
**Status:** Pending written spec review
**Scope:** Repository-wide provenance recording, reporting, signing, export, and GUI provenance interactions

## Goal

Replace ad hoc provenance recording with a shared provenance builder framework used by every CLI command, workflow runner, app workflow, GUI-imported CLI output, registry action, export, transform, and scientific bundle writer that creates, imports, transforms, exports, or wraps scientific data.

The result should match the provenance and reproducibility contract documented in `docs/user-manual/chapters/01-foundations/08-provenance-and-reproducibility.md`: every relevant output carries a `.lungfish-provenance.json` record with stable schema fields, exact invocations, resolved options, runtime identity, input and output checksums and file sizes, exit status, wall time, stderr when useful, and optional signature artifacts. Missing provenance remains a blocking defect for new scientific surfaces.

## Non-Goals

- Do not replace all existing scientific workflow implementations in this change.
- Do not remove support for decoding existing `WorkflowRun`-shaped provenance sidecars.
- Do not require a real conda environment content hash before this release; record the best available environment, pack, executable, and container identity.
- Do not build cloud signing or sigstore/cosign verification beyond the documented local signature artifacts unless the existing signing abstraction already supports it.
- Do not make GUI workflows rely on temporary CLI staging paths in final provenance records.

## Current State

The repository already has useful primitives:

- `WorkflowRun`, `StepExecution`, and `FileRecord` in `Sources/LungfishWorkflow/Provenance/ProvenanceRecord.swift`.
- `ProvenanceRecorder` in `Sources/LungfishWorkflow/Provenance/ProvenanceRecorder.swift`.
- `ProvenanceExporter` in `Sources/LungfishWorkflow/Provenance/ProvenanceExporter.swift`.
- CLI helpers in `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift`.
- Signed sidecar support in `Sources/LungfishWorkflow/Provenance/ProvenanceSigning.swift`.
- Some registry-level requirements, especially `MultipleSequenceAlignmentActionRegistry`.

Those pieces are not yet sufficient for the release contract. The current encoded sidecar is still primarily `WorkflowRun` shaped. It lacks the documented top-level fields such as `schemaVersion`, `workflowName`, `toolName`, `toolVersion`, `argv`, `reproducibleCommand`, `options.resolvedDefaults`, `runtimeIdentity`, `files`, `output` or `outputs`, `wallTimeSeconds`, and `exitStatus`. Coverage is also inconsistent: many CLI and GUI scientific surfaces record provenance manually or not at all, and large-file checksum handling can emit partial digests where the documentation promises SHA-256 over file contents.

## Architecture

The implementation should introduce five coordinated layers:

1. A canonical provenance envelope for the on-disk JSON schema.
2. A provenance builder API that is the only supported writer for new scientific provenance.
3. Policy and registry gates that identify which operations must produce provenance.
4. Import and rehydration helpers that preserve CLI provenance when the GUI stores outputs in final bundles.
5. Export, report, signing, verification, and GUI presentation paths built on the canonical envelope.

Existing `WorkflowRun` records remain an in-memory compatibility type and an export source. New sidecars should encode the documented canonical envelope while preserving enough legacy field aliases for existing readers and tests to keep working during migration.

## Canonical Envelope

Add a canonical type in `LungfishWorkflow`, tentatively named `ProvenanceEnvelope`, with stable schema version `1`.

Required fields:

- `schemaVersion`
- `id`
- `createdAt`
- `workflowName`
- `workflowVersion`
- `toolName`
- `toolVersion`
- `tool` object with `name`, `version`, and optional `kind`
- `argv`
- `reproducibleCommand`
- `options` with explicit values, default values, and resolved defaults
- `runtimeIdentity`
- `files`
- `output` for the primary output when there is one
- `outputs` for multi-output workflows
- `steps`
- `wallTimeSeconds`
- `exitStatus`
- `stderr`
- `signatures` metadata when companion signature artifacts are present
- `legacyWorkflowRun` compatibility payload or field aliases where needed for older app readers

`runtimeIdentity` should record:

- Lungfish app or CLI version
- executable path
- process identifier
- operating system version and architecture
- git revision when available
- user account where already recorded today
- conda environment name and prefix when available
- plugin pack identity when available
- container image and digest when available

`files`, `output`, and `outputs` should use a canonical file descriptor with:

- `path`
- `checksumSHA256`
- `fileSize`
- `format`
- `role`
- optional `originPath` for rehydrated GUI imports
- optional `sourceProvenancePath` when this file was copied from a CLI output or earlier bundle

For compatibility, the descriptor can also encode `sha256` and `sizeBytes` aliases while readers migrate.

## Provenance Builder API

Add a builder framework in `Sources/LungfishWorkflow/Provenance/`:

- `ProvenanceRunBuilder`
- `ProvenanceStepBuilder`
- `ProvenanceOperationDescriptor`
- `ProvenanceOptions`
- `ProvenanceRuntimeIdentity`
- `ProvenanceFileDescriptor`
- `ProvenanceWriter`
- `ProvenanceRehydrator`

The API should make the correct path easier than manual construction:

```swift
let provenance = try await ProvenanceRunBuilder(
    workflowName: "fastq.trim.fastp",
    workflowVersion: LungfishVersion.current,
    toolName: "fastp",
    toolVersion: fastpVersion
)
.argv(["fastp", "-i", input.path, "-o", output.path])
.options(
    explicit: ["quality": .integer(20)],
    defaults: ["detectAdapter": .bool(true)],
    resolved: ["quality": .integer(20), "detectAdapter": .bool(true)]
)
.input(inputURL, role: .input)
.output(outputURL, role: .output)
.runtime(.current(executablePath: executableURL, condaEnvironment: "lungfish-tools"))
.complete(exitStatus: 0, stderr: stderr, startedAt: startedAt, endedAt: endedAt)

try ProvenanceWriter().write(provenance, to: outputDirectory)
```

The concrete implementation can refine the exact method names, but the behavior must remain:

- A scientific output cannot be finalized through the new writer without a complete descriptor.
- `argv` is canonical; `reproducibleCommand` is derived from shell-escaped `argv` unless a workflow has a more accurate multi-command reproduction string.
- Resolved defaults are explicit data, not prose embedded in command strings.
- File metadata is resolved at the final storage location unless the file is an input that intentionally points outside the output bundle.
- Stderr is truncated consistently and marked as truncated when needed.
- Signing runs after the JSON bytes are written, using the existing signing provider.

## Checksum Policy

Scientific provenance must record full SHA-256 checksums over file contents for files that are recorded as concrete inputs or outputs. Existing partial digests can remain readable as legacy data, but the new builder should not emit `partial:` for canonical `checksumSHA256`.

For very large files, the writer can stream checksums in chunks and report progress through an optional callback. If a file cannot be read, the builder must either fail the operation finalization or record an explicit non-success provenance status for the run that produced the failed output. It must not silently omit checksums for successful scientific outputs.

Directory outputs should be represented by a manifest descriptor rather than pretending the directory itself has a content checksum. The manifest should enumerate contained files with checksums and sizes.

## Policy and Registry Gates

Add a shared policy model, tentatively `ScientificProvenancePolicy`, that answers two questions:

1. Does this command, action, node, workflow, or registry entry create, import, transform, export, or wrap scientific data?
2. If yes, which provenance descriptor or builder integration is responsible for writing the sidecar?

Coverage tests should enforce the policy for:

- `lungfish-cli` scientific subcommands.
- `NativeTool` and managed native tool invocations.
- `BuiltInTools` and workflow builder recipes.
- `FASTQOperationToolID`.
- `MultipleSequenceAlignmentActionRegistry`.
- classifier, extraction, import, mapping, assembly, variant, primer, tree, database, and derived bundle workflows.
- app services that wrap CLI outputs into final bundles.

The tests should deliberately fail when a new scientific registry item is added without a provenance policy decision.

## CLI Integration

`CLIProvenanceSupport.recordSingleStepRun` should become a thin compatibility wrapper over the new builder. CLI commands should pass operation descriptors that include:

- command and subcommand names
- exact argv after argument parsing
- user-visible options
- resolved defaults
- runtime identity
- conda or container identity when applicable
- input and output URLs
- exit status, wall time, and useful stderr

Commands that prepare workflow bundles without executing tools still need provenance for the created run bundle or wrapper artifact. Failed scientific commands should write failure provenance when an output directory or bundle has been created and can safely hold the sidecar.

The `lungfish provenance` command should add export/report support around the canonical envelope:

- `lungfish provenance export --format shell|nextflow|snakemake|methods|json`
- signed report output when signing is configured
- verification against sidecars, report bundles, and companion signature artifacts

If existing CLI naming prefers `workflow export-provenance`, that command can delegate to the same implementation; the provenance subsystem should own the exporter logic.

## GUI and Bundle Integration

GUI workflows that call `lungfish-cli` must preserve or rehydrate CLI provenance before finalizing app-owned bundles.

Required behavior:

- If the CLI output already has canonical provenance, copy it into the final bundle and rewrite output descriptors to point at final stored payload paths.
- If the CLI output has legacy `WorkflowRun` provenance, decode it, convert it to the canonical envelope, and rewrite paths.
- If the CLI output is missing provenance for a scientific workflow, the GUI import must fail rather than silently creating an unprovenanced scientific bundle.
- App-native workflows should build provenance directly with the same builder framework.
- Bundle roll-up provenance under `provenance/bundle.lungfish-provenance.json` should reference per-output sidecars in step order.

This applies to FASTQ derived bundles, classifier imports, extraction, assembly, mapping, variants, primer trimming, MSA and tree actions, workflow builder runs, local workflow runners, and database import or conversion surfaces.

## Export and Reporting

`ProvenanceExporter` should operate on the canonical envelope graph and keep `WorkflowRun` export as a compatibility path.

Exports must support:

- Shell `run.sh`
- Nextflow `main.nf`, `nextflow.config`, and container manifest where relevant
- Snakemake `Snakefile` and `config.yaml`
- Markdown methods section with the documented draft warning banner
- Full JSON provenance bundle
- copied original sidecars under `provenance/`

The export bundle should include enough original sidecars and input manifests that reviewers can diff regenerated sidecars against the originals. Exported runnable scripts should use the recorded exact argv where possible and downgrade clearly when a step can only be represented as a wrapper command.

Signed provenance reports should reuse the existing local signing provider and produce companion signature and public key artifacts beside the exported report or bundle manifest.

## GUI Reporting UX

The documented GUI entry points need to become dependable surfaces:

- `File > Export > Provenance`
- Operations Panel row expansion with a `Provenance` action
- Inspector rendering of sidecar JSON
- Settings for provenance signing status

The UI should read canonical envelopes first and legacy records second. It should expose verification status, signature status, checksum mismatch warnings, and export actions without making users browse temporary staging directories.

XCUI tests should cover:

- opening provenance from an operation row
- exporting provenance from the File menu
- viewing signed provenance status
- warning on missing or invalid provenance
- imported CLI output whose final bundle provenance points at final payload paths

## Migration and Compatibility

Readers must accept:

- canonical envelopes written by the new builder
- existing `WorkflowRun` sidecars
- bundle roll-up sidecars in `provenance/`
- per-output sidecars beside scientific files

Writers for new or changed scientific surfaces should emit canonical envelopes. Existing untouched legacy writers can be migrated progressively only if policy tests make the gap explicit and the implementation plan covers it. For this release branch, the target is comprehensive migration of all registry and app surfaces that create, import, transform, export, or wrap scientific data.

## Failure Semantics

A successful scientific operation must not produce an output without provenance.

When a scientific operation fails after creating an output directory or bundle, provenance should still be written with:

- nonzero `exitStatus` or failed status
- stderr or log reference
- start and end times
- inputs that were already resolved
- partial outputs only when they are intentionally retained and marked as incomplete

When the app cannot write provenance for a successful scientific output, the workflow should fail finalization and surface a blocking error. It should not mark the operation successful and leave the output silently unprovenanced.

## Testing Strategy

Implementation must be test-first for behavior changes.

Test groups:

- Schema fixture tests for canonical encoding and legacy decoding.
- Builder unit tests for argv, shell command rendering, options/defaults, runtime identity, full checksums, stderr truncation, and signing.
- Policy coverage tests for every scientific registry and CLI command surface.
- CLI integration tests for representative FASTQ, classifier, extraction, import, variant, workflow, bundle, database, MSA, tree, and export commands.
- GUI service tests for CLI provenance preservation and rehydration.
- Export tests for shell, Nextflow, Snakemake, methods, JSON, copied sidecars, and signed reports.
- XCUI tests for provenance buttons, inspector rendering, export menu, signing status, and invalid provenance warnings.
- Regression tests proving final GUI bundle provenance points at final stored payloads rather than temporary staging files.

End-to-end testing with real fixtures is required. Use two tiers:

- Hermetic release-blocking fixtures that are small enough to run in normal CI and local `swift test`: tiny FASTQ pairs, mini FASTA/GFF/reference bundles, small BAM/BAI fixtures, compact classifier TSVs, MSA/tree fixtures, and signed provenance fixtures. These tests must execute real CLI or app service workflows, then inspect the emitted `.lungfish-provenance.json`, exported reports, signature artifacts, and final bundle paths.
- Gated release fixtures for workflows that need large databases, managed conda tools, or mounted real projects. These tests may be skipped when prerequisites are unavailable, but the skip reason must name the missing tool, database, or fixture path. They should cover representative real FASTQ operations, classifier imports, extraction workflows, variant calling, workflow-builder runs, and GUI/XCUI provenance interactions against realistic bundles.

The E2E assertions should validate more than sidecar existence. They should check canonical schema fields, exact argv or reproducible command, resolved defaults, runtime identity, full checksums and sizes, final stored output paths, exit status, wall time, useful stderr on failures, export bundle contents, and signature verification where configured.

The branch already has a clean baseline: `swift test` passed before implementation started. Every implementation task should keep focused tests green before moving to broader verification.

## Independent Review Loop

After the first complete implementation pass, run independent review rounds with three separate teams:

1. CLI provenance team: exercises commands that create scientific outputs and checks sidecar presence, status, argv, defaults, runtime identity, paths, checksums, and export commands.
2. JSON and report audit team: inspects canonical sidecars, legacy conversion, exported reports, signatures, and schema consistency.
3. GUI and XCUI team: tests provenance interactions in the app, Operations Panel, Inspector, export menu, signing settings, and GUI-imported CLI provenance rehydration.

There must be at least two review iterations. Continue up to five iterations while any team finds blocking defects in provenance completeness, report validity, signature verification, registry coverage, or GUI provenance behavior.

Each review round should produce a written feedback artifact under `docs/superpowers/reviews/` and the implementation should explicitly close each blocking item before the next round.

## Acceptance Criteria

- Every scientific CLI command, app workflow, registry item, and GUI wrapper that creates, imports, transforms, exports, or wraps scientific data has a policy entry and a builder-backed provenance path.
- Successful scientific outputs have `.lungfish-provenance.json` records in the documented location.
- Canonical sidecars include the documented schema fields and compatibility aliases where needed.
- Input and output descriptors include full SHA-256 checksums and byte sizes for files.
- GUI-imported CLI outputs preserve or rehydrate provenance so final paths point at final stored payloads.
- Provenance export supports shell, Nextflow, Snakemake, methods, and JSON bundle formats.
- Signed provenance sidecars and reports can be verified with the existing local signature verifier.
- Missing provenance is a failing condition for new scientific features and for migrated release-critical workflows.
- XCUI coverage proves users can open, inspect, export, and verify provenance through the documented GUI surfaces.
- Real-fixture E2E tests cover the representative scientific workflows and inspect both generated sidecars and exported provenance reports.
- Three independent review teams complete at least two feedback iterations, with blockers resolved or explicitly documented if a non-blocking limitation remains.
