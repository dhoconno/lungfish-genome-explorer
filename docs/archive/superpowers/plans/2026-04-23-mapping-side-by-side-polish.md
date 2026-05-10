# Mapping Side-by-Side Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix narrow split-view overdraw, avoid unnecessary full reference copies in mapping analysis bundles, restore type-aware variant column filters, and expose BAM files from alignment track context menus.

**Architecture:** Keep viewer layout fixes local to the AppKit views that currently draw or constrain overlapping controls. Keep mapping bundle display prep in the app layer, producing an analysis-local bundle that points at original immutable assets and owns only the new alignment tracks. Keep INFO type detection in `VariantDatabase` so all UI callers receive accurate metadata.

**Tech Stack:** Swift, AppKit, SQLite, XCTest.

---

### Task 1: INFO Type Inference

**Files:**
- Modify: `Sources/LungfishIO/Bundles/VariantDatabase.swift`
- Test: `Tests/LungfishAppTests/AnnotationTableDrawerVariantTests.swift`

- [ ] **Step 1: Write the failing test**

Add a test that imports a VCF without `##INFO` definitions, materializes INFO, builds an `AnnotationSearchIndex`, and asserts numeric fields such as `AF` and `DP` are typed as `Float`/`Integer`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AnnotationTableDrawerVariantTests/testMaterializedInferredInfoKeysPreserveNumericTypes`

- [ ] **Step 3: Implement minimal code**

Track sampled values while materializing INFO and write inferred `variant_info_defs` types instead of always writing `String`.

- [ ] **Step 4: Run the focused tests**

Run: `swift test --filter AnnotationTableDrawerVariantTests`

### Task 2: Alignment Context Menu

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`
- Test: add focused unit coverage where helpers can be pure/internal.

- [ ] **Step 1: Write the failing test**

Add coverage for resolving active alignment track display titles and BAM paths for one-track and all-tracks modes.

- [ ] **Step 2: Implement minimal code**

Add a right-click menu on the rendered alignment area with `Show BAM in Finder` for one active track or a submenu for multiple active tracks.

### Task 3: Lightweight Mapping Viewer Bundle

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Create or modify test support as needed for bundle preparation behavior.

- [ ] **Step 1: Write the failing test**

Exercise bundle preparation with a reference bundle containing genome/variant assets and assert the analysis-local viewer bundle links or clones those assets instead of copying the full source bundle directory.

- [ ] **Step 2: Implement minimal code**

Build a fresh bundle directory, copy only the manifest, attach the imported BAM, and link immutable data subdirectories/files from the source bundle with fallback copy.

### Task 4: Narrow Pane Layout

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/EnhancedCoordinateRulerView.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift`
- Modify if needed: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`

- [ ] **Step 1: Write focused layout tests where feasible**

Add pure helper coverage for ruler label visibility/truncation decisions at narrow and wide widths.

- [ ] **Step 2: Implement minimal code**

Reserve ruler info-bar space around controls, truncate/hide secondary text at narrow widths, and compact or overflow low-priority drawer controls when panes are narrow.

### Task 5: Verification

- [ ] Run focused XCTest filters for touched behavior.
- [ ] Run a full build or full test target if feasible.
- [ ] Inspect `git diff` for unrelated edits before reporting results.
