# Lungfishgenotype Viewport and Inspector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace QuickLook-only `.lungfishgenotype` display with a native genotype result viewport and Inspector integration.

**Architecture:** Parse bundle artifacts in `LungfishIO`, render them in a new `LungfishApp` result viewport, and route sidebar selection through `ViewerViewController`. The Inspector receives document and selection states from the main split controller and the new viewport callbacks.

**Tech Stack:** Swift 6.2, AppKit, SwiftUI Inspector sections, `XCTest`, existing Lungfish bundle/provenance APIs.

---

## Files

- Modify: `Sources/LungfishCore/Models/Notifications.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Create: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift`
- Create: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultTableView.swift`
- Create: `Sources/LungfishApp/Views/Inspector/Sections/GenotypeResultDocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Create: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Genotype.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift`
- Modify: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`
- Modify: `Tests/LungfishAppTests/InspectorProvenanceTabTests.swift`
- Create: `Tests/LungfishAppTests/GenotypeResultViewportTests.swift`

## Tasks

- [ ] Add failing `LungfishIO` tests that build a temporary `.lungfishgenotype` bundle with genotype CSV, sample CSV, stats JSON, workbook, provenance, and manifest, then assert sample/call summaries and artifact URLs load correctly.
- [ ] Implement `ONTGenotypeResultBundleData`, CSV parsing, numeric parsing, stats loading, QC status derivation, artifact URL helpers, and `loadResult(from:)`.
- [ ] Add failing App tests for genotype content mode provenance availability, genotype document state reset behavior, and viewport configuration with sample selection callbacks.
- [ ] Add `.genotype` content mode and update toolbar/provenance/Inspector tab availability.
- [ ] Add genotype document and selection Inspector states and SwiftUI sections.
- [ ] Add the genotype result viewport with analyst, consumer, and artifact lenses.
- [ ] Route `.lungfishgenotype` sidebar selection to the native viewport, wire document and selection Inspector updates, and preserve QuickLook workbook as an artifact action rather than the primary display.
- [ ] Run focused tests, then a broader build/test command suitable for this repo.
