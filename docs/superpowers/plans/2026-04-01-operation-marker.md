# Shared OperationMarker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a shared `.processing` sentinel so the sidebar hides directories until their creating operation completes, and apply it to every pipeline, import, and derivative operation.

**Architecture:** A new `OperationMarker` enum in LungfishCore provides `markInProgress`/`clearInProgress`/`isInProgress`. FASTQBundle's existing marker delegates to it. Every service that creates a user-visible directory calls `markInProgress` after creation and `clearInProgress` via `defer` on success. The sidebar's collector methods skip directories where the marker is present.

**Tech Stack:** Swift 6.2, LungfishCore (shared utility), Swift Testing

**Spec:** `docs/superpowers/specs/2026-04-01-operation-marker-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/LungfishCore/Services/OperationMarker.swift` | Create | Shared marker utility |
| `Tests/LungfishCoreTests/OperationMarkerTests.swift` | Create | Unit tests for marker |
| `Sources/LungfishIO/Formats/FASTQ/FASTQBundle.swift` | Modify | Delegate to OperationMarker |
| `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` | Modify | Add isInProgress checks in collectors |
| `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift` | Modify | Add marker to all 4 import methods |
| `Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift` | Modify | Add marker around runPipeline |
| `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift` | Modify | Add marker around detect |
| `Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift` | Modify | Add marker around run |
| `Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift` | Modify | Add marker around run |
| `Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift` | Modify | Add marker around run |
| `Sources/LungfishApp/Services/FASTQDerivativeService.swift` | Modify | Add marker for derivative bundles |
| `Sources/LungfishApp/Services/BAMImportService.swift` | Modify | Add marker for alignment dir |
| `Sources/LungfishApp/Services/ReferenceBundleImportService.swift` | Modify | Add marker for ref bundle |

---

## Task 1: Create OperationMarker Utility + Tests

**Files:**
- Create: `Sources/LungfishCore/Services/OperationMarker.swift`
- Create: `Tests/LungfishCoreTests/OperationMarkerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/LungfishCoreTests/OperationMarkerTests.swift`:

```swift
// OperationMarkerTests.swift — Tests for shared in-progress directory marker
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishCore

struct OperationMarkerTests {

    @Test
    func isInProgressReturnsFalseForUnmarkedDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(!OperationMarker.isInProgress(dir))
    }

    @Test
    func markAndClearRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        OperationMarker.markInProgress(dir, detail: "Importing…")
        #expect(OperationMarker.isInProgress(dir))

        OperationMarker.clearInProgress(dir)
        #expect(!OperationMarker.isInProgress(dir))
    }

    @Test
    func clearInProgressIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Clearing when no marker exists should not throw
        OperationMarker.clearInProgress(dir)
        OperationMarker.clearInProgress(dir)
        #expect(!OperationMarker.isInProgress(dir))
    }

    @Test
    func markerFileUsesProcessingFilename() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        OperationMarker.markInProgress(dir, detail: "Test detail")

        let markerURL = dir.appendingPathComponent(".processing")
        #expect(FileManager.default.fileExists(atPath: markerURL.path))

        let content = try String(contentsOf: markerURL, encoding: .utf8)
        #expect(content == "Test detail")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OperationMarkerTests 2>&1 | tail -10`

Expected: Compilation error — `OperationMarker` doesn't exist.

- [ ] **Step 3: Create OperationMarker.swift**

Create `Sources/LungfishCore/Services/OperationMarker.swift`:

```swift
// OperationMarker.swift — Shared in-progress sentinel for operation output directories
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Manages a `.processing` sentinel file inside directories being built by long-running operations.
///
/// The sidebar hides any directory containing this marker file. This prevents users from
/// seeing incomplete results, broken bundles, or half-written data while an operation is
/// still running.
///
/// ## Convention
///
/// **Every operation that creates a user-visible directory** (result folders, FASTQ bundles,
/// reference bundles, derivative outputs) **MUST** call ``markInProgress(_:detail:)``
/// immediately after directory creation and ``clearInProgress(_:)`` on successful completion.
///
/// The recommended pattern uses `defer` to ensure cleanup:
///
/// ```swift
/// try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
/// OperationMarker.markInProgress(outputDir, detail: "Running classification…")
/// defer { OperationMarker.clearInProgress(outputDir) }
/// // ... long-running work ...
/// ```
///
/// On failure, either clean up the directory entirely (the marker goes with it) or leave
/// the marker so the sidebar ignores the incomplete directory.
public enum OperationMarker {

    /// Sentinel filename placed inside directories that are still being built.
    public static let filename = ".processing"

    /// Returns `true` when the directory contains the `.processing` sentinel file.
    public static func isInProgress(_ directoryURL: URL) -> Bool {
        let markerURL = directoryURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// Writes the `.processing` sentinel file into the directory.
    ///
    /// - Parameters:
    ///   - directoryURL: The directory to mark as in-progress.
    ///   - detail: Human-readable description of the operation (e.g., "Importing Kraken2 results…").
    public static func markInProgress(_ directoryURL: URL, detail: String = "Processing\u{2026}") {
        let markerURL = directoryURL.appendingPathComponent(filename)
        try? detail.data(using: .utf8)?.write(to: markerURL, options: .atomic)
    }

    /// Removes the `.processing` sentinel file, marking the directory as ready.
    ///
    /// Safe to call when no marker exists (no-op).
    public static func clearInProgress(_ directoryURL: URL) {
        let markerURL = directoryURL.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: markerURL)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter OperationMarkerTests 2>&1 | tail -10`

Expected: All 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishCore/Services/OperationMarker.swift Tests/LungfishCoreTests/OperationMarkerTests.swift
git commit -m "feat: add shared OperationMarker utility for in-progress directory hiding"
```

---

## Task 2: Refactor FASTQBundle to Delegate to OperationMarker

**Files:**
- Modify: `Sources/LungfishIO/Formats/FASTQ/FASTQBundle.swift:290-336`

- [ ] **Step 1: Replace FASTQBundle marker implementation**

In `Sources/LungfishIO/Formats/FASTQ/FASTQBundle.swift`, replace the processing marker section (lines 290-336). The file needs `import LungfishCore` at the top (check if it's already there; if not, add it).

Replace lines 290-336:

```swift
    /// Sentinel filename written inside a `.lungfishfastq` bundle to indicate
    /// that the bundle is still being processed (ingestion, post-import recipe, etc.).
    ///
    /// The sidebar checks for this file and shows a "Processing..." badge.
    /// The file is removed when processing completes (success or failure).
    public static let processingMarkerFilename = ".processing"

    /// Processing state of a FASTQ bundle.
    public enum ProcessingState: Sendable, Equatable {
        /// Bundle is fully ready for use.
        case ready
        /// Bundle is being imported or preprocessed. The associated string
        /// is a human-readable description (e.g. "Importing...", "Running VSP2 recipe...").
        case processing(detail: String)
    }

    /// Reads the processing state of a bundle by checking for the sentinel file.
    public static func processingState(of bundleURL: URL) -> ProcessingState {
        let markerURL = bundleURL.appendingPathComponent(processingMarkerFilename)
        guard let data = try? Data(contentsOf: markerURL),
              let detail = String(data: data, encoding: .utf8) else {
            return .ready
        }
        return .processing(detail: detail.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Returns `true` when the bundle has a `.processing` marker file.
    public static func isProcessing(_ bundleURL: URL) -> Bool {
        let markerURL = bundleURL.appendingPathComponent(processingMarkerFilename)
        return FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// Writes the `.processing` sentinel file into the bundle.
    ///
    /// Call this as soon as the bundle directory is created but before
    /// the long-running pipeline starts. The FileSystemWatcher will see
    /// the bundle directory and the sidebar will display a processing badge.
    public static func markProcessing(_ bundleURL: URL, detail: String = "Processing\u{2026}") {
        let markerURL = bundleURL.appendingPathComponent(processingMarkerFilename)
        try? detail.data(using: .utf8)?.write(to: markerURL, options: .atomic)
    }

    /// Removes the `.processing` sentinel file, marking the bundle as ready.
    public static func clearProcessing(_ bundleURL: URL) {
        let markerURL = bundleURL.appendingPathComponent(processingMarkerFilename)
        try? FileManager.default.removeItem(at: markerURL)
    }
```

With this delegating version:

```swift
    /// Sentinel filename written inside a `.lungfishfastq` bundle to indicate
    /// that the bundle is still being processed (ingestion, post-import recipe, etc.).
    ///
    /// Delegates to the shared ``OperationMarker`` utility.
    public static var processingMarkerFilename: String { OperationMarker.filename }

    /// Processing state of a FASTQ bundle.
    public enum ProcessingState: Sendable, Equatable {
        /// Bundle is fully ready for use.
        case ready
        /// Bundle is being imported or preprocessed. The associated string
        /// is a human-readable description (e.g. "Importing...", "Running VSP2 recipe...").
        case processing(detail: String)
    }

    /// Reads the processing state of a bundle by checking for the sentinel file.
    public static func processingState(of bundleURL: URL) -> ProcessingState {
        let markerURL = bundleURL.appendingPathComponent(OperationMarker.filename)
        guard let data = try? Data(contentsOf: markerURL),
              let detail = String(data: data, encoding: .utf8) else {
            return .ready
        }
        return .processing(detail: detail.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Returns `true` when the bundle has a `.processing` marker file.
    public static func isProcessing(_ bundleURL: URL) -> Bool {
        OperationMarker.isInProgress(bundleURL)
    }

    /// Writes the `.processing` sentinel file into the bundle.
    public static func markProcessing(_ bundleURL: URL, detail: String = "Processing\u{2026}") {
        OperationMarker.markInProgress(bundleURL, detail: detail)
    }

    /// Removes the `.processing` sentinel file, marking the bundle as ready.
    public static func clearProcessing(_ bundleURL: URL) {
        OperationMarker.clearInProgress(bundleURL)
    }
```

- [ ] **Step 2: Ensure LungfishIO imports LungfishCore**

Check if `Sources/LungfishIO/Formats/FASTQ/FASTQBundle.swift` already imports `LungfishCore`. If not, add `import LungfishCore` at the top of the file.

- [ ] **Step 3: Build and run existing tests**

Run: `swift build --build-tests 2>&1 | tail -5`

Then run the FASTQ-related tests to verify no regressions:

Run: `swift test 2>&1 | tail -10`

Expected: All tests pass — the delegation is transparent.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishIO/Formats/FASTQ/FASTQBundle.swift
git commit -m "refactor: FASTQBundle processing marker delegates to shared OperationMarker"
```

---

## Task 3: Add Sidebar Filtering for In-Progress Directories

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`

- [ ] **Step 1: Add import**

Add `import LungfishCore` at the top of `SidebarViewController.swift` if not already present.

- [ ] **Step 2: Add isInProgress guard in collectClassificationResults**

At line 1128, after:
```swift
            guard childURL.lastPathComponent.hasPrefix("classification-") else { continue }
```

Add:
```swift
            guard !OperationMarker.isInProgress(childURL) else { continue }
```

- [ ] **Step 3: Add isInProgress guard in collectClassificationBatchResults**

At line 1170, after:
```swift
            guard batchDir.lastPathComponent.hasPrefix("classification-batch-") else { continue }
```

Add:
```swift
            guard !OperationMarker.isInProgress(batchDir) else { continue }
```

- [ ] **Step 4: Add isInProgress guard in collectEsVirituResults**

At line 1270, after:
```swift
            guard childURL.lastPathComponent.hasPrefix("esviritu-") else { continue }
```

Add:
```swift
            guard !OperationMarker.isInProgress(childURL) else { continue }
```

- [ ] **Step 5: Add isInProgress guard in collectEsVirituBatchResults**

At line 1312, after:
```swift
            guard batchDir.lastPathComponent.hasPrefix("esviritu-batch-") else { continue }
```

Add:
```swift
            guard !OperationMarker.isInProgress(batchDir) else { continue }
```

- [ ] **Step 6: Add isInProgress guard in collectTaxTriageResults**

At line 1397, after:
```swift
            guard childURL.lastPathComponent.hasPrefix("taxtriage-") else { continue }
```

Add:
```swift
            guard !OperationMarker.isInProgress(childURL) else { continue }
```

- [ ] **Step 7: Add isInProgress guard in collectNaoMgsResults**

At line 1571, after:
```swift
            guard childURL.lastPathComponent.hasPrefix("naomgs-") else { continue }
```

Add:
```swift
            guard !OperationMarker.isInProgress(childURL) else { continue }
```

- [ ] **Step 8: Build**

Run: `swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 9: Commit**

```bash
git add Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift
git commit -m "feat: sidebar hides in-progress directories via OperationMarker"
```

---

## Task 4: Add Marker to MetagenomicsImportService (All 4 Import Methods)

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift`

The file already imports `LungfishCore` (line 6).

- [ ] **Step 1: Add marker to importKraken2**

After line 160 (`try ensureDirectoryExists(resultDirectory)`), add:

```swift
        OperationMarker.markInProgress(resultDirectory, detail: "Importing Kraken2 results\u{2026}")
        defer { OperationMarker.clearInProgress(resultDirectory) }
```

- [ ] **Step 2: Add marker to importEsViritu**

After line 248 (`try ensureDirectoryExists(resultDirectory)`), add:

```swift
        OperationMarker.markInProgress(resultDirectory, detail: "Importing EsViritu results\u{2026}")
        defer { OperationMarker.clearInProgress(resultDirectory) }
```

- [ ] **Step 3: Add marker to importTaxTriage**

After line 341 (`try ensureDirectoryExists(resultDirectory)`), add:

```swift
        OperationMarker.markInProgress(resultDirectory, detail: "Importing TaxTriage results\u{2026}")
        defer { OperationMarker.clearInProgress(resultDirectory) }
```

- [ ] **Step 4: Add marker to importNaoMgs**

In `importNaoMgs`, after the result directory is created (after line 456 `try ensureDirectoryExists(resultDirectory)`), add:

```swift
        OperationMarker.markInProgress(resultDirectory, detail: "Importing NAO-MGS results\u{2026}")
        defer { OperationMarker.clearInProgress(resultDirectory) }
```

Note: the `defer` goes BEFORE the existing `do { ... } catch { throw .importAborted(...) }` block so the marker is cleared on both success and error paths.

- [ ] **Step 5: Run existing import tests**

Run: `swift test --filter MetagenomicsImportServiceTests 2>&1 | tail -10`

Expected: All 4 existing tests pass. The marker is written and cleared within each test's lifecycle.

Run: `swift test --filter NaoMgsImportOptimization 2>&1 | tail -10`

Expected: All 8 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift
git commit -m "feat: add OperationMarker to all MetagenomicsImportService methods"
```

---

## Task 5: Add Marker to Pipeline Services

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift`
- Modify: `Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift`

Each pipeline file needs `import LungfishCore` if not already present.

- [ ] **Step 1: ClassificationPipeline**

In `Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift`, in the `runPipeline()` method, after the directory creation (around line 205-208, where `FileManager.default.createDirectory(at: config.outputDirectory, ...)` is called), add:

```swift
        OperationMarker.markInProgress(config.outputDirectory, detail: "Running Kraken2 classification\u{2026}")
        defer { OperationMarker.clearInProgress(config.outputDirectory) }
```

- [ ] **Step 2: EsVirituPipeline**

In `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift`, in the `detect()` method, after the directory creation (around line 351-354, where `FileManager.default.createDirectory(at: config.outputDirectory, ...)` is called), add:

```swift
        OperationMarker.markInProgress(config.outputDirectory, detail: "Running EsViritu detection\u{2026}")
        defer { OperationMarker.clearInProgress(config.outputDirectory) }
```

- [ ] **Step 3: TaxTriagePipeline**

In `Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift`, in the `run()` method, after the primary output directory creation (around line 203-206), add:

```swift
        OperationMarker.markInProgress(profileAdjustedConfig.outputDirectory, detail: "Running TaxTriage\u{2026}")
        defer { OperationMarker.clearInProgress(profileAdjustedConfig.outputDirectory) }
```

Check: if the function uses `effectiveConfig.outputDirectory` as the final output and it differs from the original, make sure the marker is on the directory the sidebar will see. Read the function to confirm which variable holds the user-visible directory.

- [ ] **Step 4: SPAdesAssemblyPipeline**

In `Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift`, in the `run()` method, after workspace creation (around line 195 where `createWorkspace()` returns), add the marker on the output directory:

```swift
        OperationMarker.markInProgress(workspace.outputDir, detail: "Running SPAdes assembly\u{2026}")
        defer { OperationMarker.clearInProgress(workspace.outputDir) }
```

Read the file to confirm the correct variable name for the output directory.

- [ ] **Step 5: Minimap2Pipeline**

In `Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift`, in the `run()` method, after directory creation at line 376 (`FileManager.default.createDirectory(at: config.outputDirectory, ...)`), add:

```swift
        OperationMarker.markInProgress(config.outputDirectory, detail: "Running minimap2 alignment\u{2026}")
        defer { OperationMarker.clearInProgress(config.outputDirectory) }
```

- [ ] **Step 6: Build**

Run: `swift build --build-tests 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift
git commit -m "feat: add OperationMarker to all pipeline services"
```

---

## Task 6: Add Marker to FASTQ Derivative, BAM Import, and Reference Import Services

**Files:**
- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService.swift`
- Modify: `Sources/LungfishApp/Services/BAMImportService.swift`
- Modify: `Sources/LungfishApp/Services/ReferenceBundleImportService.swift`

Each file needs `import LungfishCore` if not already present.

- [ ] **Step 1: FASTQDerivativeService**

In `Sources/LungfishApp/Services/FASTQDerivativeService.swift`, find where derivative bundle output directories are created (around line 1183 for demux output). After the `createDirectory` call for the output directory, add:

```swift
        OperationMarker.markInProgress(outputDirectory, detail: "Creating derivative FASTQ\u{2026}")
```

And add `OperationMarker.clearInProgress(outputDirectory)` after the derivative pipeline completes successfully.

Read the file carefully — there may be multiple directory creation points for different derivative types (orient, demux, subset, trim). Add the marker to each one. Use `defer` where the function structure allows it. If the function has multiple return paths, ensure `clearInProgress` is called on each success path.

- [ ] **Step 2: BAMImportService**

In `Sources/LungfishApp/Services/BAMImportService.swift`, after the alignment directory creation at line 81, add:

```swift
        OperationMarker.markInProgress(alignmentsDir, detail: "Importing BAM alignment\u{2026}")
        defer { OperationMarker.clearInProgress(alignmentsDir) }
```

- [ ] **Step 3: ReferenceBundleImportService**

In `Sources/LungfishApp/Services/ReferenceBundleImportService.swift`, after the output directory creation at line 167, add:

```swift
        OperationMarker.markInProgress(outputDirectory, detail: "Importing reference bundle\u{2026}")
        defer { OperationMarker.clearInProgress(outputDirectory) }
```

Note: this file already has a temp directory with `defer` cleanup at line 175. The marker goes on the user-visible output directory, not the temp directory.

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/FASTQDerivativeService.swift Sources/LungfishApp/Services/BAMImportService.swift Sources/LungfishApp/Services/ReferenceBundleImportService.swift
git commit -m "feat: add OperationMarker to derivative, BAM import, and reference import services"
```

---

## Task 7: Run Full Test Suite

- [ ] **Step 1: Run all tests**

Run: `swift test 2>&1 | tail -30`

Expected: All tests pass. The markers are written and cleared within each test's lifecycle, so they don't affect test behavior.

- [ ] **Step 2: Verify no stale markers in test temp directories**

The `defer` pattern ensures markers are always cleaned up. If any test creates a directory and uses `OperationMarker.markInProgress`, the `defer { try? FileManager.default.removeItem(at: workspace) }` in the test cleans up the entire directory including the marker.

- [ ] **Step 3: Fix any regressions**

If any tests fail, check:
- Did a pipeline test expect to find a file that's now a `.processing` marker? (Unlikely — markers are hidden files)
- Did the FASTQBundle refactor break a test that checks `processingMarkerFilename`? (Should be transparent)

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: address test regressions from OperationMarker integration"
```
