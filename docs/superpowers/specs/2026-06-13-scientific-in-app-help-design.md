# Scientific In-App Help Design

Date: 2026-06-13
Owner: Codex
Status: Approved by user to proceed without further interactive review
Scope: First-pass in-app help for scientific workflows, operation dialogs, result action bars, and bundled help topics. This does not attempt a full rewrite of the user manual.

## Current State

Lungfish already has a small in-app Help window backed by Markdown files in `Sources/LungfishApp/Resources/Help`. Several result views and SwiftUI controls use ad hoc `.help(...)`, `toolTip`, or accessibility labels, but there is no shared system for authoring, reviewing, and reusing explanatory copy.

The app also has strong documentation assets under `docs/user-manual`, including a style guide and feature-specific chapters. Expert review protocols in `agents/process` already call out Documentation, Bioinformatics Correctness, GUI, and provenance review expectations.

## Goals

- Add a reusable help metadata layer that keeps scientific help copy editable, testable, and consistent.
- Make first-pass help available on high-traffic scientific dialogs and result controls.
- Use macOS-native affordances: SwiftUI `.help`, AppKit `toolTip`, accessibility help, Help menu topics, and concise inline guidance when a setting needs more context than a tooltip.
- Preserve provenance expectations in user-facing copy for imports, transformations, exports, classifiers, extraction, and derived bundles.
- Produce a durable surface map that identifies additional controls needing help in later passes.

## Non-Goals

- No custom web-style tooltip framework.
- No large tutorial overlay or onboarding tour.
- No new scientific workflow behavior.
- No change to provenance writing, parsing, or bundle generation code.
- No rewrite of existing user-manual chapters.

## Proposed System

Create a small help catalog that can be used from SwiftUI and AppKit:

- `LungfishHelpContent`: stable IDs and reviewed copy for tooltips, accessibility help, and inline explanatory text.
- SwiftUI helper modifiers to attach catalog copy with `.help(...)` and `.accessibilityHint(...)`.
- AppKit helper methods to attach `toolTip`, `setAccessibilityHelp`, and optional accessibility labels to `NSControl` and table columns.
- Source-level tests that verify important dialogs use the catalog rather than hard-coded scattered prose.

The catalog uses short IDs grouped by domain:

- `workflow.fastq.*`
- `workflow.bam.primerTrim.*`
- `workflow.bam.variantCalling.*`
- `workflow.classifier.*`
- `result.provenance.*`
- `result.export.*`
- `result.blast.*`

Each help item has:

- `id`: stable machine-readable key.
- `summary`: short tooltip text, usually one sentence.
- `detail`: optional inline help for controls that affect scientific interpretation.
- `audience`: `benchScientist`, `analyst`, or `powerUser`.
- `provenanceRelevant`: true when the control creates, imports, transforms, exports, extracts, or wraps scientific data.

## Copy Standards

Use the documentation voice already defined in `docs/user-manual/STYLE.md` and the Bioinformatics Educator prompt:

- Purposeful, precise, calm, and actionable.
- Prefer one sentence for tooltips.
- Use standard scientific terms, then add context when the setting can mislead a bench scientist.
- Name uncertainty directly. Use words like "often" or "may" when the claim depends on input data or tool behavior.
- Avoid marketing language and exclamation marks.
- Mention provenance when a control produces or changes scientific data: "The output keeps the command, parameters, inputs, and checksums in provenance."
- Avoid implying that a classifier hit proves infection or contamination. Use language such as "supports review", "candidate", and "verify".

## First-Pass Coverage

### Shared Operation Dialogs

`DatasetOperationsDialog` should attach help to:

- Tool sidebar choices: explain what selecting a tool changes.
- Status text: explain why Run is unavailable and what the user can fix.
- Run button: explain that the run uses the visible settings and records provenance for scientific outputs.

### FASTQ Operations

`FASTQOperationToolPanes` should add help to:

- Overview: explain what the selected operation will do to reads.
- Inputs: explain required auxiliary inputs such as reference FASTA, barcode definitions, and primer references.
- Output Strategy: explain whether the operation creates a new bundle or derived output.
- Readiness: explain disabled states.
- Advanced arguments: warn that extra arguments affect reproducibility and are included in provenance.

### BAM Primer Trim

`BAMPrimerTrimToolPanes` should add help to:

- Primer Scheme picker: scheme choice defines expected amplicon starts and ends.
- Minimum read length, quality, sliding window, and primer offset.
- Readiness: explain why Run is blocked.

### BAM Variant Calling

`BAMVariantCallingToolPanes` should add help to:

- Alignment Track: only indexed BAM tracks are eligible.
- Output Variant Track Name.
- Minimum allele frequency and minimum depth.
- iVar primer-trim confirmation: explain that iVar variant calls require primer-trimmed amplicon alignments.
- Medaka and Clair3 model fields.
- Extra arguments: provenance-relevant.

### Classifier Result Surfaces

`ClassifierActionBar` should add help to:

- BLAST Verify: use selected taxon or organism as a candidate for independent sequence search.
- Export: export the current view for review or downstream analysis.
- Extract FASTQ: create a read subset for the selected organism or taxon, with provenance.
- Provenance: inspect tool version, parameters, inputs, checksums, and outputs.

### Bundled Help Topics

Add or update help topics for:

- Reads and FASTQ operations.
- Classifier and virology review.
- Alignments and variant calling.
- Provenance and reproducibility.

## Surface Map Deliverable

The audit should produce `docs/superpowers/reviews/2026-06-13-in-app-help-surface-map.md`. It should list workflow surfaces, missing help, proposed copy, and the expert persona that requested the copy.

## Error Handling

Help lookup should fail closed:

- Missing optional help returns no tooltip rather than crashing.
- Catalog IDs used by first-pass dialogs are covered by tests.
- Help copy is plain text and should not depend on network access.

## Testing

- Unit tests for catalog uniqueness, non-empty copy, provenance flags, and banned language.
- Source-level tests confirming first-pass dialogs and shared action bars attach catalog help.
- Existing `HelpSystemTests` updated to include new bundled topics and non-empty files.
- Targeted Swift tests for changed modules.

## Review Workflow

1. Genomics and virology surface audit identifies help gaps and scientific caveats.
2. Documentation expert pass applies consistent Lungfish style and clarifies audience language.
3. Engineering applies catalog IDs to controls.
4. Tests verify coverage and style constraints.
5. Residual gaps remain in the surface map for follow-up batches.
