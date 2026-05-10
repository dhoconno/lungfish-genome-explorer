# Assembly XCUI Gap Report

Date: 2026-04-19
Scope: Assembly XCUI pilot, real-fixture viability, and viewport parity gaps
Branch: `codex/assembly-xcui-pilot`

## Current Fixture Viability

Real managed-assembler runs were audited against checked-in fixtures and the current local assembly pack environments.

### Assemblers that currently work end-to-end with real fixtures

- `MEGAHIT`
  - Fixture: `Tests/Fixtures/sarscov2/test_1.fastq.gz` + `test_2.fastq.gz`
  - Result: successful managed assembly with non-empty contig output
  - XCUI target: suitable for live-smoke end-to-end coverage

- `SKESA`
  - Fixture: `Tests/Fixtures/sarscov2/test_1.fastq.gz` + `test_2.fastq.gz`
  - Result: successful managed assembly with non-empty contig output
  - XCUI target: suitable for live-smoke end-to-end coverage

### Assemblers that do not yet have meaningful real-fixture coverage

- `SPAdes`
  - The UI/profile bug where the default `isolate` profile did not emit `--isolate` was real and has been fixed.
  - Even with `--isolate`, the current SARS-CoV-2 paired fixture still fails in the underlying assembler with `Invalid kmer coverage histogram`.
  - Gap: add or curate a real SPAdes-compatible Illumina fixture that produces a stable successful result.

- `Flye`
  - Fixture: `Tests/Fixtures/assembly-ui/ont/reads.fastq`
  - Result: fails with `No reads above minimum length threshold (1000)`.
  - Gap: add a longer ONT fixture that clears Flye's minimum-read-length requirements.

- `Hifiasm`
  - Fixture: `Tests/Fixtures/assembly-ui/pacbio-hifi/reads.fastq`
  - Result: run completes, but produces zero contigs.
  - Gap: add a HiFi/CCS fixture that yields a non-empty assembly result so the viewport and sidebar behavior are tested against a meaningful outcome.

## XCUI Status

The pilot surfaced a product-side gating issue that should be addressed before investing further in XCUI stabilization: assembly read-type readiness was being computed directly from selected input URLs as though they were raw FASTQ files, while the app commonly passes `.lungfishfastq` bundle URLs.

### What is now covered or in progress

- Deterministic assembly dialog coverage for:
  - assembler switching across `SPAdes`, `MEGAHIT`, `SKESA`, `Flye`, and `Hifiasm`
  - assembly-specific accessibility identifiers
  - raw FASTQ project fixtures for Illumina, ONT, and PacBio HiFi/CCS selection flows

- Live-smoke target coverage for:
  - `MEGAHIT`
  - `SKESA`

### App-side fixes already required by the pilot

- `ManagedAssemblyPipeline.buildSpadesCommand(for:)` now emits `--isolate` for the default SPAdes profile.
- FASTQ datasets now support a persisted dataset-level assembly read type in the Document Inspector.
- Assembly tool availability now honors the effective dataset read type, disabling incompatible assemblers in the assembly tool picker/sidebar.
- PacBio assembly support remains intentionally scoped to HiFi/CCS datasets; CLR/subreads are not exposed as a supported assembly read class in this phase.
- Assembly read-type detection now resolves `.lungfishfastq` bundle selections to their primary FASTQ payload before evaluating assembly compatibility.
- Assembly read-type detection now honors the persisted dataset read type first and falls back to FASTQ-sidecar sequencing-platform metadata when header sniffing is inconclusive.
- `FASTQOperationExecutionService` now treats assembly as a directory-output workflow and discovers assembly results from the actual CLI output directory.
- Embedded assembly runs now create timestamped analysis directories under `Analyses/` instead of writing directly into the container root.
- FASTQ assembly dialog and assembly result viewport now expose stable XCUI/accessibility identifiers for the shared harness.

## Remaining Product Gaps

### Real-fixture gaps

- Add one real successful fixture each for:
  - `SPAdes`
  - `Flye`
  - `Hifiasm`

- Keep `MEGAHIT` and `SKESA` as the current live-smoke baseline until those fixtures exist.

### XCUI harness gaps

- Defer further XCUI expansion until the product-side assembly readiness path is stable for real dataset selections. The bundle-selection read-type bug was a product bug first and an XCUI failure only second.
- Finish stabilizing the deterministic assembly dialog assertions for lower, scroll-hosted controls in the embedded assembly form.
- The `Min Contig` stepper row is still not exposing a stable macOS XCUI target despite the dedicated identifier work; treat that as a follow-up accessibility hole rather than silently assuming the control is covered.
- Keep the harness pointed at direct filesystem opens/saves rather than macOS system panels.
- Continue exercising assembly workflows end-to-end with real fixtures wherever the underlying tool and fixture pair is viable.

### Dataset metadata and readiness gaps

- Current code inspection shows that local FASTQ import does not clearly persist the user-confirmed platform into the FASTQ sidecar metadata, while the download/import path does.
  - Impact: the new metadata fallback improves assembly readiness when sequencing-platform sidecar metadata exists, but that path is not yet uniformly populated across import routes.

- Inference from code: paired-end topology in `AssemblyWizardSheet` is still inferred from selected input URL names.
  - Imported bundle selections, especially interleaved paired-end bundles, should be audited separately so assembly request topology is derived from bundle metadata rather than filename conventions alone.

### Sidebar and result-routing gaps

- Confirm the new per-run analysis-directory routing for assembly in live XCUI, specifically:
  - the assembler output lands under `Analyses/{tool}-{timestamp}/`
  - the sidebar selects the new analysis item automatically
  - the assembly result viewport opens on completion

## Viewport Parity Gaps

The current `AssemblyResultViewController` is still a stub and does not match the classifier multi-part viewport shell the app is converging on.

### Missing relative to the classifier shell

- `Two-pane result shell`
  - Classifier result controllers use a tracked split view with list/detail panes.
  - Assembly still renders a single table-only content area.

- `Dedicated detail pane`
  - Classifier views support single-selection details and multi-selection placeholder states.
  - Assembly has no contig detail pane or selection-dependent detail presentation.

- `Bottom action bar`
  - Classifier views have a shared action bar for BLAST/export/provenance actions.
  - Assembly only exposes a table context menu today.

- `Shared pane-layout adoption seam`
  - The shared pane/layout foundation work explicitly expects future assembly views to adopt the same hosted pane model as classifier views.
  - Assembly is not yet wired into that layout system.

## Recommended Next Steps

1. Audit and, if needed, fix paired-end/interleaved topology derivation for bundle-backed assembly inputs.
2. Resume assembly deterministic XCUI stabilization only after those product-side readiness paths are green.
3. Verify live-smoke `MEGAHIT` and `SKESA` runs in XCUI against the per-run analysis-directory routing.
4. Add viable real fixtures for `SPAdes`, `Flye`, and `Hifiasm`.
5. Replace the assembly result stub with a classifier-style multi-part viewport:
   - summary bar
   - split list/detail shell
   - action bar
   - layout-mode support through the shared pane foundation

## Reporting Guidance

This report should be treated as an input to the next assembly spec/plan update.

The missing viewport and layout work is not incidental polish. It is a product gap that should be tracked explicitly so assembly outputs follow the same multi-part viewport direction as the classifier result views.
