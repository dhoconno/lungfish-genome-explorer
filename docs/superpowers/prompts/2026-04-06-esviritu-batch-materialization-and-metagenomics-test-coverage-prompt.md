Implement the metagenomics batch materialization fix and regression coverage using these artifacts:
- Spec: `docs/superpowers/specs/2026-04-06-esviritu-batch-materialization-and-metagenomics-tests-design.md`
- Plan: `docs/superpowers/plans/2026-04-06-esviritu-batch-materialization-and-metagenomics-test-coverage.md`

Required Superpowers execution workflow:
1. Use `systematic-debugging` first to re-confirm root-cause evidence in the failing batch output.
2. Use `test-driven-development` for every behavior change (write failing test first, then implement minimal fix).
3. Use `verification-before-completion` before claiming success.

Primary objectives:
1) Fix EsViritu batch by resolving/materializing `.lungfishfastq` inputs before pipeline execution.
2) Apply the same batch-resolution parity fix to Kraken2/Bracken batch execution.
3) Keep TaxTriage on the same shared input materialization path without regressions.
4) Harden `EsVirituConfig`, `ClassificationConfig`, and `TaxTriageConfig` validation to reject directory inputs explicitly.
5) Add deterministic functional fixture tests for EsViritu, Kraken2/Bracken, and TaxTriage output-location contracts.

Implementation constraints:
- Preserve existing user-visible output directory layout and batch manifests.
- Preserve original logical input paths in persisted manifests; do not store transient materialized temp file paths.
- Keep deterministic tests runnable without requiring local tool/database installations.
- Optional real-tool smoke tests may remain skip-if-missing and must not gate deterministic coverage.

Verification requirements:
- Run all commands listed in the plan’s task sections.
- Include final evidence for:
  - passing deterministic regression/functional tests
  - any skipped optional smoke tests (with reason)
  - manual re-run result for `/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Imports` showing EsViritu batch no longer fails with unresolved `.lungfishfastq` input paths.

Deliverables:
- Code changes implementing the fix.
- New/updated tests and fixtures.
- Brief summary mapping each plan task to completed file changes.
