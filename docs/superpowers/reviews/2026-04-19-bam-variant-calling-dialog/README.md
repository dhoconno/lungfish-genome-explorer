# BAM Variant Calling Dialog Review Reports

This directory records the expert review gates for the BAM variant-calling dialog spec and follow-on planning/implementation work.

Spec under review:

- `docs/superpowers/specs/2026-04-19-bam-variant-calling-dialog-design.md`

## Gate Log

### Gate 1 — Initial spec adversarial review

- `spec-gate-1-architecture.md`
- `spec-gate-1-bioinformatics.md`
- `spec-gate-1-disposition.md`

Gate 1 found blocking issues in the original spec around:

- missing `OperationCenter` / bundle-lock integration
- underspecified reuse of the resilient VCF helper/resume/materialization flow
- incorrect iVar TSV-to-VCF design
- weak primer-trim safety for iVar
- overly optimistic Medaka BAM/metadata assumptions
- biologically misleading synthetic diploid genotype insertion for sample-less viral callsets

The spec was revised before any planning work was allowed to continue.

### Gate 2 — Revised spec re-review

- `spec-gate-2-architecture.md`
- `spec-gate-2-bioinformatics.md`

Gate 2 is the go/no-go gate for moving from spec to implementation planning.
Both revised-spec reviewers cleared the design to move forward, with only non-blocking implementation risks noted.

### Gate 3 — Implementation plan review

- `plan-gate-1-architecture.md`
- `plan-gate-1-bioinformatics.md`

Gate 3 is the go/no-go gate for moving from planning into implementation.
Both reviewers cleared the revised plan to move forward.

### Gate 4 — Final implementation integration review

- `implementation-gate-4-architecture.md`
- `implementation-gate-4-bioinformatics.md`
- `implementation-gate-4-disposition.md`

Gate 4 is the go/no-go gate for claiming the BAM variant-calling workflow implementation is complete.
Both reviewers cleared the final CLI/app integration after the pack-availability launch gating fix landed and fresh verification passed.
