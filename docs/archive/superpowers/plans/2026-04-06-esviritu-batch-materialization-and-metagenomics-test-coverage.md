# EsViritu Batch Materialization and Metagenomics Test Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix EsViritu batch failures caused by unresolved `.lungfishfastq` bundle inputs, close the same batch gap for Kraken2/Bracken, and add deterministic regression tests (including FASTQ artifact functional tests) for EsViritu, Kraken2/Bracken, and TaxTriage.

**Architecture:** Introduce a shared app-layer input materialization helper used by all metagenomics run modes, enforce strict FASTQ-file validation in workflow configs, and add fixture-driven functional tests using deterministic execution doubles so CI does not depend on local bioinformatics installations.

**Tech Stack:** Swift 6.2, XCTest, LungfishApp + LungfishWorkflow modules, FASTQ bundle fixtures under `Tests/Fixtures`.

---

## File Map

| Action | File | Responsibility |
|---|---|---|
| Create | `Sources/LungfishApp/Services/MetagenomicsInputMaterializationService.swift` | Shared config input resolution/materialization for EsViritu, Classification, TaxTriage |
| Modify | `Sources/LungfishApp/App/AppDelegate.swift` | Use shared service in single + batch run paths; preserve original input paths in manifests |
| Modify | `Sources/LungfishWorkflow/Metagenomics/EsVirituConfig.swift` | Reject directory inputs with explicit validation error |
| Modify | `Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift` | Reject directory inputs with explicit validation error |
| Modify | `Sources/LungfishWorkflow/TaxTriage/TaxTriageConfig.swift` | Reject directory inputs with explicit validation error |
| Create | `Tests/LungfishAppTests/MetagenomicsBatchMaterializationTests.swift` | Regression tests for batch materialization parity and manifest-path stability |
| Create | `Tests/LungfishWorkflowTests/Metagenomics/EsVirituBatchRegressionTests.swift` | EsViritu config/pipeline regression tests around bundle-directory inputs |
| Create | `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsFunctionalFixtureTests.swift` | Deterministic functional tests for EsViritu + Classification + TaxTriage expected outputs |
| Create | `Tests/Fixtures/metagenomics/inputs/SampleA.lungfishfastq/SampleA.fastq` | FASTQ artifact fixture A |
| Create | `Tests/Fixtures/metagenomics/inputs/SampleB.lungfishfastq/SampleB.fastq` | FASTQ artifact fixture B |
| Create | `Tests/Fixtures/metagenomics/expected/esviritu/SampleA.detected_virus.info.tsv` | Expected EsViritu output fixture |
| Create | `Tests/Fixtures/metagenomics/expected/classification/classification.kreport` | Expected Kraken2 report fixture |
| Create | `Tests/Fixtures/metagenomics/expected/classification/classification.kraken` | Expected Kraken2 read-assignment fixture |
| Create | `Tests/Fixtures/metagenomics/expected/classification/classification.bracken` | Expected Bracken fixture |
| Create | `Tests/Fixtures/metagenomics/expected/taxtriage/report.tsv` | Expected TaxTriage report fixture |
| Create | `Tests/Fixtures/metagenomics/expected/taxtriage/confidence.tsv` | Expected TaxTriage metrics fixture |

---

### Task 1: Lock the Failure with Regression Tests (Red)

**Files:**
- Create: `Tests/LungfishAppTests/MetagenomicsBatchMaterializationTests.swift`
- Create: `Tests/LungfishWorkflowTests/Metagenomics/EsVirituBatchRegressionTests.swift`

- [ ] **Step 1: Add a regression test proving unresolved bundle directories are currently passed into EsViritu batch paths**

Test input:
- `.lungfishfastq` directory URLs containing inner FASTQ files.

Expected pre-fix behavior:
- Test demonstrates batch path does not materialize inputs before execution.

- [ ] **Step 2: Add a regression test for Classification batch path parity**

Expected pre-fix behavior:
- Batch path uses unresolved bundle directories while single path resolves.

- [ ] **Step 3: Add config validation tests for directory-input rejection (initially failing)**

Expected after implementation:
- `EsVirituConfig.validate()`, `ClassificationConfig.validate()`, and `TaxTriageConfig.validate()` throw explicit directory-input errors.

- [ ] **Step 4: Run targeted tests and confirm red state**

Run:
```bash
swift test --filter MetagenomicsBatchMaterializationTests
swift test --filter EsVirituBatchRegressionTests
```

Expected:
- At least one failure proving the regression exists before fix.

---

### Task 2: Implement Shared Input Materialization Service (Green)

**Files:**
- Create: `Sources/LungfishApp/Services/MetagenomicsInputMaterializationService.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`

- [ ] **Step 1: Extract current `resolveInputFiles(...)` behavior into a reusable service**

Service behavior:
- Accept original input URLs.
- Resolve `.lungfishfastq` bundles and derived bundles via existing resolver/materializer flow.
- Return concrete FASTQ file URLs.

- [ ] **Step 2: Apply service to EsViritu single + batch paths**

Requirements:
- Batch path must resolve per-sample inputs before invoking `EsVirituPipeline.detect`.
- Manifest/sample records must continue to store original logical inputs (bundle URLs), not transient temp files.

- [ ] **Step 3: Apply service to Classification single + batch paths**

Requirements:
- Preserve existing display-name/original-input behavior.
- Ensure batch path resolves inputs before `ClassificationPipeline.classify/profile`.

- [ ] **Step 4: Keep TaxTriage on same shared service (no behavior regression)**

Requirements:
- Existing functionality preserved while centralizing resolution code path.

- [ ] **Step 5: Run targeted tests and ensure green**

Run:
```bash
swift test --filter MetagenomicsBatchMaterializationTests
swift test --filter ClassificationPipelineTests
swift test --filter EsVirituPipelineTests
```

Expected:
- Batch resolution tests pass.
- Existing pipeline tests remain green.

---

### Task 3: Harden Validation Errors for Directory Inputs

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/EsVirituConfig.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift`
- Modify: `Sources/LungfishWorkflow/TaxTriage/TaxTriageConfig.swift`

- [ ] **Step 1: Add explicit error cases for directory input paths**

Each config should expose a distinct error (for actionable UX), e.g.:
- "Input path is a directory; expected FASTQ file"

- [ ] **Step 2: Update validation to check file type, not only path existence**

Requirements:
- Keep existing file-not-found behavior.
- Add directory-path rejection before tool invocation.

- [ ] **Step 3: Add/extend tests for new errors**

Run:
```bash
swift test --filter EsVirituConfigTests
swift test --filter ClassificationConfigTests
swift test --filter TaxTriagePipelineTests
```

Expected:
- New directory-input tests pass.
- Existing config validation tests still pass.

---

### Task 4: Add Deterministic Functional Fixture Tests for All 3 Tool Flows

**Files:**
- Create: `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsFunctionalFixtureTests.swift`
- Create/update: `Tests/Fixtures/metagenomics/...`

- [ ] **Step 1: Add tiny `.lungfishfastq` FASTQ fixture bundles and expected output fixtures**

Fixture requirements:
- Two small samples (single-end) with deterministic read content.
- Expected output artifacts for EsViritu, Classification (Kraken2/Bracken), and TaxTriage.

- [ ] **Step 2: Implement deterministic execution doubles for functional tests**

Behavior:
- Simulate tool invocation by writing expected output artifacts to the exact output paths generated by configs.
- Ensure tests exercise run orchestration and output-location contracts.

- [ ] **Step 3: Add functional tests asserting output existence + expected parse results + expected output locations**

Assertions:
- EsViritu: `<sample>/<sample>.detected_virus.info.tsv` exists and parses.
- Classification: `classification.kreport`, `classification.kraken`, `classification.bracken` exist and parse.
- TaxTriage: expected report/metrics outputs exist and parse.

- [ ] **Step 4: Run functional fixture tests**

Run:
```bash
swift test --filter MetagenomicsFunctionalFixtureTests
```

Expected:
- Tests pass without requiring local Kraken2/Bracken/EsViritu/Nextflow installations.

---

### Task 5: Add Optional Real-Tool Smoke Coverage and Final Verification

**Files:**
- Modify: `Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineTests.swift`
- Modify: `Tests/LungfishWorkflowTests/Metagenomics/EsVirituPipelineTests.swift`
- Modify: `Tests/LungfishWorkflowTests/TaxTriagePipelineTests.swift`

- [ ] **Step 1: Keep/extend skip-if-missing smoke tests for local environments with real tools**

Purpose:
- Preserve optional confidence checks for real executables/databases.

- [ ] **Step 2: Execute final targeted suite**

Run:
```bash
swift test --filter MetagenomicsBatchMaterializationTests
swift test --filter EsVirituBatchRegressionTests
swift test --filter MetagenomicsFunctionalFixtureTests
swift test --filter EsVirituPipelineTests
swift test --filter ClassificationPipelineTests
swift test --filter TaxTriagePipelineTests
```

Expected:
- Deterministic tests pass consistently.
- Optional smoke tests skip cleanly when prerequisites are missing.

- [ ] **Step 3: Validate against original failing project path**

Manual verification:
- Re-run EsViritu batch on `/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Imports`.
- Confirm summary contains successful outputs and no "input read file not found ... .lungfishfastq" failures.

