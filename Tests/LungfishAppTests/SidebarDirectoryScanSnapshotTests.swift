// SidebarDirectoryScanSnapshotTests.swift - source guards for sidebar directory scans
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

@MainActor
final class SidebarDirectoryScanSnapshotTests: XCTestCase {

    func testRootAndRecursiveDirectorySortsDoNotProbeFileSystemInComparators() throws {
        let source = combinedSidebarViewControllerSource()
        let rootScan = try slice(
            source,
            from: "private func buildRootItems(from projectURL: URL) -> [SidebarItem]",
            to: "private func buildSidebarTree(from url: URL, isRoot: Bool = false) -> SidebarItem"
        )
        let recursiveScan = try slice(
            source,
            from: "// If it's a directory, scan children (unless it's a bundle)",
            to: "// Scan for NAO-MGS result bundles at this directory level."
        )

        let rootComparator = try sortedClosure(in: rootScan)
        let recursiveComparator = try sortedClosure(in: recursiveScan)

        XCTAssertFalse(
            rootComparator.contains("fileExists(atPath:"),
            "Root sidebar directory sorting must use captured directory metadata instead of probing each comparator call."
        )
        XCTAssertFalse(
            recursiveComparator.contains("fileExists(atPath:"),
            "Recursive sidebar directory sorting must use captured directory metadata instead of probing each comparator call."
        )
    }

    func testRootAndRecursiveDirectoryScansUseDirectoryEntrySnapshot() throws {
        let source = combinedSidebarViewControllerSource()
        let rootScan = try slice(
            source,
            from: "private func buildRootItems(from projectURL: URL) -> [SidebarItem]",
            to: "private func buildSidebarTree(from url: URL, isRoot: Bool = false) -> SidebarItem"
        )
        let recursiveScan = try slice(
            source,
            from: "// If it's a directory, scan children (unless it's a bundle)",
            to: "// Scan for NAO-MGS result bundles at this directory level."
        )

        XCTAssertTrue(source.contains("private struct SidebarDirectoryEntry"))
        XCTAssertTrue(rootScan.contains("directoryEntries(in: projectURL"))
        XCTAssertTrue(recursiveScan.contains("directoryEntries(in: url"))
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
