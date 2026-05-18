# Wave 3 FASTQ Operation Execution Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decompose `FASTQOperationExecutionService.execute(...)` into focused App-owned planner, CLI invocation, output import, provenance rehydration, and staging cleanup services without changing FASTQ command behavior, output naming, manifests, or provenance semantics.

**Architecture:** Keep `FASTQOperationExecutionService` as the public async orchestrator. Move pure planning and CLI argument mapping into value-type services, move output bundle/report/reference import into an importer service, move path-map and reference provenance merging into a rehydrator service, and isolate transient directory deletion in a cleanup service with explicit preservation rules.

**Tech Stack:** Swift Package Manager, XCTest, LungfishApp services, LungfishIO FASTQ/reference bundle APIs, LungfishWorkflow provenance APIs.

---

## Slice Spec

- Scope is limited to `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/wave3-fastq-execution-split`.
- Do not modify ONT workflow, CLI, `MainSplitViewController`, GenBank/Kraken parsers, or dialog sheets.
- Preserve the public entry point `FASTQOperationExecutionService.execute(request:workingDirectory:)`.
- Preserve `FASTQOperationExecutionService.buildInvocation(for:)` as compatibility surface for existing tests/callers, delegating to the new builder.
- Preserve CLI subcommands and arguments, output target naming, grouped batch manifests, direct import behavior, and provenance rehydration semantics.
- Treat missing provenance as blocking for scientific outputs. Refactor must preserve source-to-final path replacement and reference-bundle provenance merging.

## File Structure

- Modify `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`
  - Keep shared protocols, error type, input resolver, CLI process runner, and public orchestrator.
  - Delegate planning, invocation building, importing, grouped provenance, and cleanup to extracted services.
- Create `Sources/LungfishApp/Services/FASTQOperationPlanner.swift`
  - Own output directory selection, per-input split planning, execution directory selection, output kind decisions, default output filenames, grouped manifest writing, grouped provenance envelope creation, payload discovery helpers, and launch-request helper extensions needed for planning.
- Create `Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift`
  - Own `FASTQOperationLaunchRequest` and `FASTQDerivativeRequest` to `CLIInvocation` mapping, including all unsupported-shape errors.
- Create `Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift`
  - Own `IdentityFASTQOperationImporter`, `BundleFASTQOperationImporter`, `AppReferenceBundleWrapper`, `AppFASTQOutputIngestor`, `AppFASTQOutputBundleWriter`, QC report application, FASTA reference wrapping, FASTQ bundle writing, and grouped demultiplex preservation.
- Create `Sources/LungfishApp/Services/FASTQOperationProvenanceRehydrator.swift`
  - Own materialized input path replacement, selected output rehydration, reference-bundle provenance merging, and helper methods for final payload lookup.
- Create `Sources/LungfishApp/Services/FASTQOperationStagingCleanup.swift`
  - Own transient staging directory detection and safe deletion rules.
- Modify `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`
  - Keep integration coverage for `execute(...)`.
  - Add focused unit tests for extracted services where behavior is currently only exercised through the large service.

## TDD / Red-Test Plan

- Planner red tests:
  - `testPlannerSplitsPerInputDerivativeRequestsIntoOnePlanPerInput`
  - `testPlannerUsesWorkingDirectoryForGroupedDemultiplexOutput`
  - `testPlannerKeepsAssemblyOutputInWorkingDirectory`
  - `testPlannerCreatesPerInputMapOutputDirectories`
- Invocation-builder red tests:
  - Move representative existing invocation assertions from `FASTQOperationExecutionService().buildInvocation(for:)` to `FASTQOperationCLIInvocationBuilder().buildInvocation(for:)` for trim, contaminant filter, primer removal, demultiplex, orient, classify, map, assemble, and QC summary.
  - Keep one compatibility test proving the service delegates `buildInvocation(for:)`.
- Output-importer red tests:
  - Existing FASTA-to-reference wrapping provenance tests should target `BundleFASTQOperationImporter`.
  - Existing FASTQ output bundle writing tests should remain green after extraction.
  - Add or keep tests for QC summary application and demultiplex grouped result returning `[outputDirectory]`.
- Provenance-rehydrator red tests:
  - Existing materialized input provenance replacement behavior should target `FASTQOperationProvenanceRehydrator`.
  - Existing reference bundle merge behavior should target `FASTQOperationProvenanceRehydrator`.
- Cleanup red tests:
  - `testStagingCleanupRemovesTransientDirectories`
  - `testStagingCleanupPreservesFinalBundlesAndCallerDirectories`

Red output capture:
- After adding tests and before production extraction, run `swift test --filter FASTQOperationExecutionServiceTests`.
- Expected failure: compiler cannot find new extracted service types and/or selected tests fail because APIs do not exist yet. Save the command output summary in the final response.

## Implementation Plan

### Task 1: Add Plan Document

**Files:**
- Create `docs/reviews/2026-05-16-wave3-fastq-execution-split-plan.md`

- [ ] **Step 1: Write this plan file**
- [ ] **Step 2: Confirm the plan exists**

Run: `test -f docs/reviews/2026-05-16-wave3-fastq-execution-split-plan.md`

Expected: exit 0.

### Task 2: Write Red Tests For New Service Boundaries

**Files:**
- Modify `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`

- [ ] **Step 1: Add planner, builder, provenance, and cleanup tests using concrete existing request fixtures**
- [ ] **Step 2: Run the focused test suite**

Run: `swift test --filter FASTQOperationExecutionServiceTests`

Expected: FAIL because extracted service types such as `FASTQOperationPlanner`, `FASTQOperationCLIInvocationBuilder`, `FASTQOperationProvenanceRehydrator`, and `FASTQOperationStagingCleanup` do not exist.

### Task 3: Extract Planner

**Files:**
- Create `Sources/LungfishApp/Services/FASTQOperationPlanner.swift`
- Modify `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`

- [ ] **Step 1: Move `FASTQExecutionOutputKind`, `FASTQExecutionPlan`, output directory selection, split planning, output discovery, grouped manifest, grouped provenance, path utilities, and launch-request helper extensions into the planner file**
- [ ] **Step 2: Add a `FASTQOperationPlanner` property to the service**
- [ ] **Step 3: Replace in-service calls with planner calls**
- [ ] **Step 4: Run planner-focused tests**

Run: `swift test --filter FASTQOperationExecutionServiceTests/testPlanner`

Expected: PASS after extraction.

### Task 4: Extract CLI Invocation Builder

**Files:**
- Create `Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift`
- Modify `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`

- [ ] **Step 1: Move `buildExecutionInvocation`, `fastqArguments`, quality trim mode mapping, adapter search-end mapping, derivative provenance helper extensions needed for command inputs, and assembly input replacement helpers into the builder file**
- [ ] **Step 2: Implement `FASTQOperationExecutionService.buildInvocation(for:)` as `try invocationBuilder.buildInvocation(for:)`**
- [ ] **Step 3: Use `invocationBuilder.buildInvocation(for:outputTargetPath:)` in `execute(...)`**
- [ ] **Step 4: Run builder-focused tests**

Run: `swift test --filter FASTQOperationExecutionServiceTests/testInvocationBuilder`

Expected: PASS after extraction.

### Task 5: Extract Provenance Rehydrator

**Files:**
- Create `Sources/LungfishApp/Services/FASTQOperationProvenanceRehydrator.swift`
- Modify `Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift`
- Modify `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`

- [ ] **Step 1: Move materialized input path discovery and final payload lookup into `FASTQOperationProvenanceRehydrator`**
- [ ] **Step 2: Move reference-bundle selected-output rehydration and envelope merge into the same service**
- [ ] **Step 3: Call the rehydrator from FASTQ bundle writing and reference wrapping paths**
- [ ] **Step 4: Run provenance-focused tests**

Run: `swift test --filter FASTQOperationExecutionServiceTests/test.*Provenance`

Expected: PASS after extraction.

### Task 6: Extract Output Importer

**Files:**
- Create `Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift`
- Modify `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`

- [ ] **Step 1: Move importer, reference wrapper, output ingestor, output bundle writer, QC report DTO, and importer helper code into the output importer file**
- [ ] **Step 2: Keep initializer defaults unchanged so existing app construction behavior is identical**
- [ ] **Step 3: Run importer-focused tests**

Run: `swift test --filter FASTQOperationExecutionServiceTests/testBundleImporter`

Expected: PASS after extraction.

### Task 7: Extract Staging Cleanup

**Files:**
- Create `Sources/LungfishApp/Services/FASTQOperationStagingCleanup.swift`
- Modify `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`

- [ ] **Step 1: Move transient staging detection and preservation checks into `FASTQOperationStagingCleanup`**
- [ ] **Step 2: Replace service cleanup calls with `stagingCleanup.cleanup(...)`**
- [ ] **Step 3: Run cleanup-focused tests**

Run: `swift test --filter FASTQOperationExecutionServiceTests/testStagingCleanup`

Expected: PASS after extraction.

### Task 8: Full Verification And Commit

**Files:**
- All Slice B files

- [ ] **Step 1: Run required verification**

Run:
```bash
swift test --filter FASTQOperationExecutionServiceTests
swift test --filter FASTQOperationDialogRoutingTests
swift test --filter ScientificFASTQProvenancePolicyTests
swift build --product Lungfish
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 2: Inspect diff for scope**

Run: `git diff --stat && git status --short`

Expected: only Slice B files and the required plan doc changed.

- [ ] **Step 3: Commit**

Run:
```bash
git add docs/reviews/2026-05-16-wave3-fastq-execution-split-plan.md Sources/LungfishApp/Services/FASTQOperationExecutionService.swift Sources/LungfishApp/Services/FASTQOperationPlanner.swift Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift Sources/LungfishApp/Services/FASTQOperationProvenanceRehydrator.swift Sources/LungfishApp/Services/FASTQOperationStagingCleanup.swift Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift
git commit -m "refactor fastq operation execution services"
```

Expected: commit succeeds on `codex/wave3-fastq-execution-split`.

## Verification Commands

- `swift test --filter FASTQOperationExecutionServiceTests`
- `swift test --filter FASTQOperationDialogRoutingTests`
- `swift test --filter ScientificFASTQProvenancePolicyTests`
- `swift build --product Lungfish`
- `git diff --check`

## Residual Risks

- The extraction touches many private helpers that currently rely on file-local visibility; compiler errors are likely during the split and should be resolved by keeping helpers internal to App target rather than broad public API.
- Some test names may not contain the planned prefixes, so focused filters may run zero tests; the final full required filters are authoritative.
- Provenance semantics are sensitive to exact path rewriting. Rehydrator changes must be verified by existing sidecar checksum/source path assertions, not only by build success.
- `swift build --product Lungfish` may reveal unrelated platform warnings, but any build failure in touched files blocks commit.
