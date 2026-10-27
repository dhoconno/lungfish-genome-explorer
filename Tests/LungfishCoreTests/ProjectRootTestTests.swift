// ProjectRootTestTests.swift - The one test of whether a folder is a Lungfish project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane PROJECT-ROOT (walk WF-3 and WF-2b, ARCH's design). A folder is a project when its name ends in
// `.lungfish`, or when it holds `metadata.json` and the project database, as Finder's copy `P.lungfish copy` does.

import XCTest
import LungfishTestSupport
@testable import LungfishCore

@MainActor
final class ProjectRootTestTests: XCTestCase {

    /// A folder named `X.lungfish` is a project with nothing in it, as a test fixture is.
    func testExtensionAloneIsAProject() throws {
        let folder = try makeRoot().appendingPathComponent("Fixture.LUNGFISH", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertTrue(ProjectRootTest.isProjectRoot(folder))
    }

    /// Finder names a copy of `P.lungfish` `P.lungfish copy`. It holds the metadata and the database the app opens.
    func testFinderCopyNameWithMetadataAndDatabaseIsAProject() throws {
        let root = try makeRoot()
        let original = root.appendingPathComponent("P.lungfish", isDirectory: true)
        _ = try ProjectFile.create(at: original, name: "P")
        let copy = root.appendingPathComponent("P.lungfish copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)

        XCTAssertTrue(ProjectRootTest.isProjectRoot(copy))
    }

    /// An older project's database is `project.db`, and a project renamed without its extension still opens.
    func testRenamedProjectWithTheOlderDatabaseNameIsAProject() throws {
        let folder = try makeRoot().appendingPathComponent("Renamed Project", isDirectory: true)
        try makeFiles(["metadata.json", "project.db"], in: folder)

        XCTAssertTrue(ProjectRootTest.isProjectRoot(folder))
    }

    /// A result folder or a bundle may hold its own `metadata.json`. With no project database it is not a project.
    func testMetadataJSONWithoutDatabaseIsNotAProject() throws {
        let folder = try makeRoot().appendingPathComponent("kraken2-result", isDirectory: true)
        try makeFiles(["metadata.json"], in: folder)

        XCTAssertFalse(ProjectRootTest.isProjectRoot(folder))
    }

    /// A plain folder, and a folder that holds only the `.lungfish/` lock folder, are not projects.
    func testPlainFolderIsNotAProject() throws {
        let root = try makeRoot()
        let plain = root.appendingPathComponent("Plain Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let locked = root.appendingPathComponent("Locked Folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: locked.appendingPathComponent(".lungfish", isDirectory: true), withIntermediateDirectories: true
        )

        XCTAssertFalse(ProjectRootTest.isProjectRoot(plain))
        XCTAssertFalse(ProjectRootTest.isProjectRoot(locked))
        XCTAssertFalse(ProjectRootTest.isProjectRoot(root.appendingPathComponent("Missing Folder", isDirectory: true)))
    }

    // MARK: - Helpers

    private func makeRoot() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "project-root-test")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        return root
    }

    private func makeFiles(_ names: [String], in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            try Data("{}".utf8).write(to: folder.appendingPathComponent(name))
        }
    }
}
