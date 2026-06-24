# LGE Zip Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transparently import ZIP-compressed Lungfish objects by extracting a single recognized LGE object and feeding it into the existing sidebar import pipeline.

**Architecture:** Add a focused `LGEZipImportResolver` in `Sources/LungfishApp/Services` and call it before sidebar/menu import planning. The resolver owns extraction, recognition, error reporting metadata, and temporary cleanup; existing import services continue to copy or install final project payloads.

**Tech Stack:** Swift, XCTest, Foundation `Process` with `/usr/bin/unzip`, existing `ProjectTempDirectory`, existing `GeneiousArchiveTool` safe ZIP member validation.

---

### Task 1: Resolver Service

**Files:**
- Create: `Sources/LungfishApp/Services/LGEZipImportResolver.swift`
- Test: `Tests/LungfishAppTests/LGEZipImportResolverTests.swift`

- [ ] Write failing tests for `.lungfishmhcref.zip` resolution, temp cleanup, non-LGE ZIP rejection, and ambiguous multiple-object rejection.
- [ ] Run `swift test --filter LGEZipImportResolverTests` and verify the tests fail because the service does not exist.
- [ ] Implement `LGEZipImportResolver` with safe member validation, project-local temp extraction, single-object discovery, and cleanup.
- [ ] Run `swift test --filter LGEZipImportResolverTests` and verify it passes.

### Task 2: Import Pipeline Wiring

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate+MenuActions.swift`
- Test: `Tests/LungfishAppTests/MainSplitSidebarDropRoutingTests.swift` or `Tests/LungfishAppTests/SidebarImportPlannerTests.swift`

- [ ] Add a failing test showing a ZIP archive is resolved before sidebar planning and non-LGE ZIPs report failed imports instead of being copied as generic files.
- [ ] Run the focused test and verify the expected failure.
- [ ] Wire resolver output into drag/drop and file-panel import flows before `makeSidebarImportPlan`.
- [ ] Run focused tests for the resolver and sidebar import planner.

### Task 3: Verification

**Files:**
- Verify all modified Swift and doc files.

- [ ] Run `swift test --filter LGEZipImportResolverTests`.
- [ ] Run `swift test --filter SidebarImportPlannerTests`.
- [ ] Run `swift test --filter MainSplitSidebarDropRoutingTests` if touched.
- [ ] Run `git diff --check`.
