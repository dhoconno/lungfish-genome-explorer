# Genotype Palette and View Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add dual quick palettes, a persisted haplotype/genotype summary toggle, and haplotype color overrides with a debug build.

**Architecture:** Reuse the existing genotype display view model and sidecar settings for inspector-driven state. Add a small palette provider in genotype UI for `mcm` and `generic` swatches, keep the current matrix style request pipeline, and extend haplotype definition data with an optional color override while preserving `colorTokenIndex`.

**Tech Stack:** Swift 6, SwiftUI inspector sections, AppKit genotype result controller, Codable sidecar and haplotype definition models, XCTest.

---

### Task 1: Dual Matrix Annotation Palettes

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeMatrixAnnotationSection.swift`
- Test: `Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift`

- [ ] Add `matrixMCMQuickPaletteColors` and `matrixGenericQuickPaletteColors` to the genotype display view model. `mcm` returns `HaplotypeColorToken.canonicalBudde2010Tokens.map(\.fillColor)`. `generic` returns the 64 optimized hex colors as `AnnotationColor` values.
- [ ] Update `GenotypeMatrixAnnotationSection` to render two visible swatch groups labeled `mcm` and `generic`. Both groups call `applyMatrixPaletteColor`.
- [ ] Update tests to assert palette counts are 8 and 64, and that generic swatches apply to fill/text/border targets.

### Task 2: Persisted Haplotype/Genotype Summary Toggle

**Files:**
- Modify: `Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Test: `Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift`

- [ ] Add `preferredSummaryViewMode: String?` to `GenotypeAnnotationSidecar.Settings`, defaulting to `nil`.
- [ ] On genotype result configuration, use the sidecar preferred mode when present; otherwise keep the current default: haplotyping/outline for haplotyped results and matrix for genotype-only results.
- [ ] Add a view-model callback for toggling the summary mode from the inspector, and persist the new mode to sidecar settings when changed.
- [ ] Render a compact inspector button when haplotyping is available. It toggles between `Show genotype matrix` and `Show haplotyping view`.
- [ ] Add tests for default haplotyping view, persisted matrix preference, and toggle callback state updates.

### Task 3: Haplotype Definition Color Overrides

**Files:**
- Modify: `Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalysis.swift`
- Modify: `Sources/LungfishCore/Genotype/HaplotypeColorToken.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeHaplotypeDefinitionEditor.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeHaplotypeDefinitionMatrixView.swift`
- Test: `Tests/LungfishCoreTests/HaplotypeColorTokenTests.swift`
- Test: `Tests/LungfishIOTests/GenotypeHaplotypeAnalyzerTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] Add `colorOverride: AnnotationColor?` to `GenotypeHaplotypeDefinition`, keeping all existing initializers source-compatible by defaulting it to `nil`.
- [ ] Add `effectiveColorToken` or `effectiveFillColor` helper that prefers `colorOverride` over `HaplotypeColorToken.canonicalPalette[colorTokenIndex]`.
- [ ] Update drafting and editor mutation paths to preserve `colorOverride`.
- [ ] Add compact per-haplotype color controls: current chip, `mcm` swatches, `generic` swatches, and `ColorPicker`.
- [ ] Update haplotype definition matrix rendering to use the effective color.
- [ ] Add Codable round-trip and legacy-decode tests.

### Task 4: Verification and Debug Build

**Files:**
- No source files expected beyond Tasks 1-3.

- [ ] Run focused tests:
  `swift test --filter 'GenotypeResultDisplaySectionTests|GenotypeResultViewportTests|HaplotypeColorTokenTests|GenotypeHaplotypeAnalyzerTests'`
- [ ] Run whitespace validation:
  `git diff --check`
- [ ] Build Debug app:
  `xcodebuild -project Lungfish.xcodeproj -scheme Lungfish -configuration Debug -destination 'platform=macOS' build`
- [ ] Verify signature:
  `codesign --verify --deep --strict --verbose=2 /Users/dho/Library/Developer/Xcode/DerivedData/Lungfish-dezgndsfxnngnefsbasncdypmyyp/Build/Products/Debug/Lungfish.app`
- [ ] Commit implementation.
