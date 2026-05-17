// ProjectCreationEnsuresPrimerSchemesFolderTests.swift - Project init creates the Primer Schemes folder
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

/// Pins the contract that ``DocumentManager/createProject(at:name:description:author:)``
/// bootstraps `<project>/Primer Schemes/` so the Import Center and sidebar
/// scanner have a stable home from the project's first moment.
@MainActor
final class ProjectCreationEnsuresPrimerSchemesFolderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCreationEnsuresPrimerSchemesFolderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testCreatingProjectCreatesPrimerSchemesFolder() throws {
        let projectURL = tempDir.appendingPathComponent("TestProject", isDirectory: true)
        let manager = DocumentManager.shared

        let project = try manager.createProject(at: projectURL, name: "TestProject")
        addTeardownBlock { manager.closeActiveProject() }

        let expectedFolder = project.url.appendingPathComponent("Primer Schemes", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedFolder.path, isDirectory: &isDirectory),
            "createProject must create <project>/Primer Schemes/"
        )
        XCTAssertTrue(isDirectory.boolValue, "Primer Schemes must be a directory, not a file")

        // PrimerSchemesFolder.listBundles should enumerate the freshly-created empty folder cleanly.
        XCTAssertEqual(PrimerSchemesFolder.listBundles(in: project.url).count, 0)
    }
}
