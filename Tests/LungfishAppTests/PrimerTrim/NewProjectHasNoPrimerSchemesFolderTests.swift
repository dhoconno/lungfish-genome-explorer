// NewProjectHasNoPrimerSchemesFolderTests.swift - A new project starts without a Primer Schemes folder
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

/// Pins that ``DocumentManager/createProject(at:name:description:author:)`` does not
/// create `<project>/Primer Schemes/` (owner, 2026-10-01): an empty project's sidebar
/// shows nothing it does not hold. The folder appears when the first scheme is saved.
@MainActor
final class NewProjectHasNoPrimerSchemesFolderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewProjectHasNoPrimerSchemesFolderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testCreatingProjectDoesNotCreatePrimerSchemesFolder() throws {
        let projectURL = tempDir.appendingPathComponent("TestProject", isDirectory: true)
        let manager = DocumentManager.shared

        let project = try manager.createProject(at: projectURL, name: "TestProject")
        addTeardownBlock { manager.closeActiveProject() }

        XCTAssertNil(PrimerSchemesFolder.folderURL(in: project.url), "A new project has no Primer Schemes folder")
        XCTAssertEqual(PrimerSchemesFolder.listBundles(in: project.url).count, 0)
        XCTAssertFalse(
            SidebarProjectScanner.scanRootNodes(from: project.url).contains { $0.title == PrimerSchemesFolder.folderName },
            "The sidebar of a new project does not list Primer Schemes"
        )
    }

    func testEmptyPrimerSchemesFolderFromAnOlderProjectIsNotListed() throws {
        let projectURL = tempDir.appendingPathComponent("Older.lungfish", isDirectory: true)
        _ = try PrimerSchemesFolder.ensureFolder(in: projectURL)
        XCTAssertFalse(SidebarProjectScanner.scanRootNodes(from: projectURL).contains { $0.title == PrimerSchemesFolder.folderName })

        try ">p\nACGT\n".write(
            to: projectURL.appendingPathComponent("Primer Schemes/scheme.fasta"), atomically: true, encoding: .utf8
        )
        XCTAssertTrue(SidebarProjectScanner.scanRootNodes(from: projectURL).contains { $0.title == PrimerSchemesFolder.folderName })
    }
}
