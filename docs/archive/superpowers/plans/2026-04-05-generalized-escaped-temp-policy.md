# Generalized Escaped-Temp Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate false-positive escaped-temp assertions while preserving strict detection of real project-temp policy violations across all workflows.

**Architecture:** Add explicit temp scope policy and provenance metadata to `ProjectTempDirectory`, then make the DEBUG escaped-temp scanner assert based on policy metadata instead of prefix-only heuristics. Migrate high-risk pipeline callsites first.

**Tech Stack:** Swift 6.2, Foundation, os.log, XCTest

**Spec:** `docs/superpowers/specs/2026-04-05-generalized-escaped-temp-policy-design.md`

---

### Task 1: Add Temp Policy API + Errors

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ProjectTempDirectory.swift`
- Test: `Tests/LungfishIOTests/ProjectTempDirectoryTests.swift`

- [ ] Add `TempScopePolicy` enum (`requireProjectContext`, `preferProjectContext`, `systemOnly`).
- [ ] Add `ProjectTempError.projectContextRequired(contextURL:)`.
- [ ] Add new `create(prefix:contextURL:policy:caller:line:)` API.
- [ ] Keep existing `create(prefix:in:)` and `createFromContext(prefix:contextURL:)` as compatibility wrappers.
- [ ] Add unit tests for each policy mode and error behavior.

### Task 2: Add Provenance Marker Metadata

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ProjectTempDirectory.swift`
- Test: `Tests/LungfishIOTests/ProjectTempDirectoryTests.swift`

- [ ] Define marker payload model (JSON).
- [ ] Write `.lungfish-temp-origin.json` in each created temp dir.
- [ ] Include `prefix`, `policy`, `contextPath`, `resolvedProjectPath`, `pid`, `createdAt`, `caller`.
- [ ] Add tests validating marker existence + parse correctness.

### Task 3: Make DEBUG Scanner Metadata-Driven

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Test: `Tests/LungfishAppTests/...` (new focused scanner tests)

- [ ] Update scanner to read marker metadata for candidate dirs.
- [ ] Assert only when metadata says `requireProjectContext` and dir is in system temp in current session.
- [ ] Downgrade unmarked-prefix hits to warning during migration phase.
- [ ] Keep test-fixture exclusions as belt-and-suspenders until migration completes.
- [ ] Add tests for assert vs warning decisions.

### Task 4: Harden Project Root Resolution

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ProjectTempDirectory.swift`
- Test: `Tests/LungfishIOTests/ProjectTempDirectoryTests.swift`

- [ ] Replace fixed max-depth walk with root-terminating walk (or increase depth with explicit rationale).
- [ ] Add deep-nesting tests proving `.lungfish` root is found for nested derivative paths.
- [ ] Verify no performance regression for typical paths.

### Task 5: Migrate High-Risk Callsites to Explicit Policies

**Files (initial batch):**
- Modify: `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift`
- Modify: `Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift`
- Modify: `Sources/LungfishWorkflow/Orient/OrientPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift`
- Modify (if needed for policy propagation): `Sources/LungfishWorkflow/Demultiplex/DemultiplexingModels.swift` or file containing `DemultiplexConfig`

- [ ] For app-driven project workflows, use `requireProjectContext`.
- [ ] For flows that legitimately operate outside projects, use `preferProjectContext` or `systemOnly` explicitly.
- [ ] Thread policy through config objects where needed (e.g., `DemultiplexConfig`).
- [ ] Add targeted tests for both project and non-project call paths.

### Task 6: Regression Verification Matrix

**Files:**
- Modify tests as needed in `Tests/LungfishWorkflowTests`, `Tests/LungfishIOTests`, `Tests/LungfishAppTests`

- [ ] `swift test --filter ProjectTempDirectoryTests`
- [ ] `swift test --filter DemultiplexingPipelineTests`
- [ ] `swift test --filter EsVirituPipelineTests`
- [ ] Verify DEBUG app does not crash for allowed fallback contexts.
- [ ] Verify DEBUG app still asserts for forced violation (`requireProjectContext` escaped temp in system dir).

### Task 7: Migration Tightening

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Optional docs: `docs/superpowers/specs/2026-04-05-generalized-escaped-temp-policy-design.md`

- [ ] After marker coverage is high, change unmarked-prefix behavior from warning to assert (optional staged flag).
- [ ] Remove no-longer-needed temporary exclusions once superseded by metadata.
- [ ] Update spec docs with final enforcement mode.

---

## Exit Criteria

1. No false-positive escaped-temp crashes for valid fallback workflows.
2. Real project-required escapes are still caught with high-confidence assertions.
3. Every temp directory created by managed APIs carries provenance metadata.
4. High-risk pipelines (including demux) are policy-classified and covered by tests.
