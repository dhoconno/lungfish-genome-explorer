// SidebarDuplicateNameTests.swift - The name Duplicate gives a copy in the sidebar
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A68, carry-in row SW3 and UX ruling R-SW3 (plan decision U8). Duplicate names a copy
// `<name> copy.<extension>` and a later copy `<name> copy <n>.<extension>`. A plain folder has no extension, and the
// copy must not end in a dot, which exFAT may refuse. Each test opens a project in a sidebar, selects an item and runs
// Duplicate as the menu does, then reads the names the copies took.

import AppKit
import XCTest
import LungfishTestSupport
@testable import LungfishApp

@MainActor
final class SidebarDuplicateNameTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var folder: URL!
    private var file: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = try TestTempDirectory.make(prefix: "SidebarDuplicateName")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        folder = project.appendingPathComponent("Reads", isDirectory: true)
        file = folder.appendingPathComponent("a.fasta")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ">a\nACGT\n".write(to: file, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A pin that passes at the base. A file keeps its extension, and the second copy takes the counter.
    func testDuplicateOfAFileKeepsItsExtensionAndCountsTheLaterCopy() throws {
        try duplicate(file, times: 2)

        XCTAssertTrue(exists(folder, "a copy.fasta"))
        XCTAssertTrue(exists(folder, "a copy 2.fasta"))
    }

    // MARK: - Helpers

    /// Opens the project in a sidebar, selects `url` and runs Duplicate `times` times, as the menu does.
    private func duplicate(_ url: URL, times: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        sidebar.openProject(at: project)
        XCTAssertTrue(sidebar.selectItem(forURL: url), "could not select \(url.lastPathComponent)", file: file, line: line)
        for _ in 0..<times {
            sidebar.duplicateSelectedSidebarItems(nil)
        }
    }

    private func exists(_ parent: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: parent.appendingPathComponent(name).path)
    }
}
