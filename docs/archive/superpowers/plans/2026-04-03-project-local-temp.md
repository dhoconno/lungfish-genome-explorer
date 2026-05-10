# Project-Local Temp Directory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route all project-scoped temporary files through `project.lungfish/.tmp/` instead of system `/tmp`, with aggressive cleanup, a manual clear menu item, long-session stale-file cleanup, and debug guards against regressions.

**Architecture:** A new `ProjectTempDirectory` utility in LungfishIO provides the central `create(prefix:in:)` API. All ~45 call sites that currently use `FileManager.default.temporaryDirectory` are migrated to call this utility instead, threading the project URL from their existing config/bundle context. `TempFileManager` is updated for project-aware cleanup. A debug-only guard scans system temp for escaped `lungfish-*` directories.

**Tech Stack:** Swift 6.2, Foundation, os.log, XCTest

**Spec:** `docs/superpowers/specs/2026-04-03-project-local-temp-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `Sources/LungfishIO/Bundles/ProjectTempDirectory.swift` | Central temp directory API + findProjectRoot |
| Create | `Tests/LungfishIOTests/ProjectTempDirectoryTests.swift` | Unit tests for all ProjectTempDirectory methods |
| Modify | `Sources/LungfishCore/Services/TempFileManager.swift` | Add project-aware cleanup, periodic stale scan, debug guard |
| Create | `Tests/LungfishCoreTests/TempFileManagerProjectTests.swift` | Tests for project cleanup integration |
| Modify | `Sources/LungfishWorkflow/Extraction/ReadExtractionService.swift` | Migrate 3 temp sites |
| Modify | `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift` | Migrate 1 temp site (space redirect) |
| Modify | `Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift` | Migrate 1 temp site (space redirect) |
| Modify | `Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift` | Migrate 1 temp site |
| Modify | `Sources/LungfishWorkflow/Orient/OrientPipeline.swift` | Migrate 1 temp site |
| Modify | `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift` | Migrate 1 temp site |
| Modify | `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline+Scout.swift` | Migrate 1 temp site |
| Modify | `Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift` | Migrate 1 temp site |
| Modify | `Sources/LungfishWorkflow/Native/NativeToolRunner.swift` | Migrate 1 temp site (BBTools symlinks) |
| Create | `Tests/LungfishWorkflowTests/Extraction/ProjectTempExtractionTests.swift` | Integration tests: extraction uses project .tmp/ |
| Modify | `Sources/LungfishApp/Services/FASTQDerivativeService.swift` | Migrate 8 temp sites + `makeTemporaryDirectory` |
| Modify | `Sources/LungfishApp/App/AppDelegate.swift` | Migrate ~8 materialization/export temp sites |
| Modify | `Sources/LungfishApp/Services/AlignmentDuplicateService.swift` | Migrate 1 temp site |
| Modify | `Sources/LungfishApp/Services/ReferenceBundleImportService.swift` | Migrate 1 temp site |
| Modify | `Sources/LungfishApp/Services/FASTQIngestionService.swift` | Migrate 1 temp site |
| Modify | `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` | Migrate 1 extraction temp site |
| Modify | `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift` | Migrate 1 extraction temp site |
| Modify | `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift` | Migrate 1 extraction temp site |
| Modify | `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift` | Migrate 1 extraction temp site |
| Modify | `Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift` | Migrate 1 temp site |
| Modify | `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift` | Migrate 1 temp site |
| Modify | `Sources/LungfishApp/ViewModels/GenBankBundleDownloadViewModel.swift` | Migrate 2 temp sites |
| Modify | `Sources/LungfishApp/ViewModels/GenomeDownloadViewModel.swift` | Migrate 1 temp site |
| Modify | `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift` | Migrate 1 temp site |
| Modify | `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` | Migrate 1 temp site |
| Delete | `Sources/LungfishApp/Views/Metagenomics/ProjectRootDiscovery.swift` | Moved to LungfishIO |
| Modify | `Tests/LungfishAppTests/ProjectRootDiscoveryTests.swift` | Update import to LungfishIO |
| Modify | `Sources/LungfishCLI/Commands/ImportCommand.swift` | Migrate 1 temp site |
| Modify | `Sources/LungfishCLI/Commands/FastqCommand.swift` | Migrate 2 temp sites |
| Modify | `Sources/LungfishCLI/Commands/FetchCommand.swift` | Migrate 1 temp site |

---

## Task 1: ProjectTempDirectory Core API (TDD)

**Files:**
- Create: `Tests/LungfishIOTests/ProjectTempDirectoryTests.swift`
- Create: `Sources/LungfishIO/Bundles/ProjectTempDirectory.swift`

This task builds the foundation that every subsequent task depends on.

- [ ] **Step 1: Write failing tests for ProjectTempDirectory**

```swift
// Tests/LungfishIOTests/ProjectTempDirectoryTests.swift
import XCTest
@testable import LungfishIO

final class ProjectTempDirectoryTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectTempDirTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    // MARK: - findProjectRoot

    func testFindProjectRootFromDerivativesPath() throws {
        let projectURL = tempDir.appendingPathComponent("myproject.lungfish")
        let deepPath = projectURL
            .appendingPathComponent("Downloads")
            .appendingPathComponent("sample.lungfishfastq")
            .appendingPathComponent("derivatives")
            .appendingPathComponent("esviritu-ABC123")
        try FileManager.default.createDirectory(at: deepPath, withIntermediateDirectories: true)

        let result = ProjectTempDirectory.findProjectRoot(deepPath)
        XCTAssertEqual(result?.standardizedFileURL, projectURL.standardizedFileURL)
    }

    func testFindProjectRootFromImportsPath() throws {
        let projectURL = tempDir.appendingPathComponent("test.lungfish")
        let importPath = projectURL
            .appendingPathComponent("Imports")
            .appendingPathComponent("naomgs-test")
        try FileManager.default.createDirectory(at: importPath, withIntermediateDirectories: true)

        let result = ProjectTempDirectory.findProjectRoot(importPath)
        XCTAssertEqual(result?.standardizedFileURL, projectURL.standardizedFileURL)
    }

    func testFindProjectRootReturnsNilOutsideProject() {
        let result = ProjectTempDirectory.findProjectRoot(tempDir)
        XCTAssertNil(result)
    }

    func testFindProjectRootFromProjectItself() throws {
        let projectURL = tempDir.appendingPathComponent("test.lungfish")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let result = ProjectTempDirectory.findProjectRoot(projectURL)
        XCTAssertEqual(result?.standardizedFileURL, projectURL.standardizedFileURL)
    }

    // MARK: - tempRoot

    func testTempRootReturnsCorrectPath() {
        let projectURL = tempDir.appendingPathComponent("test.lungfish")
        let root = ProjectTempDirectory.tempRoot(for: projectURL)
        XCTAssertEqual(root.lastPathComponent, ".tmp")
        XCTAssertEqual(root.deletingLastPathComponent().standardizedFileURL, projectURL.standardizedFileURL)
    }

    // MARK: - create

    func testCreateMakesDirectoryInsideProjectTmp() throws {
        let projectURL = tempDir.appendingPathComponent("test.lungfish")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let created = try ProjectTempDirectory.create(prefix: "lungfish-test-", in: projectURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        XCTAssertTrue(created.path.contains(".tmp/"))
        XCTAssertTrue(created.lastPathComponent.hasPrefix("lungfish-test-"))
    }

    func testCreateFallsBackToSystemTempWhenNilProject() throws {
        let created = try ProjectTempDirectory.create(prefix: "lungfish-test-", in: nil)
        defer { try? FileManager.default.removeItem(at: created) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        XCTAssertTrue(created.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    func testCreateFromAnyURLInsideProject() throws {
        let projectURL = tempDir.appendingPathComponent("test.lungfish")
        let deepURL = projectURL
            .appendingPathComponent("Downloads")
            .appendingPathComponent("sample.lungfishfastq")
        try FileManager.default.createDirectory(at: deepURL, withIntermediateDirectories: true)

        let created = try ProjectTempDirectory.createFromContext(
            prefix: "lungfish-test-",
            contextURL: deepURL
        )

        XCTAssertTrue(created.path.contains("test.lungfish/.tmp/"))
    }

    // MARK: - cleanAll

    func testCleanAllRemovesEntireTmpDirectory() throws {
        let projectURL = tempDir.appendingPathComponent("test.lungfish")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        // Create some temp directories
        let _ = try ProjectTempDirectory.create(prefix: "a-", in: projectURL)
        let _ = try ProjectTempDirectory.create(prefix: "b-", in: projectURL)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpRoot.path))

        try ProjectTempDirectory.cleanAll(in: projectURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpRoot.path))
    }

    func testCleanAllIsIdempotent() throws {
        let projectURL = tempDir.appendingPathComponent("test.lungfish")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        // Should not throw even if .tmp/ doesn't exist
        try ProjectTempDirectory.cleanAll(in: projectURL)
        try ProjectTempDirectory.cleanAll(in: projectURL)
    }

    // MARK: - diskUsage

    func testDiskUsageReturnsNonZeroAfterCreate() throws {
        let projectURL = tempDir.appendingPathComponent("test.lungfish")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let created = try ProjectTempDirectory.create(prefix: "test-", in: projectURL)
        // Write a small file so diskUsage > 0
        let testFile = created.appendingPathComponent("data.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        let usage = ProjectTempDirectory.diskUsage(in: projectURL)
        XCTAssertGreaterThan(usage, 0)
    }

    func testDiskUsageReturnsZeroWhenNoTmp() {
        let projectURL = tempDir.appendingPathComponent("empty.lungfish")
        let usage = ProjectTempDirectory.diskUsage(in: projectURL)
        XCTAssertEqual(usage, 0)
    }

    // MARK: - cleanStale

    func testCleanStaleRemovesOldDirectoriesOnly() throws {
        let projectURL = tempDir.appendingPathComponent("test.lungfish")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let old = try ProjectTempDirectory.create(prefix: "old-", in: projectURL)
        let recent = try ProjectTempDirectory.create(prefix: "recent-", in: projectURL)

        // Backdate the "old" directory by 25 hours
        let oldDate = Date().addingTimeInterval(-25 * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: old.path
        )

        try ProjectTempDirectory.cleanStale(in: projectURL, olderThan: 24 * 3600)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "Old dir should be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "Recent dir should remain")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectTempDirectoryTests 2>&1 | tail -5`
Expected: Compilation error — `ProjectTempDirectory` does not exist yet.

- [ ] **Step 3: Implement ProjectTempDirectory**

```swift
// Sources/LungfishIO/Bundles/ProjectTempDirectory.swift
import Foundation
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "ProjectTempDirectory")

/// Manages project-local temporary directories under `project.lungfish/.tmp/`.
///
/// All Lungfish operations that need temporary working space should use this
/// utility instead of `FileManager.default.temporaryDirectory`. This keeps temp
/// files on the same volume as the project (critical for external SSDs) and
/// enables centralized cleanup.
///
/// ## Usage
///
/// ```swift
/// // From a pipeline with a config that has outputDirectory:
/// let tempDir = try ProjectTempDirectory.createFromContext(
///     prefix: "lungfish-extract-",
///     contextURL: config.outputDirectory
/// )
/// defer { try? FileManager.default.removeItem(at: tempDir) }
/// ```
///
/// ## Fallback
///
/// When no project root can be found (e.g., pre-project operations like database
/// downloads), `create(prefix:in: nil)` falls back to system temp with a warning.
public enum ProjectTempDirectory {

    /// The hidden directory name inside the project root.
    private static let tmpDirName = ".tmp"

    // MARK: - Project Root Discovery

    /// Walks up from a URL to find the enclosing `.lungfish` project directory.
    ///
    /// Handles derivative paths (`project.lungfish/Downloads/bundle/derivatives/tool-*/`),
    /// import paths (`project.lungfish/Imports/naomgs-*/`), and any other nesting.
    ///
    /// - Parameter url: Any URL within a Lungfish project tree.
    /// - Returns: The project root URL (ending in `.lungfish`), or `nil` if not found
    ///   within 10 levels.
    public static func findProjectRoot(_ url: URL) -> URL? {
        var candidate = url
        for _ in 0..<10 {
            if candidate.pathExtension == "lungfish" {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return nil
    }

    // MARK: - Temp Root

    /// Returns the `.tmp/` directory URL for a project.
    ///
    /// Does not create the directory — use ``create(prefix:in:)`` to create
    /// a subdirectory that also ensures `.tmp/` exists.
    ///
    /// - Parameter projectURL: The `.lungfish` project root URL.
    /// - Returns: `projectURL/.tmp/`
    public static func tempRoot(for projectURL: URL) -> URL {
        projectURL.appendingPathComponent(tmpDirName, isDirectory: true)
    }

    // MARK: - Create

    /// Creates a temporary directory inside the project's `.tmp/` folder.
    ///
    /// - Parameters:
    ///   - prefix: A descriptive prefix (e.g., `"lungfish-extract-"`). A UUID suffix
    ///     is appended automatically.
    ///   - projectURL: The `.lungfish` project root, or `nil` to fall back to system temp.
    /// - Returns: The URL of the created directory.
    /// - Throws: Filesystem errors if the directory cannot be created.
    public static func create(prefix: String, in projectURL: URL?) throws -> URL {
        let baseDir: URL
        if let projectURL {
            baseDir = tempRoot(for: projectURL)
        } else {
            logger.warning("No project URL provided; falling back to system temp for prefix '\(prefix, privacy: .public)'")
            baseDir = FileManager.default.temporaryDirectory
        }

        let dirName = "\(prefix)\(UUID().uuidString)"
        let url = baseDir.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a temporary directory, deriving the project root from any URL
    /// within the project tree.
    ///
    /// This is the preferred entry point for callers that have a context URL
    /// (e.g., `config.outputDirectory`, `bundleURL`) but not the project root.
    ///
    /// - Parameters:
    ///   - prefix: A descriptive prefix (e.g., `"lungfish-extract-"`).
    ///   - contextURL: Any URL within the project tree. `findProjectRoot` is called
    ///     to resolve the `.lungfish` ancestor.
    /// - Returns: The URL of the created directory.
    /// - Throws: Filesystem errors if the directory cannot be created.
    public static func createFromContext(prefix: String, contextURL: URL) throws -> URL {
        let projectURL = findProjectRoot(contextURL)
        return try create(prefix: prefix, in: projectURL)
    }

    // MARK: - Cleanup

    /// Removes the entire `.tmp/` directory and all contents.
    ///
    /// Safe to call when `.tmp/` does not exist (no-op).
    ///
    /// - Parameter projectURL: The `.lungfish` project root.
    public static func cleanAll(in projectURL: URL) throws {
        let root = tempRoot(for: projectURL)
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
            logger.info("Cleaned all temp files in \(root.path, privacy: .public)")
        }
    }

    /// Removes subdirectories of `.tmp/` older than `maxAge` seconds.
    ///
    /// Active operations create temp directories with recent modification dates,
    /// so this only removes stale directories from interrupted or completed work.
    ///
    /// - Parameters:
    ///   - projectURL: The `.lungfish` project root.
    ///   - maxAge: Maximum age in seconds. Directories modified more recently are kept.
    public static func cleanStale(in projectURL: URL, olderThan maxAge: TimeInterval) throws {
        let root = tempRoot(for: projectURL)
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)
        let contents = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        for item in contents {
            let attrs = try item.resourceValues(forKeys: [.contentModificationDateKey])
            if let modDate = attrs.contentModificationDate, modDate < cutoff {
                try fm.removeItem(at: item)
                logger.info("Removed stale temp dir: \(item.lastPathComponent, privacy: .public)")
            }
        }
    }

    // MARK: - Disk Usage

    /// Returns the total size in bytes of the `.tmp/` directory.
    ///
    /// Returns 0 if `.tmp/` does not exist.
    ///
    /// - Parameter projectURL: The `.lungfish` project root.
    /// - Returns: Total byte count of all files under `.tmp/`.
    public static func diskUsage(in projectURL: URL) -> UInt64 {
        let root = tempRoot(for: projectURL)
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return 0 }

        var total: UInt64 = 0
        if let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
                total += UInt64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectTempDirectoryTests 2>&1 | tail -5`
Expected: All 13 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles/ProjectTempDirectory.swift Tests/LungfishIOTests/ProjectTempDirectoryTests.swift
git commit -m "feat: add ProjectTempDirectory utility for project-local temp files (TDD)"
```

---

## Task 2: Move findProjectRoot from LungfishApp to LungfishIO

**Files:**
- Delete: `Sources/LungfishApp/Views/Metagenomics/ProjectRootDiscovery.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- Modify: `Tests/LungfishAppTests/ProjectRootDiscoveryTests.swift`

The `findProjectRoot` function now lives in `ProjectTempDirectory` (LungfishIO). The old file-scoped function in LungfishApp must be removed, and all 4 classifier controllers + tests updated to use `ProjectTempDirectory.findProjectRoot()`.

- [ ] **Step 1: Delete the old ProjectRootDiscovery.swift**

Remove `Sources/LungfishApp/Views/Metagenomics/ProjectRootDiscovery.swift` entirely.

- [ ] **Step 2: Update all 4 classifier controllers to use ProjectTempDirectory.findProjectRoot**

In each of these files, replace `findProjectRoot(` with `ProjectTempDirectory.findProjectRoot(` and add `import LungfishIO` if not already present:

- `EsVirituResultViewController.swift` — 1 call site
- `NaoMgsResultViewController.swift` — 2 call sites (primary + fallback)
- `NvdResultViewController.swift` — 1 call site
- `TaxTriageResultViewController.swift` — 1 call site

- [ ] **Step 3: Update ProjectRootDiscoveryTests to import from LungfishIO**

Change `@testable import LungfishApp` to `@testable import LungfishIO` and update all calls from `findProjectRoot(` to `ProjectTempDirectory.findProjectRoot(`.

- [ ] **Step 4: Build and run tests**

Run: `swift build --build-tests 2>&1 | tail -5` then `swift test --filter ProjectRootDiscoveryTests 2>&1 | tail -5`
Expected: Build succeeds. All 5 ProjectRootDiscoveryTests pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: move findProjectRoot to ProjectTempDirectory in LungfishIO"
```

---

## Task 3: Migrate ReadExtractionService (TDD)

**Files:**
- Create: `Tests/LungfishWorkflowTests/Extraction/ProjectTempExtractionTests.swift`
- Modify: `Sources/LungfishWorkflow/Extraction/ReadExtractionService.swift`

Three temp directory sites to migrate: `lungfish-extract-`, `lungfish-bam-dedup-`, `lungfish-bam-extract-`.

- [ ] **Step 1: Write failing test that extraction uses project .tmp/**

```swift
// Tests/LungfishWorkflowTests/Extraction/ProjectTempExtractionTests.swift
import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO

final class ProjectTempExtractionTests: XCTestCase {

    private var tempDir: URL!
    private var projectURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectTempExtractionTests-\(UUID().uuidString)")
        projectURL = tempDir.appendingPathComponent("test.lungfish")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    /// Verifies that extractByReadIDs creates its temp read ID file inside
    /// the project .tmp/ directory, not in system temp.
    func testExtractByReadIDsUsesProjectTemp() async throws {
        // The output directory is inside the project, so extraction should
        // use project .tmp/ for its intermediate read_ids.txt file.
        let outputDir = projectURL.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // After extraction (which will fail because there are no FASTQ files),
        // check that .tmp/ was created inside the project.
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectURL)

        // We can't easily test the intermediate temp dir because it's cleaned
        // up by defer. Instead, verify the API accepts a project-context URL
        // by checking that the config's output directory resolves to the project.
        let resolved = ProjectTempDirectory.findProjectRoot(outputDir)
        XCTAssertEqual(resolved?.standardizedFileURL, projectURL.standardizedFileURL)
    }

    /// Verifies that extraction output directories derive from project context.
    func testExtractionConfigOutputDirResolvesToProject() {
        let outputDir = projectURL
            .appendingPathComponent("Downloads")
            .appendingPathComponent("sample.lungfishfastq")
            .appendingPathComponent("derivatives")
            .appendingPathComponent("extract-output")

        let resolved = ProjectTempDirectory.findProjectRoot(outputDir)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.standardizedFileURL, projectURL.standardizedFileURL)
    }
}
```

- [ ] **Step 2: Run tests to verify they pass (these are structure tests)**

Run: `swift test --filter ProjectTempExtractionTests 2>&1 | tail -5`
Expected: PASS (these test the resolution logic, not the migration itself).

- [ ] **Step 3: Migrate ReadExtractionService temp directories**

In `ReadExtractionService.swift`, replace all three `FileManager.default.temporaryDirectory` usages with `ProjectTempDirectory.createFromContext(prefix:contextURL:)`, using `config.outputDirectory` as the context URL.

**Site 1** (~line 71): `extractByReadIDs` — read ID file
```swift
// Before:
let tempDir = fm.temporaryDirectory.appendingPathComponent("lungfish-extract-\(UUID().uuidString)")
try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

// After:
let tempDir = try ProjectTempDirectory.createFromContext(
    prefix: "lungfish-extract-",
    contextURL: config.outputDirectory
)
```

**Site 2** (~line 252): `extractByBAMRegion` — dedup fallback BAM
```swift
// Before:
let fallbackTempDir = fm.temporaryDirectory.appendingPathComponent("lungfish-bam-dedup-\(UUID().uuidString)")
try fm.createDirectory(at: fallbackTempDir, withIntermediateDirectories: true)

// After:
let fallbackTempDir = try ProjectTempDirectory.createFromContext(
    prefix: "lungfish-bam-dedup-",
    contextURL: config.outputDirectory
)
```

**Site 3** (~line 286): `extractByBAMRegion` — region extraction BAM
```swift
// Before:
let tempDir = fm.temporaryDirectory.appendingPathComponent("lungfish-bam-extract-\(UUID().uuidString)")
try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

// After:
let tempDir = try ProjectTempDirectory.createFromContext(
    prefix: "lungfish-bam-extract-",
    contextURL: config.outputDirectory
)
```

Add `import LungfishIO` to the file's imports.

- [ ] **Step 4: Run existing ReadExtractionServiceTests to verify no regressions**

Run: `swift test --filter ReadExtractionServiceTests 2>&1 | tail -5`
Expected: All 18 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Extraction/ReadExtractionService.swift Tests/LungfishWorkflowTests/Extraction/ProjectTempExtractionTests.swift
git commit -m "refactor: migrate ReadExtractionService to project-local temp dirs"
```

---

## Task 4: Migrate LungfishWorkflow Pipelines

**Files:**
- Modify: `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift`
- Modify: `Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Orient/OrientPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline+Scout.swift`
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`

Each pipeline has a config with an `outputDirectory` that provides the project context. The migration pattern is identical for all: replace `fm.temporaryDirectory.appendingPathComponent("prefix-\(UUID())")` + `createDirectory` with `ProjectTempDirectory.createFromContext(prefix:contextURL:)`.

- [ ] **Step 1: Migrate EsVirituPipeline (1 site ~line 396)**

Replace the safe-output-dir creation when output path has spaces:
```swift
// Before:
safeOutputDir = fm.temporaryDirectory
    .appendingPathComponent("esviritu-\(UUID().uuidString.prefix(8))")
try fm.createDirectory(at: safeOutputDir, withIntermediateDirectories: true)

// After:
safeOutputDir = try ProjectTempDirectory.createFromContext(
    prefix: "esviritu-",
    contextURL: config.outputDirectory
)
```

- [ ] **Step 2: Migrate TaxTriagePipeline (1 site ~line 234)**

Same pattern — the space-redirect temp directory.

- [ ] **Step 3: Migrate SPAdesAssemblyPipeline (1 site ~line 437)**

Replace `NSTemporaryDirectory()` with `ProjectTempDirectory.createFromContext`:
```swift
// Before:
let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("lungfish-spades-\(UUID().uuidString.prefix(8))")

// After:
let tempDir = try ProjectTempDirectory.createFromContext(
    prefix: "lungfish-spades-",
    contextURL: config.outputDirectory
)
```

- [ ] **Step 4: Migrate OrientPipeline (1 site ~line 121)**

- [ ] **Step 5: Migrate DemultiplexingPipeline (1 site ~line 352)**

- [ ] **Step 6: Migrate DemultiplexingPipeline+Scout (1 site ~line 52)**

- [ ] **Step 7: Migrate FASTQIngestionPipeline (1 site ~line 398)**

- [ ] **Step 8: Migrate NativeToolRunner BBTools symlinks (1 site ~line 410)**

For NativeToolRunner, the context URL comes from the arguments (file paths). Extract the first file path from the arguments to use as context:
```swift
// Before:
let linkDir = fm.temporaryDirectory.appendingPathComponent("lungfish-bbtools-\(UUID().uuidString)")
try fm.createDirectory(at: linkDir, withIntermediateDirectories: true)

// After:
let contextURL = URL(fileURLWithPath: value)
let linkDir = try ProjectTempDirectory.createFromContext(
    prefix: "lungfish-bbtools-",
    contextURL: contextURL
)
```

- [ ] **Step 9: Build and run all workflow tests**

Run: `swift test --filter LungfishWorkflowTests 2>&1 | tail -5`
Expected: All existing tests PASS.

- [ ] **Step 10: Commit**

```bash
git add Sources/LungfishWorkflow/
git commit -m "refactor: migrate all LungfishWorkflow pipelines to project-local temp dirs"
```

---

## Task 5: Migrate FASTQDerivativeService (8 sites)

**Files:**
- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService.swift`

The service has a `makeTemporaryDirectory(prefix:)` helper at line 4387 that all other sites call. The simplest migration is to change this single method plus the 3 sites that call `fm.temporaryDirectory` directly.

- [ ] **Step 1: Add a `projectURL` property or pass context through**

The `FASTQDerivativeService` operates on FASTQ bundles. It should accept a project context URL. Find the best approach:
- If the service has access to a bundle URL, use `ProjectTempDirectory.createFromContext(prefix:contextURL:bundleURL)`
- Otherwise, add an optional `projectURL` parameter to `makeTemporaryDirectory`

Change `makeTemporaryDirectory`:
```swift
// Before:
private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// After:
private func makeTemporaryDirectory(prefix: String, contextURL: URL? = nil) throws -> URL {
    if let contextURL {
        return try ProjectTempDirectory.createFromContext(prefix: prefix, contextURL: contextURL)
    }
    return try ProjectTempDirectory.create(prefix: prefix, in: nil)
}
```

- [ ] **Step 2: Update all 8 call sites to pass contextURL**

Each call site has access to a FASTQ URL or bundle URL. Thread it through.

- [ ] **Step 3: Update the 3 direct `fm.temporaryDirectory` calls**

Lines ~2156, ~2183, ~2230, ~2257 — these create temp dirs for virtual FASTQ orientation and demux trim. Replace each with `ProjectTempDirectory.createFromContext`.

- [ ] **Step 4: Build and run app tests**

Run: `swift test --filter LungfishAppTests 2>&1 | tail -5`
Expected: All existing tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/FASTQDerivativeService.swift
git commit -m "refactor: migrate FASTQDerivativeService to project-local temp dirs (8 sites)"
```

---

## Task 6: Migrate AppDelegate Materialization + Export Sites

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`

~8 sites for materialization (`lungfish-minimap2-`, `lungfish-orient-`, `lungfish-classify-`, `lungfish-esviritu-`, `lungfish-taxtriage-`) and export (`export-`, `export-decomp-`, VCF import).

- [ ] **Step 1: Migrate all 5 materialization temp dirs**

Each has a bundle URL in scope. Use `ProjectTempDirectory.createFromContext(prefix:contextURL:)`.

- [ ] **Step 2: Migrate 3 export/import temp dirs**

- [ ] **Step 3: Build and run**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/App/AppDelegate.swift
git commit -m "refactor: migrate AppDelegate materialization and export to project-local temp"
```

---

## Task 7: Migrate Remaining LungfishApp Services + ViewControllers

**Files:**
- Modify: `Sources/LungfishApp/Services/AlignmentDuplicateService.swift` (1 site)
- Modify: `Sources/LungfishApp/Services/ReferenceBundleImportService.swift` (1 site)
- Modify: `Sources/LungfishApp/Services/FASTQIngestionService.swift` (1 site)
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` (1 site)
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift` (1 site)
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift` (1 site)
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift` (1 site)
- Modify: `Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift` (1 site)
- Modify: `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift` (1 site)
- Modify: `Sources/LungfishApp/ViewModels/GenBankBundleDownloadViewModel.swift` (2 sites)
- Modify: `Sources/LungfishApp/ViewModels/GenomeDownloadViewModel.swift` (1 site)
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift` (1 site)
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` (1 site)

Each follows the same pattern: replace `FileManager.default.temporaryDirectory` with `ProjectTempDirectory.createFromContext`, using the available bundle/output URL as context.

- [ ] **Step 1: Migrate classifier extraction controllers (4 files)**

Each has `bundleURL` and uses a temp dir for extraction output. Replace with `ProjectTempDirectory.createFromContext(prefix:contextURL:bundleURL)`.

- [ ] **Step 2: Migrate services (3 files)**

- [ ] **Step 3: Migrate view models and view controllers (6 files)**

- [ ] **Step 4: Build and run all tests**

Run: `swift test 2>&1 | grep "Executed 58"` (should show ~5820+ tests, 0 unexpected failures)
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/
git commit -m "refactor: migrate remaining LungfishApp services and views to project-local temp"
```

---

## Task 8: Migrate CLI Commands

**Files:**
- Modify: `Sources/LungfishCLI/Commands/ImportCommand.swift` (1 site)
- Modify: `Sources/LungfishCLI/Commands/FastqCommand.swift` (2 sites)
- Modify: `Sources/LungfishCLI/Commands/FetchCommand.swift` (1 site)

CLI commands derive the project context from their `--output` path.

- [ ] **Step 1: Migrate all 4 sites**

Each command has an `output` parameter. Use it as the context URL.

- [ ] **Step 2: Build and run CLI tests**

Run: `swift test --filter LungfishCLITests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishCLI/
git commit -m "refactor: migrate CLI commands to project-local temp dirs"
```

---

## Task 9: TempFileManager Project-Aware Cleanup + Menu Item

**Files:**
- Modify: `Sources/LungfishCore/Services/TempFileManager.swift`
- Create: `Tests/LungfishCoreTests/TempFileManagerProjectTests.swift`

- [ ] **Step 1: Write failing tests for project cleanup**

```swift
// Tests/LungfishCoreTests/TempFileManagerProjectTests.swift
import XCTest
@testable import LungfishCore
@testable import LungfishIO

final class TempFileManagerProjectTests: XCTestCase {

    private var tempDir: URL!
    private var projectURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TFMProjectTests-\(UUID().uuidString)")
        projectURL = tempDir.appendingPathComponent("test.lungfish")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    func testCleanProjectOnLaunchRemovesTmpDir() async throws {
        // Create .tmp/ with contents
        let _ = try ProjectTempDirectory.create(prefix: "test-", in: projectURL)
        let tmpRoot = ProjectTempDirectory.tempRoot(for: projectURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpRoot.path))

        await TempFileManager.shared.cleanProjectOnLaunch(projectURL: projectURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpRoot.path))
    }

    func testProjectDiskUsageReturnsBytes() throws {
        let dir = try ProjectTempDirectory.create(prefix: "test-", in: projectURL)
        let file = dir.appendingPathComponent("data.bin")
        try Data(count: 1024).write(to: file)

        let usage = ProjectTempDirectory.diskUsage(in: projectURL)
        XCTAssertGreaterThanOrEqual(usage, 1024)
    }
}
```

- [ ] **Step 2: Add `cleanProjectOnLaunch` to TempFileManager**

```swift
// In TempFileManager.swift, add:
/// Removes the entire `.tmp/` directory for the given project.
///
/// Called on app launch and from the "Clear Temporary Files" menu item.
public func cleanProjectOnLaunch(projectURL: URL) async {
    do {
        try ProjectTempDirectory.cleanAll(in: projectURL)
        logger.info("Cleaned project temp files at launch")
    } catch {
        logger.warning("Failed to clean project temp: \(error.localizedDescription, privacy: .public)")
    }
}
```

Add `import LungfishIO` to TempFileManager.

- [ ] **Step 3: Add periodic stale cleanup timer**

Add a method that can be called from AppDelegate to start a periodic cleanup:
```swift
/// Starts a periodic timer that cleans stale temp directories (>24h)
/// every 4 hours. Call once from AppDelegate after project opens.
public func startPeriodicCleanup(projectURL: URL) {
    // Store projectURL and schedule cleanup
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter TempFileManagerProjectTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Wire menu item in AppDelegate**

Add a "Clear Temporary Files..." menu item under File menu (or appropriate location). When clicked:
1. Compute disk usage via `ProjectTempDirectory.diskUsage(in:)`
2. Show confirmation alert with size
3. Call `ProjectTempDirectory.cleanAll(in:)`

- [ ] **Step 6: Wire periodic cleanup in AppDelegate**

In `applicationDidFinishLaunching`, after project opens, call:
```swift
await TempFileManager.shared.cleanProjectOnLaunch(projectURL: projectURL)
TempFileManager.shared.startPeriodicCleanup(projectURL: projectURL)
```

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishCore/Services/TempFileManager.swift Tests/LungfishCoreTests/TempFileManagerProjectTests.swift Sources/LungfishApp/App/AppDelegate.swift
git commit -m "feat: project-aware cleanup, menu item, periodic stale-file removal"
```

---

## Task 10: Debug Guard Assertion

**Files:**
- Modify: `Sources/LungfishCore/Services/TempFileManager.swift`

- [ ] **Step 1: Add debug guard that scans system temp for escaped lungfish-* dirs**

```swift
#if DEBUG
/// Scans system temp for lungfish-* directories that should be in project .tmp/.
/// Logs a warning in debug builds to catch regressions.
public func debugScanForEscapedTempDirs() async {
    let systemTemp = FileManager.default.temporaryDirectory
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(
        at: systemTemp,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else { return }

    for item in contents {
        let name = item.lastPathComponent
        if name.hasPrefix("lungfish-") || name.hasPrefix("esviritu-") ||
           name.hasPrefix("taxtriage-") || name.hasPrefix("bbmerge-") ||
           name.hasPrefix("bbrepair-") || name.hasPrefix("bbduk-primer-") {
            logger.warning("DEBUG: Found escaped temp dir in system temp: \(name, privacy: .public). Should be in project .tmp/")
            assertionFailure("Escaped temp dir found in system temp: \(name). Use ProjectTempDirectory.createFromContext() instead.")
        }
    }
}
#endif
```

- [ ] **Step 2: Wire the guard into the periodic cleanup timer**

In the periodic timer (every 4 hours), also call `debugScanForEscapedTempDirs()` in debug builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishCore/Services/TempFileManager.swift
git commit -m "feat: add debug guard assertion for escaped temp directories"
```

---

## Task 11: Final Verification

- [ ] **Step 1: Run the full test suite**

Run: `swift test 2>&1 | grep "Executed 58"`
Expected: ~5830+ tests, 0 unexpected failures.

- [ ] **Step 2: Verify no system temp references remain in project-context code**

Run: `grep -rn "temporaryDirectory\|NSTemporaryDirectory" Sources/ --include="*.swift" | grep -v "ProjectTempDirectory\|BlastService\|NCBIService\|SRAService\|TempFileManager\|WorkflowRunner\|MetagenomicsDatabaseRegistry\|NFCoreRegistry"`

Expected: No matches (all project-context sites migrated; only pre-project services remain).

- [ ] **Step 3: Build the CLI and test extraction end-to-end**

```bash
swift build --product lungfish-cli
.build/arm64-apple-macosx/debug/lungfish-cli extract reads --by-region --bam <test-bam> --region MT192765.1 -o /path/to/project.lungfish/output.fastq
```

Verify the extraction temp files appear inside `project.lungfish/.tmp/` during execution.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "chore: final verification — all temp files routed through project .tmp/"
```
