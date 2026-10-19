// ProvenanceExportStagingTests.swift - The stage and publish step of `provenance export`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.38, decision MGR-12.38-B9 items 2 to 4, review fixes 2 and 3. Each test calls
// `ProvenanceCommand.ExportSubcommand.stageAndPublish(outputURL:stage:)` directly with a closure that stages a few
// files, so the class launches no process and runs in milliseconds. The cancel through the real transport is
// ProvenanceExportCancelReplayTests, and the report itself is ProvenanceExportCommandTests.

import Foundation
import XCTest
@testable import LungfishCLI

final class ProvenanceExportStagingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-export-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The sorted names in a folder, hidden ones included.
    private func names(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    /// An existing folder stages inside itself, so a parent the user cannot write (a volume root, the home folder)
    /// still works as it did when the leaf wrote straight into the folder.
    func testAnExistingFolderInAParentThatIsNotWritableIsStillExportedInto() throws {
        try XCTSkipIf(getuid() == 0, "root writes anywhere, so the case cannot fail")
        let parent = directory.appendingPathComponent("volumes", isDirectory: true)
        let output = parent.appendingPathComponent("Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: output.appendingPathComponent("unrelated.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        _ = try ProvenanceCommand.ExportSubcommand.stageAndPublish(outputURL: output) { staging in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try Data("report".utf8).write(to: staging.appendingPathComponent("report.txt"))
        }
        XCTAssertEqual(try names(output), ["report.txt", "unrelated.txt"], "the report landed and no staging folder is left inside")
        XCTAssertEqual(try names(parent), ["Drive"])
    }
}
