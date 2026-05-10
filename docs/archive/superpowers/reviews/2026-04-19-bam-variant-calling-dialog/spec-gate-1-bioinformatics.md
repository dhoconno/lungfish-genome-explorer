# Spec Gate 1 — Bioinformatics / Data Integrity Review

Date: 2026-04-19
Reviewer: Expert self-review subagent (`Schrodinger`)
Scope: Bioinformatics correctness and data integrity for the original BAM variant-calling dialog spec
Verdict: Blocked pending spec revision

## Blocking issues

1. The spec incorrectly planned a custom iVar TSV-to-VCF conversion path instead of using native iVar VCF output.
2. The Medaka path relied on naive BAM-to-FASTQ reconstruction and assumed BAM provenance preserved model-selection context without proof.
3. BAM/reference validation was too weak; it needed explicit contig and length checks before any caller ran.
4. Reusing the existing SQLite importer unchanged would invent synthetic diploid genotype semantics for sample-less viral callsets.
5. The iVar safety story was too weak because a warning-only primer-trim note was not enough for an explicitly supported amplicon caller.

## Important issues

1. The spec assumed bundle references could be handed directly to callers even though the bundle stores `genome/sequence.fa.gz`.
2. The new `VCF.gz` / `.tbi` artifact contract conflicted with existing placeholder BCF/CSI assumptions in several code paths.
3. The spec had not decided whether iVar `-g annotations.gff3` / `ANN=` support was in scope.

## Required disposition

Do not move to planning until the spec explicitly:

- uses native iVar VCF output
- hardens or narrows Medaka support
- adds strict BAM/reference validation
- defines viral sample-less SQLite import semantics with no synthetic diploid genotypes
- turns iVar primer-trim handling into a launch gate
- clarifies reference staging
- resolves the `ANN=` scope decision for v1
