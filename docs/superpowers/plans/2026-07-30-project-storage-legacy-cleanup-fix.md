# Project Storage Legacy Cleanup Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Manage Project Storage safely clean application-produced legacy
workbook archives and staging data that the current classifier incorrectly
retains.

**Architecture:** Correct workbook authority resolution at the classifier.
Add one shared legacy-workflow authority parser used by scanning and execution.
Represent manual-review cleanup separately from proven and blocked entries so
the UI can expose it without automatic selection or automatic cleanup.

**Tech Stack:** Swift, AppKit, Foundation, XCTest, Lungfish provenance and
no-follow filesystem utilities.

---

### Task 1: Correct historical workbook archive authority

**Files:**
- Modify: `Sources/LungfishWorkflow/Storage/ProjectStorageLegacyWorkbookClassifier.swift`
- Test: `Tests/LungfishWorkflowTests/ProjectStorageScannerTests.swift`

- [ ] Add a failing fixture with repeated historical `current.xlsx`
  descriptors and one checksum-verified retained live revision.
- [ ] Verify it fails because the classifier requires a unique path entry.
- [ ] Select the last matching archived current descriptor, verify archived
  and retained payload SHA-256 values, and count matching live bundles.
- [ ] Add same-size tampering and duplicate-live-bundle negative coverage.
- [ ] Run the focused scanner tests and commit.

### Task 2: Classify legacy workflow staging safely

**Files:**
- Create: `Sources/LungfishWorkflow/Storage/ProjectStorageLegacyWorkflowAuthority.swift`
- Modify: `Sources/LungfishWorkflow/Storage/ProjectStorageModels.swift`
- Modify: `Sources/LungfishWorkflow/Storage/ProjectStorageScanner.swift`
- Test: `Tests/LungfishWorkflowTests/ProjectStorageScannerTests.swift`

- [ ] Add failing exact-name parser tests for root, cohort, candidate, and
  malformed lookalike names.
- [ ] Add failing classification tests for valid final bundles, valid failed
  provenance, explicit retention, held/missing locks, and unverified legacy
  work.
- [ ] Implement the shared parser, bounded no-follow provenance reader, and
  classification rules.
- [ ] Add `reviewRequired` disposition and
  `legacyUnverifiedOwnedWork` code while preserving proven-only reclaimable
  totals.
- [ ] Run the focused scanner tests and commit.

### Task 3: Execute selected legacy cleanup under its run lock

**Files:**
- Modify: `Sources/LungfishWorkflow/Storage/ProjectStorageCleanupExecutor.swift`
- Test: `Tests/LungfishWorkflowTests/ProjectStorageCleanupExecutorTests.swift`
- Test: `Tests/LungfishWorkflowTests/ProjectStorageCleanupProvenanceTests.swift`

- [ ] Add a failing execution test for a selected review-required legacy item
  with no marker and an unlocked derived run lock.
- [ ] Add a failing race test where the lock becomes held or classification
  changes before detach.
- [ ] Acquire the parser-derived historical run lock for markerless legacy
  staging and hold it through the existing detach/Trash sequence.
- [ ] Verify inventory, journal, provenance, cancellation, and recovery tests.
- [ ] Commit.

### Task 4: Present legacy review separately and unchecked

**Files:**
- Modify: `Sources/LungfishApp/Views/ProjectStorage/ProjectStorageSheetViewModel.swift`
- Modify: `Sources/LungfishApp/Views/ProjectStorage/ProjectStorageSheetViewController.swift`
- Test: `Tests/LungfishAppTests/ProjectStorageSheetViewModelTests.swift`

- [ ] Add failing tests for the new checkable review section, unchecked initial
  state, explanatory status, selection totals, and accessibility language.
- [ ] Split proven, review-required, and blocked entries in the view model.
- [ ] Preserve default selection for proven entries only.
- [ ] Verify Return/Escape, read-only projects, retry, and partial-failure
  behavior.
- [ ] Commit.

### Task 5: Cumulative verification and debug app

**Files:**
- Modify only if a regression is discovered in the files above.

- [ ] Run ProjectStorage scanner, executor, provenance, automatic-cleanup,
  view-model, accessibility, and performance tests.
- [ ] Confirm automatic cleanup never selects review-required entries.
- [ ] Run `git diff --check`.
- [ ] Build the arm64 debug app, package it, and verify its signature.
- [ ] Inspect the real project read-only and report the entries the corrected
  rules would expose; do not mutate the user’s project during verification.

