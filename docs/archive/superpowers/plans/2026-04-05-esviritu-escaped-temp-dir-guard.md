# EsViritu Escaped Temp Guard Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate false-positive debug crashes from test-created `esviritu-test-*` temp directories while preserving detection of real runtime escapes to system temp.

**Architecture:** Tighten the debug scanner scope to the current app session and production prefixes, then enforce test temp cleanup in EsViritu tests so fixtures never pollute system temp between runs.

**Tech Stack:** Swift 6.2, Foundation, XCTest

**Spec:** `docs/superpowers/specs/2026-04-05-esviritu-escaped-temp-dir-guard-design.md`

---

### Task 1: Harden Debug Escaped-Temp Scanner

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Test: `Tests/LungfishAppTests` (new or existing debug scanner tests if available)

- [ ] Add a session start timestamp captured when the app launches.
- [ ] Update `debugScanForEscapedTempDirs()` to assert only for candidates created during current session.
- [ ] Add explicit ignore list for test-only prefixes (`esviritu-test-`, `esviritu-test-db-`).
- [ ] Keep current production prefix matching and assertion behavior unchanged for true positives.
- [ ] Verify app still asserts when a production prefix directory is created in system temp during runtime.

### Task 2: Clean Up EsViritu Test Fixtures

**Files:**
- Modify: `Tests/LungfishWorkflowTests/Metagenomics/EsVirituPipelineTests.swift`

- [ ] Refactor fixture helpers to register all created temp directories for teardown cleanup.
- [ ] Add cleanup in `tearDown` or `addTeardownBlock` for every fixture directory created by helper methods.
- [ ] Optionally rename fixture prefixes to non-production namespace (`test-esviritu-*`) to prevent scanner collisions.
- [ ] Verify no `esviritu-test-*` directories remain in `$TMPDIR` after test run.

### Task 3: Regression Verification

**Files:**
- Modify: `Tests/LungfishWorkflowTests/Metagenomics/EsVirituPipelineTests.swift` (if adding assertions)
- Optional: add targeted test in `Tests/LungfishAppTests/...` for scanner filtering logic

- [ ] Run targeted workflow tests:
  - `swift test --filter EsVirituConfigTests`
  - `swift test --filter EsVirituPipelineTests`
- [ ] Confirm cleanup result:
  - `find "$TMPDIR" -maxdepth 1 -type d -name 'esviritu-test-*'`
  - Expected: no directories from latest run.
- [ ] Launch DEBUG app and wait through scanner interval; confirm no false positive assertion.
- [ ] Create one controlled production-prefix directory in system temp during app runtime; confirm assertion still triggers.

### Task 4: Documentation + Guardrails

**Files:**
- Modify: `docs/superpowers/specs/2026-04-05-esviritu-escaped-temp-dir-guard-design.md` (if implementation differs)
- Optional: add short note in test file comments

- [ ] Update docs if implementation details diverge from spec.
- [ ] Add short inline comments explaining why test prefixes are excluded and why teardown tracking is required.
- [ ] Ensure no production behavior changes outside DEBUG scanner logic.

---

## Exit Criteria

1. No app crash from `esviritu-test-*` directories.
2. EsViritu tests leave no leaked temp fixtures.
3. Real escaped production prefixes in system temp still trigger debug assertion.
