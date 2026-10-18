// ImportStagedPublishExFATTests.swift - The stage of import msa and import tree sits on the destination's volume
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.06 (review of M2, fix 6). `publishStagedBundle` writes a bundle into a stage and publishes it
// with one exclusive rename, which needs the stage and the destination on one volume. The stage sits in the
// project's temporary folder, or outside a project in the replacement folder that `itemReplacementDirectory` makes
// appropriate for the destination's parent. Every other test of the stage runs on the boot volume, where any stage
// shares the volume, and `scripts/testing/exfat-tests.sh --simulate` changes the rename flags and not the volume.
// These cases run on a real ExFAT volume and skip without one. Run them with
// `scripts/testing/exfat-tests.sh ImportStagedPublishExFATTests`.

import Foundation
import LungfishIO
import XCTest
@testable import LungfishCLI

final class ImportStagedPublishExFATTests: XCTestCase {
    private var root: URL?

    /// What the write closure saw of its stage.
    private struct StageFacts: Sendable {
        let stageRoot: String
        let volumePath: String?
    }

    override func setUpWithError() throws {
        guard let volume = ProcessInfo.processInfo.environment["LUNGFISH_EXFAT_TEST_ROOT"], !volume.isEmpty else {
            throw XCTSkip("Set LUNGFISH_EXFAT_TEST_ROOT to an ExFAT volume root to run this test.")
        }
        var information = statfs()
        guard statfs(volume, &information) == 0 else {
            throw XCTSkip("LUNGFISH_EXFAT_TEST_ROOT does not name a mounted volume.")
        }
        let typeName = withUnsafeBytes(of: information.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard typeName == "exfat" else {
            throw XCTSkip("LUNGFISH_EXFAT_TEST_ROOT is \(typeName), not exfat.")
        }
        let folder = URL(fileURLWithPath: volume, isDirectory: true)
            .appendingPathComponent("import-staged-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    /// A destination in a plain folder has its stage in the replacement folder of the destination's volume.
    func testAStagedImportToAnExFATFolderPublishesTheBundle() async throws {
        let folder = try XCTUnwrap(root)
        let bundle = folder.appendingPathComponent("aln.lungfishmsa", isDirectory: true)

        let facts = try await publish(bundle, prefix: "import-msa-")

        try assertPublished(bundle, facts)
    }

    /// A destination in a project has its stage in the project's `.tmp`, on the project's volume.
    func testAStagedImportToAnExFATProjectPublishesTheBundle() async throws {
        let folder = try XCTUnwrap(root)
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Multiple Sequence Alignments/aln.lungfishmsa", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)

        let facts = try await publish(bundle, prefix: "import-msa-")

        try assertPublished(bundle, facts)
        // The stage path comes back without the `/private` of the volume's mount path, so both sides are resolved.
        let stageParent = URL(fileURLWithPath: facts.stageRoot).deletingLastPathComponent().resolvingSymlinksInPath().path
        let temporaryFolder = ProjectTempDirectory.tempRoot(for: project).resolvingSymlinksInPath().path
        XCTAssertEqual(stageParent, temporaryFolder, "the stage sits in the project's .tmp. \(facts.stageRoot)")
    }

    // MARK: - Helpers

    /// Runs the leaf's staged publish with a writer that makes a one-file bundle and reports where its stage sits.
    private func publish(_ bundle: URL, prefix: String) async throws -> StageFacts {
        try await publishStagedBundle(at: bundle, prefix: prefix, guardedBy: ImportDestination()) { (stagedURL: URL) throws -> StageFacts in
            try FileManager.default.createDirectory(at: stagedURL, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: stagedURL.appendingPathComponent("manifest.json"))
            let volume = try stagedURL.resourceValues(forKeys: [.volumeURLKey]).volume
            return StageFacts(stageRoot: stagedURL.deletingLastPathComponent().path, volumePath: volume?.path)
        }
    }

    /// The bundle exists, the stage is gone, and the stage sat on the volume of the destination's folder.
    private func assertPublished(
        _ bundle: URL, _ facts: StageFacts, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path),
            "the bundle was published", file: file, line: line
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: facts.stageRoot), "the stage is removed", file: file, line: line)
        let destinationVolume = try bundle.deletingLastPathComponent().resourceValues(forKeys: [.volumeURLKey]).volume?.path
        XCTAssertNotNil(destinationVolume, "the destination's folder names a volume", file: file, line: line)
        XCTAssertEqual(facts.volumePath, destinationVolume, "the stage shares the destination's volume", file: file, line: line)
    }
}
