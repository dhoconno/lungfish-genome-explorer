# EsViritu installer repair implementation plan

> Use subagent-driven development. User authorized a surgical repair following diagnosis.

**Goal:** Restore EsViritu downloads through the shared registry with durable provenance and discovery.
**Architecture:** Retain the transactional installer, specialize format validation and destination selection by tool, and preserve archive catalog versions.
**Tech Stack:** Swift, Foundation, Swift Testing.
**Spec:** User request and main-checkout docs/reports/2026-09-23-esviritu-download-investigation.md.

## Global Constraints
- Keep changes surgical; no unrelated refactoring or source-data transformation.
- Preserve transactional rollback and strict Kraken2 checks.
- Every installed scientific payload must retain canonical reproducibility provenance containing exact command, versions, runtime, options/defaults, paths, checksums, sizes, exit status, timing, and useful stderr; outputs must reference final durable paths.
- Use synthetic small fixtures; real downloaded archive is available for optional verification under /tmp/lungfish-esviritu-download-check/.

## Review Focus
- Nested version directory and manager discovery.
- Empty reference or metadata-only archive must fail.
- Existing Kraken2 payload checks and special-build behavior remain strict.
- Archive version stays v3.2.4, not a generated build stamp.
- Provenance and rollback remain valid after changing destination.

### Task 1: Repair shared installation of EsViritu archives

**Files:** Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstaller.swift; MetagenomicsDatabaseRegistry.swift; relevant installer/registry tests. Inspect EsVirituDatabaseManager.swift for discovery contract; prefer honoring existing path over rewriting discovery.

- [ ] Write failing regression tests using the production installer with an EsViritu-shaped synthetic archive payload v3.2.4/{reference.fna,reference.mmi,metadata.tsv}. Verify installed path esviritu/esviritu-viral-db, ready/discoverable database, catalog version v3.2.4, and canonical receipt output paths and payload digest.
- [ ] Add rejection coverage for empty/missing reference payload; keep Kraken2 tests.
- [ ] Run appropriate focused baseline/new tests and capture expected regression failure before implementation.
- [ ] Replace hardcoded Kraken2 destination only as needed for supported EsViritu tool. Preserve existing Kraken2 catalog-ID naming. Use a tool-aware nonempty regular reference/index validator for EsViritu at top level or a single nested version directory; no accepting symlinks or directories as reference files. Maintain all current Kraken2 checks.
- [ ] Ensure shared registry preserves the catalog version for EsViritu archive installs rather than synthetic built-date version, without changing special Kraken2 version behavior.
- [ ] Verify success provenance at final path, transactional rollback and existing Kraken2 behavior with focused tests. Exercise actual production integration if reasonably available without installing into user's data.
- [ ] Commit only task changes and report commands, results, limitations and commit SHA.
