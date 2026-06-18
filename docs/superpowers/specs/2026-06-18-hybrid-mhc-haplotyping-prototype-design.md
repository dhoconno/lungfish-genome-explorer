# Hybrid MHC Haplotyping Prototype Design

## Goal

Smoke test a hybrid MCM MHC haplotyping workflow before adding it to the official
Lungfish CLI or app. The prototype should run from filesystem inputs, produce a
color-coded Excel report in the established Genetics Services style, and emit a
machine-readable unresolved-target evidence file that can later drive AI
refinement.

## Inputs

- Sample bundles: all `.lungfishfastq` directories under
  `/Volumes/iWES_WNPRC/32271/32271.lungfish/32271-NB05-2026-06-17/ont-fluidigm-samples`.
- Reference bundle:
  `/Users/dho/Desktop/sandbox/mcm-mhc-miseq-reference-20260617/MCM-MHC-miSeq-20260617.lungfishmhcref`.
- Haplotype definition: the reference bundle default,
  `mcm-mhc-miseq-20260617`.
- Example report used for shape and coloring:
  `/Users/dho/Downloads/32307_ONT09_vs_ONT08_LCPreclincial38_MCM_30May26v2.xlsx`.

## Prototype Boundary

The code will live under `scripts/analysis/` and should be structured so its
data models and pure haplotyping logic can move into `LungfishWorkflow` later.
It is not part of the official CLI in this phase.

The prototype may call the existing `lungfish-cli fastq genotype` command or
reuse its output bundles, but the smoke-test-specific orchestration, unresolved
target selection, and report assembly stay in the prototype script.

## Deterministic Pass

The first pass runs deterministic genotyping and haplotype assignment with the
new MCM reference bundle. It applies low-support filtering before haplotype
matching to prevent low-level extra alleles from poisoning otherwise clear
calls.

Initial thresholds:

- `minSupport = 2`
- global per-locus fraction threshold: `1%`
- `MHC-DQ` per-locus fraction override: `5%`
- `MHC-DP` per-locus fraction override: `5%`

The prototype records the resolved threshold values in its output provenance and
in a summary sheet or sidecar.

## Call States

Each sample/locus call is classified as one of:

- `called`: one or two haplotypes are deterministically assigned.
- `not_assayed`: the locus is unavailable for the active reference/assay in the
  run rather than failed in one sample.
- `no_haplotype`: observed evidence does not match any known haplotype.
- `too_many_haplotypes`: more than two haplotype definitions match after
  filtering.
- `too_many_genotypes`: a diploid class II locus has more than two raw genotype
  observations after filtering.
- `special_case`: deterministic MCM-specific rescue logic was applied.

Only unresolved states are eligible for later AI refinement. Deterministic
`called`, `not_assayed`, and documented `special_case` calls are not sent to AI
unless a future option explicitly requests full review.

## AI-Ready Evidence Output

The first smoke test does not call an AI provider. It writes
`unresolved-targets.json` containing:

- sample ID
- report locus
- deterministic state and displayed haplotype labels
- observed genotype rows for that sample/locus after filtering
- dropped low-support observations for audit
- matched haplotype definitions, if any
- linked support loci needed for human-like interpretation, especially
  MHC-A/AG/G/F/E context and MHC-DQ/DP linkage
- reference and haplotype definition digests

This file is the contract for the later AI refinement step.

## Excel Output

The workbook contains one primary report sheet modeled on the attached example:

- top rows: animal/sample IDs and filtered exact-match read counts
- haplotype summary rows for MHC-A, MHC-B, MHC-DRB, MHC-DQ, and MHC-DP
- comments row summarizing unresolved calls per sample
- genotype count matrix below the haplotype rows
- M1-M7 color coding using the established font-color palette
- unresolved calls shown plainly as `ERR: ...` or `?` according to the
  deterministic call state

The workbook should also include a compact provenance or run-summary sheet with
input paths, reference path, thresholds, script version, command line, file
checksums, start/end timestamps, and output paths. This satisfies the Lungfish
provenance rule even though the artifact is a prototype.

## Validation

The smoke test is successful when:

- all 48 sample bundles are processed or explicitly reported as skipped with a
  reason;
- the workbook opens cleanly and visually matches the expected report shape;
- called haplotypes use MCM family labels consistently (`M1A`, `M4DP`, etc.);
- unresolved calls are visible in comments and in `unresolved-targets.json`;
- output provenance includes inputs, outputs, checksums, thresholds, command
  line, exit status, and wall time.

## Later CLI Wiring

After the smoke test is accepted, the portable pieces should move into the
official codebase:

- deterministic target selection and unresolved evidence assembly in
  `LungfishWorkflow`;
- CLI flags for hybrid mode and thresholds in `lungfish-cli`;
- AI runner support for target-filtered evidence chunks;
- bundle revision/provenance publication for hybrid deterministic-plus-AI
  haplotype analyses;
- tests covering threshold filtering, unresolved-target selection, Excel export,
  and provenance.
