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

    // MARK: - The merge publish's refusals and the cleanup

    private struct StageFailed: Error {}

    /// Runs `stageAndPublish` with a stage closure that returns nothing.
    private func publish(_ output: URL, _ stage: (URL) throws -> Void) throws {
        try ProvenanceCommand.ExportSubcommand.stageAndPublish(outputURL: output, stage: stage)
    }

    /// Writes each file (relative path to text) into the staging folder, creating folders as needed.
    private func stageFiles(_ staging: URL, _ files: [String: String]) throws {
        for (relative, text) in files {
            let file = staging.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
    }

    /// A staged folder against a file of that name in the existing output is refused before anything in the output
    /// changes, and no staging folder is left.
    func testAStagedFolderMeetingAFileOfThatNameIsRefusedBeforeAnythingChanges() throws {
        let parent = directory.appendingPathComponent("reports", isDirectory: true)
        let output = parent.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: output.appendingPathComponent("keep.txt"))
        try Data("old".utf8).write(to: output.appendingPathComponent("provenance"))
        XCTAssertThrowsError(try publish(output) { staging in
            try stageFiles(staging, ["report.txt": "report", "provenance/record.json": "{}"])
        }) { error in
            XCTAssertTrue(String(describing: error).contains("holds a file named provenance"), "\(error)")
        }
        XCTAssertEqual(try names(output), ["keep.txt", "provenance"], "nothing was published and no staging folder is left inside")
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("provenance"), encoding: .utf8), "old")
        XCTAssertEqual(try names(parent), ["export"], "no staging folder is left beside the output")
    }

    /// The reverse order, a staged file against a folder of that name in the existing output.
    func testAStagedFileMeetingAFolderOfThatNameIsRefusedBeforeAnythingChanges() throws {
        let parent = directory.appendingPathComponent("reports", isDirectory: true)
        let output = parent.appendingPathComponent("export", isDirectory: true)
        let folder = output.appendingPathComponent("report.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: output.appendingPathComponent("keep.txt"))
        let before = try names(output)
        XCTAssertThrowsError(try publish(output) { staging in
            try stageFiles(staging, ["report.txt": "report", "extra.txt": "extra"])
        }) { error in
            XCTAssertTrue(String(describing: error).contains("holds a folder named report.txt"), "\(error)")
        }
        XCTAssertEqual(try names(output), before, "the output's listing is unchanged")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists && isDirectory.boolValue, "the folder is still a folder")
        XCTAssertEqual(try names(parent), ["export"], "no staging folder is left beside the output")
    }

    /// A stage that fails leaves no staging folder, for a new output and for an existing one.
    func testAFailedStageLeavesNoStagingFolder() throws {
        let newParent = directory.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: newParent, withIntermediateDirectories: true)
        XCTAssertThrowsError(try publish(newParent.appendingPathComponent("export", isDirectory: true)) { staging in
            try stageFiles(staging, ["partial.txt": "partial"])
            throw StageFailed()
        }) { error in
            XCTAssertTrue(error is StageFailed, "the stage's own error is rethrown, it was \(error)")
        }
        XCTAssertEqual(try names(newParent), [], "a failed run leaves neither the output nor its staging folder")

        let existingParent = directory.appendingPathComponent("existing", isDirectory: true)
        let existing = existingParent.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("keep.txt"))
        XCTAssertThrowsError(try publish(existing) { staging in
            try stageFiles(staging, ["partial.txt": "partial"])
            throw StageFailed()
        }) { error in
            XCTAssertTrue(error is StageFailed, "the stage's own error is rethrown, it was \(error)")
        }
        XCTAssertEqual(try names(existing), ["keep.txt"], "a failed run leaves the existing folder as it was")
        XCTAssertEqual(try names(existingParent), ["export"])
    }

    /// An output that is a regular file is refused before the stage runs.
    func testAFileAsOutputIsRefusedBeforeAnythingIsStaged() throws {
        let parent = directory.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let output = parent.appendingPathComponent("export.txt")
        try Data("old".utf8).write(to: output)
        XCTAssertThrowsError(try publish(output) { _ in
            XCTFail("a file as output is refused before anything is staged")
        }) { error in
            XCTAssertTrue(String(describing: error).contains("is a file"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: output), Data("old".utf8), "the file is as it was")
        XCTAssertEqual(try names(parent), ["export.txt"], "no staging folder is left beside the file")
    }
}
