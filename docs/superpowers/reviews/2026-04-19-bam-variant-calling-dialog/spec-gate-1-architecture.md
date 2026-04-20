# Spec Gate 1 — Architecture / Error Handling Review

Date: 2026-04-19
Reviewer: Expert self-review subagent (`Einstein`)
Scope: Architecture, error handling, and documentation quality for the original BAM variant-calling dialog spec
Verdict: Blocked pending spec revision

## Blocking issues

1. The spec did not commit bundle-mutating variant calls to the existing `OperationCenter` locking and long-running operation path.
2. The shared import/attach seam was too thin and did not preserve the current helper/resume/materialization behavior from the app-side VCF import flow.
3. Medaka readiness and preflight were stated too optimistically relative to what the current bundle/alignment model actually preserves.

## Important issues

1. The dialog state still mentioned output-directory concepts even though v1 was bundle-scoped.
2. Track-id and rerun semantics were not defined.
3. The plugin-pack description was still broader than the approved viral BAM variant-calling scope.

## Required disposition

Do not move to planning until the spec explicitly:

- requires `OperationCenter` registration, bundle locking, cancellation wiring, and Operations Panel visibility
- preserves resilient VCF import behavior behind a CLI-visible shared import coordinator
- narrows or hardens Medaka support
- removes stray non-bundle output concepts
- defines rerun semantics
- narrows pack language to viral BAM variant calling
