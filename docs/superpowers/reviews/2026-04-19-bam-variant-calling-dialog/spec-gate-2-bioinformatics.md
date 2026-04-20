# Spec Gate 2 — Bioinformatics / Data Integrity Re-Review

Date: 2026-04-19
Reviewer: Expert self-review subagent (`Schrodinger`)
Verdict: Pass for planning

## Result

No remaining blocking bioinformatics or data-integrity concerns.

The reviewer explicitly cleared the revised spec to move to planning after confirming that it now:

- requires native iVar VCF output
- specifies sample-less viral SQLite import semantics without synthetic diploid genotypes
- adds concrete BAM/reference validation
- turns primer-trim into a launch gate
- narrows Medaka to provably ONT/model-resolvable inputs

## Residual non-blocking risks

1. `BAMToFASTQConverter` still has a rare stdout fallback path that should be hardened before Medaka reuses it.
2. Primer-trim proof will often be a user acknowledgement rather than durable provenance in v1.
3. BAM/reference checksum validation may frequently fall back to strict contig/length matching because many BAMs do not carry usable `@SQ M5` values.
4. Sample-less viral semantics still require UI polish so sample panes and filters behave correctly when a track truly has no samples.
