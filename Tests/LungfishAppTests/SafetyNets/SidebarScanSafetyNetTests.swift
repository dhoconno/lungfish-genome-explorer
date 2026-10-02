// SidebarScanSafetyNetTests.swift - Committed snapshots of the sidebar scan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Safety net for architecture review finding R2. The sidebar scan recognises
// analysis folders through tool-name tables, legacy names and content probes
// (SidebarProjectScanner, AnalysesFolder). The architecture program replaces
// those tables with registries, so this suite runs the real scanner over five
// fixture projects (SidebarScanSafetyNetProjects) and compares each tree with
// a committed snapshot under Tests/Fixtures/sidebar-scan.
//
// Each snapshot line is one sidebar row, indented two spaces per level, with
// the columns type, title, badge, subtitle, path and routing keys. Paths are
// relative to the project folder.
//
// After an intended change to the scan, rewrite the snapshots and review the
// diff before committing it:
//
//     LUNGFISH_UPDATE_SIDEBAR_SNAPSHOTS=1 swift test --skip-update \
//         --filter LungfishAppTests.SidebarScanSafetyNetTests
//
// In update mode every test writes its snapshot and passes.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishTestSupport

final class SidebarScanSafetyNetTests: XCTestCase {
    static let updateEnvironmentKey = "LUNGFISH_UPDATE_SIDEBAR_SNAPSHOTS"

    func testAlignmentProjectSnapshot() async throws {
        try await verify(SidebarScanSafetyNetProjects.alignmentProject)
    }

    func testAnalysesSeedProjectSnapshot() async throws {
        try await verify(SidebarScanSafetyNetProjects.analysesSeedProject)
    }

    func testReferenceDataProjectSnapshot() async throws {
        try await verify(SidebarScanSafetyNetProjects.referenceDataProject)
    }

    func testDemoPracticeDataProjectSnapshot() async throws {
        try await verify(SidebarScanSafetyNetProjects.demoPracticeDataProject)
    }

    func testAnalysisNamingProjectSnapshot() async throws {
        try await verify(SidebarScanSafetyNetProjects.analysisNamingProject)
    }

    func testEveryProjectHasATest() {
        XCTAssertEqual(
            SidebarScanSafetyNetProjects.all.map(\.name).sorted(),
            ["alignment-project", "analyses-seeds", "analysis-naming", "demo-practice-data", "reference-data"],
            "Add a test method for every fixture project"
        )
    }

    // MARK: - Snapshot

    private func verify(
        _ project: SidebarScanFixtureProject,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let root = try TestTempDirectory.make(prefix: "SidebarScanSafetyNet")
        defer { TestTempDirectory.cleanup(root) }
        let projectURL = try await project.build(root)

        let rendered = SidebarScanSnapshot.render(
            SidebarProjectScanner.scanRootNodes(from: projectURL),
            projectURL: projectURL,
            summary: project.summary
        )
        let snapshotURL = SafetyNetPaths.fixture("sidebar-scan/\(project.name).txt")

        if ProcessInfo.processInfo.environment[Self.updateEnvironmentKey] == "1" {
            try SafetyNetFiles.write(rendered, to: snapshotURL)
            return
        }

        guard let committed = try? String(contentsOf: snapshotURL, encoding: .utf8) else {
            XCTFail(
                "No committed snapshot at \(snapshotURL.path). Run with \(Self.updateEnvironmentKey)=1 to write it.",
                file: file,
                line: line
            )
            return
        }
        XCTAssertEqual(
            rendered,
            committed,
            "The sidebar scan of \(project.name) changed. Diff against \(snapshotURL.lastPathComponent):\n\(SidebarScanSnapshot.difference(rendered, committed))",
            file: file,
            line: line
        )
    }
}

/// Renders a scanned sidebar tree as stable text.
enum SidebarScanSnapshot {
    static func render(_ nodes: [SidebarScanNode], projectURL: URL, summary: String) -> String {
        let paths = SafetyNetPathRenderer(root: projectURL)
        var lines = [
            "# \(summary)",
            "# Columns are type, title, badge, subtitle, path and routing keys.",
        ]
        func visit(_ node: SidebarScanNode, depth: Int) {
            let badge: String
            switch node.badge {
            case .symbol(let name): badge = "symbol \(name)"
            case .text(let text): badge = "text \(text)"
            case nil: badge = "-"
            }
            let keys = node.userInfo.isEmpty
                ? "-"
                : node.userInfo.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            let columns = [
                SidebarItemTypeCatalog.caseName(node.type),
                node.title,
                badge,
                node.subtitle ?? "-",
                paths.render(node.url) ?? "-",
                keys,
            ]
            lines.append(String(repeating: "  ", count: depth) + columns.joined(separator: " | "))
            for child in node.children {
                visit(child, depth: depth + 1)
            }
        }
        for node in nodes {
            visit(node, depth: 0)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The lines that differ, marked with + for the scan and - for the snapshot.
    static func difference(_ rendered: String, _ committed: String) -> String {
        let actual = rendered.components(separatedBy: "\n")
        let expected = committed.components(separatedBy: "\n")
        let difference = actual.difference(from: expected)
        var lines: [String] = []
        for change in difference {
            switch change {
            case .insert(let offset, let element, _): lines.append("+ \(offset + 1): \(element)")
            case .remove(let offset, let element, _): lines.append("- \(offset + 1): \(element)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
