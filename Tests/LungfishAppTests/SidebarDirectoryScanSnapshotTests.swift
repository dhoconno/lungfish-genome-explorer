// SidebarDirectoryScanSnapshotTests.swift - source guards for sidebar directory scans
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

@MainActor
final class SidebarDirectoryScanSnapshotTests: XCTestCase {

    /// The directory sort must use the directory-ness captured in the entry
    /// snapshot, never re-probe the filesystem per comparator call.
    ///
    /// After F5/F7 the scan lives in `SidebarProjectScanner`, so both the root and
    /// recursive scans share a single `sortedEntries` comparator; asserting on it
    /// covers both call sites.
    func testRootAndRecursiveDirectorySortsDoNotProbeFileSystemInComparators() throws {
        let source = sidebarProjectScannerSource()
        let sortHelper = try slice(
            source,
            from: "private static func sortedEntries(_ entries: [DirectoryEntry]) -> [DirectoryEntry]",
            to: "// MARK: - Root scan"
        )

        let comparator = try sortedClosure(in: sortHelper)

        XCTAssertFalse(
            comparator.contains("fileExists(atPath:"),
            "Sidebar directory sorting must use captured directory metadata instead of probing each comparator call."
        )

        let rootScan = try slice(
            source,
            from: "static func scanRootNodes(from projectURL: URL) -> [SidebarScanNode]",
            to: "// MARK: - Recursive tree scan"
        )
        let recursiveScan = try slice(
            source,
            from: "// Directories recurse, except bundles which show as single items.",
            to: "// NAO-MGS and NVD result bundles are standalone"
        )

        XCTAssertTrue(
            rootScan.contains("sortedEntries("),
            "Root sidebar scan must sort through the shared metadata-based comparator."
        )
        XCTAssertTrue(
            recursiveScan.contains("sortedEntries("),
            "Recursive sidebar scan must sort through the shared metadata-based comparator."
        )
    }

    func testRootAndRecursiveDirectoryScansUseDirectoryEntrySnapshot() throws {
        let source = sidebarProjectScannerSource()
        let rootScan = try slice(
            source,
            from: "static func scanRootNodes(from projectURL: URL) -> [SidebarScanNode]",
            to: "// MARK: - Recursive tree scan"
        )
        let recursiveScan = try slice(
            source,
            from: "// Directories recurse, except bundles which show as single items.",
            to: "// NAO-MGS and NVD result bundles are standalone"
        )

        XCTAssertTrue(source.contains("struct DirectoryEntry: Sendable"))
        XCTAssertTrue(rootScan.contains("directoryEntries(in: projectURL"))
        XCTAssertTrue(recursiveScan.contains("directoryEntries(in: url"))
    }

    /// The scan that F5/F7 moved off the main actor must stay free of AppKit and
    /// of main-actor isolation, or it silently migrates back onto the main thread.
    func testProjectScannerStaysFreeOfAppKitAndMainActorIsolation() throws {
        let source = sidebarProjectScannerSource()

        XCTAssertFalse(
            source.contains("import AppKit"),
            "SidebarProjectScanner must not import AppKit; badge intent is materialized on the main actor."
        )
        XCTAssertFalse(
            source.contains("@MainActor"),
            "SidebarProjectScanner must stay nonisolated so the project walk can run off the main actor."
        )
        XCTAssertFalse(
            source.contains("SidebarItem("),
            "SidebarProjectScanner must produce Sendable SidebarScanNode values, not main-actor SidebarItems."
        )
        XCTAssertFalse(
            source.contains("@unchecked Sendable"),
            "SidebarProjectScanner must achieve Sendability structurally, not by suppressing the checker."
        )
    }

    /// The incremental watcher path must keep applying a surgical subtree diff.
    ///
    /// Moving its rescan off the main actor (F7) must not tempt the apply step into
    /// a blanket `reloadData()`, which would undo the targeted insert/remove/reload
    /// contract the sidebar depends on.
    func testIncrementalUpdatePathStillAppliesSurgicalSubtreeDiff() throws {
        let source = combinedSidebarViewControllerSource()
        let updateBody = try slice(
            source,
            from: "func updateSidebar(changedPaths: FileSystemWatcher.ChangedPaths)",
            to: "private func notifySelectedItemsRefreshedIfNeeded(changedPaths: [URL])"
        )

        // The incremental path must bump the generation before capturing it, the
        // same way the full-reload path does. Without the bump, two overlapping
        // incremental scans capture the same token and neither invalidates the
        // other. Behaviour is covered by
        // SidebarScanSnapshotParityTests.testOverlappingIncrementalScansAreMutuallyOrdered.
        let bumpRange = try XCTUnwrap(
            updateBody.range(of: "sidebarScanGeneration &+= 1"),
            "The incremental update must bump the scan generation."
        )
        let captureRange = try XCTUnwrap(
            updateBody.range(of: "let generation = sidebarScanGeneration"),
            "The incremental update must capture the scan generation."
        )
        XCTAssertTrue(
            bumpRange.upperBound <= captureRange.lowerBound,
            "The incremental update must bump the generation BEFORE capturing it."
        )

        XCTAssertTrue(
            updateBody.contains("applySubtreeDiff("),
            "The incremental sidebar update must apply a surgical subtree diff."
        )
        XCTAssertFalse(
            updateBody.contains("outlineView.reloadData()"),
            "The incremental sidebar update must not fall back to a blanket reloadData()."
        )
        XCTAssertTrue(
            updateBody.contains("SidebarProjectScanner.scanTree"),
            "The incremental rescan must go through the nonisolated scanner so it can run off-main."
        )
    }

    /// Both background apply paths must re-check the scan generation before
    /// mutating the tree, or a slow scan can clobber newer state.
    func testBackgroundScanAppliesAreGenerationGuarded() throws {
        let source = combinedSidebarViewControllerSource()

        XCTAssertTrue(
            source.contains("func reloadFromFilesystemAsync"),
            "The background reload path must exist."
        )
        XCTAssertTrue(
            source.contains("sidebarScanGeneration"),
            "Background sidebar scans must carry a generation token."
        )

        let occurrences = source.components(separatedBy: "guard self.sidebarScanGeneration == generation").count - 1
        XCTAssertEqual(
            occurrences,
            2,
            "Both the full-reload and incremental background apply steps must re-check the scan generation."
        )
    }

    /// Selection suppression must go through the nesting-aware scope, never a bare
    /// `suppressSelectionCallbacks = ...` write.
    ///
    /// A direct write from a nested site (such as `applySidebarSelection`) can clear
    /// suppression that an enclosing rebuild still owns, letting a synthetic
    /// selection event escape mid-rebuild. Behaviour is covered by
    /// SidebarScanSnapshotParityTests.testSelectionIsNotSuppressedDuringBackgroundScan.
    func testSelectionSuppressionGoesThroughTheNestingAwareScope() throws {
        let source = combinedSidebarViewControllerSource()

        XCTAssertTrue(
            source.contains("func withSelectionSuppressed"),
            "A nesting-aware selection-suppression scope must exist."
        )
        XCTAssertTrue(
            source.contains("selectionSuppressionDepth"),
            "Selection suppression must be depth-counted so nesting is safe."
        )

        // The only permitted direct writes are the two counter primitives.
        let directWrites = source.components(separatedBy: "suppressSelectionCallbacks = ").count - 1
        XCTAssertEqual(
            directWrites,
            3,
            """
            Only the declaration and the two counter primitives \
            (beginSelectionSuppression/endSelectionSuppression) may assign \
            suppressSelectionCallbacks directly; everything else must use \
            withSelectionSuppressed.
            """
        )
    }

    private func sidebarProjectScannerSource() -> String {
        let url = sidebarViewControllerSourceDirectory()
            .appendingPathComponent("SidebarProjectScanner.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testSidebarMovePathsRewriteAnalysisManifestReferences() throws {
        let source = combinedSidebarViewControllerSource()
        let lines = source.components(separatedBy: .newlines)
        var checkedMoveSites = 0

        for index in lines.indices where lines[index].contains("FileManager.default.moveItem") {
            let upperBound = min(lines.endIndex, index + 6)
            let context = lines[index..<upperBound].joined(separator: "\n")
            guard context.contains("rehydrateScientificProvenance") else {
                continue
            }

            checkedMoveSites += 1
            XCTAssertTrue(
                context.contains("rewriteAnalysisManifestReferencesIfNeeded"),
                "Sidebar move paths that rehydrate provenance must also rewrite analysis manifest references:\n\(context)"
            )
        }

        XCTAssertEqual(checkedMoveSites, 3)
        XCTAssertTrue(source.contains("func rewriteAnalysisManifestReferencesIfNeeded"))
    }

    func testSidebarDeletePathRemovesAnalysisManifestReferences() throws {
        let source = combinedSidebarViewControllerSource()
        let deleteBody = try slice(
            source,
            from: "private func performDelete(items: [SidebarItem], includingDependentURLs dependentURLs: [URL] = [])",
            to: "/// Returns `true` when `error` indicates the target file no longer exists"
        )

        XCTAssertTrue(deleteBody.contains("FileManager.default.trashItem(at: url"))
        XCTAssertTrue(deleteBody.contains("removeAnalysisManifestReferencesIfNeeded(forDeleted: url)"))
        XCTAssertTrue(source.contains("func removeAnalysisManifestReferencesIfNeeded"))
    }

    func testOpenProjectKeepsDirectoriesBeforeFilesAtRootAndNestedLevels() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarDirectoryOrder-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let rootAlphaDir = projectURL.appendingPathComponent("Alpha Folder", isDirectory: true)
        let rootZetaDir = projectURL.appendingPathComponent("zeta-folder", isDirectory: true)
        let nestedAlphaDir = rootZetaDir.appendingPathComponent("alpha-nested", isDirectory: true)
        let nestedBetaDir = rootZetaDir.appendingPathComponent("Beta Nested", isDirectory: true)

        try FileManager.default.createDirectory(at: nestedAlphaDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedBetaDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootAlphaDir, withIntermediateDirectories: true)
        try "root alpha".write(
            to: projectURL.appendingPathComponent("alpha.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "root zeta".write(
            to: projectURL.appendingPathComponent("Zeta.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "nested alpha".write(
            to: rootZetaDir.appendingPathComponent("alpha-child.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "nested zeta".write(
            to: rootZetaDir.appendingPathComponent("Zeta-child.txt"),
            atomically: true,
            encoding: .utf8
        )

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertEqual(
            sidebar.rootItems.map(\.title),
            ["Alpha Folder", "zeta-folder", "alpha.txt", "Zeta.txt"]
        )

        let zetaItem = try XCTUnwrap(sidebar.rootItems.first { $0.title == "zeta-folder" })
        XCTAssertEqual(
            zetaItem.children.map(\.title),
            ["alpha-nested", "Beta Nested", "alpha-child.txt", "Zeta-child.txt"]
        )
    }

    func testDirectorySymlinksKeepDirectoryOrderingAndRootExclusions() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarDirectorySymlink-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let linkedTarget = tempRoot.appendingPathComponent("Linked Target", isDirectory: true)
        let visibleSymlink = projectURL.appendingPathComponent("linked-dir", isDirectory: true)
        let provenanceSymlink = projectURL.appendingPathComponent("provenance", isDirectory: true)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkedTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: visibleSymlink, withDestinationURL: linkedTarget)
        try FileManager.default.createSymbolicLink(at: provenanceSymlink, withDestinationURL: linkedTarget)
        try "root".write(
            to: projectURL.appendingPathComponent("alpha.txt"),
            atomically: true,
            encoding: .utf8
        )

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertEqual(
            sidebar.rootItems.map(\.title),
            ["linked-dir", "alpha.txt"]
        )
        XCTAssertFalse(
            sidebar.rootItems.contains { $0.url?.lastPathComponent == "provenance" },
            "Directory symlinks should still use directory-only project-root exclusions."
        )
    }

    private func slice(
        _ source: String,
        from startMarker: String,
        to endMarker: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let startRange = try XCTUnwrap(
            source.range(of: startMarker),
            "Missing source marker: \(startMarker)",
            file: file,
            line: line
        )
        let endRange = try XCTUnwrap(
            source.range(of: endMarker, range: startRange.upperBound..<source.endIndex),
            "Missing source marker: \(endMarker)",
            file: file,
            line: line
        )
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func sortedClosure(
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let sortedRange = try XCTUnwrap(
            source.range(of: ".sorted"),
            "Missing sorted directory listing",
            file: file,
            line: line
        )
        return try closureSource(after: sortedRange.upperBound, in: source, file: file, line: line)
    }

    private func closureSource(
        after index: String.Index,
        in source: String,
        file: StaticString,
        line: UInt
    ) throws -> String {
        let openingBrace = try XCTUnwrap(
            source[index...].firstIndex(of: "{"),
            "Missing sorted closure body",
            file: file,
            line: line
        )

        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...cursor])
                }
            default:
                break
            }
            source.formIndex(after: &cursor)
        }

        XCTFail("Unterminated sorted closure body", file: file, line: line)
        return ""
    }
}
