// ArchiveToolBasePinTests.swift - What the archive tool sites do at the base of lane 13.08
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Pins the argv, the failure words and the path-escape outcome of each archive
/// tool site that has a seam, at base 916a79b07 of Phase 2.13 lane 13.08.
///
/// A test whose name ends in `Refused` and that opens with `XCTExpectFailure`
/// records a defect of the base. The site extracts a symbolic link that leaves
/// its destination. The fix commit of that site removes the expectation.
final class ArchiveToolBasePinTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try DemoProjectFixtures.makeTempDirectory("archive-pin")
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func escapeName() -> String { "escape-\(UUID().uuidString).txt" }

    // MARK: - SafeZipExtractor (unzip, SafeZipExtractor.swift:235)

    func testSafeZipExtractorRunsUnzipWithItsFixedArgvAndNamesStatusAndStderrOnFailure() async throws {
        let zip = tempDir.appendingPathComponent("ok.zip")
        try DemoProjectFixtures.writeProjectArchive(to: zip)
        let destination = tempDir.appendingPathComponent("out", isDirectory: true)
        let fake = try ArchiveToolFixtures.writeFakeTool(in: tempDir, exitCode: 9, stderr: "boom happened")
        do {
            try await SafeZipExtractor(unzipURL: fake.tool).extract(zip, to: destination)
            XCTFail("expected a failure")
        } catch DemoProjectError.extractionFailed(let message) {
            XCTAssertEqual(message, "unzip exited with status 9: boom happened")
        }
        XCTAssertEqual(
            try ArchiveToolFixtures.recordedArgv(fake.argvLog),
            [["-qq", "-o", zip.path, "-d", destination.path]]
        )
    }

    func testSafeZipExtractorCancelStopsTheToolAndThrowsCancelled() async throws {
        let zip = tempDir.appendingPathComponent("ok.zip")
        try DemoProjectFixtures.writeProjectArchive(to: zip)
        let destination = tempDir.appendingPathComponent("out", isDirectory: true)
        let fake = try ArchiveToolFixtures.writeFakeTool(in: tempDir, exitCode: 0, body: "exec sleep 30")
        let extractor = SafeZipExtractor(unzipURL: fake.tool)
        let task = Task { try await extractor.extract(zip, to: destination) }
        try await ArchiveToolFixtures.waitForFile(fake.argvLog)
        let started = ContinuousClock.now
        task.cancel()
        do {
            try await task.value
            XCTFail("expected a cancellation")
        } catch DemoProjectError.cancelled {
            // The cancel reached the tool.
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(15))
    }

    // MARK: - GeneiousArchiveTool (unzip, GeneiousArchiveTool.swift:67)

    func testGeneiousArchiveToolRunsUnzipWithItsFixedArgvAndNamesCommandStatusAndStderr() throws {
        let zip = tempDir.appendingPathComponent("g.zip")
        try Data().write(to: zip)
        let destination = tempDir.appendingPathComponent("out", isDirectory: true)
        let quiet = try ArchiveToolFixtures.writeFakeTool(in: tempDir, name: "quiet-unzip", exitCode: 0)
        try GeneiousArchiveTool(unzipURL: quiet.tool).extract(archiveURL: zip, to: destination)
        XCTAssertEqual(
            try ArchiveToolFixtures.recordedArgv(quiet.argvLog),
            [["-Z1", zip.path], ["-qq", zip.path, "-d", destination.path]]
        )

        let failing = try ArchiveToolFixtures.writeFakeTool(in: tempDir, name: "failing-unzip", exitCode: 9, stderr: "boom happened")
        XCTAssertThrowsError(try GeneiousArchiveTool(unzipURL: failing.tool).listMembers(archiveURL: zip)) { error in
            XCTAssertEqual(
                error as? GeneiousArchiveToolError,
                .unzipFailed(arguments: ["-Z1", zip.path], status: 9, stderr: "boom happened")
            )
            XCTAssertEqual(
                error.localizedDescription,
                "/usr/bin/unzip -Z1 \(zip.path) failed with exit code 9: boom happened"
            )
        }
    }

    func testGeneiousArchiveToolRefusesAParentDirectoryEntryBeforeExtractingAnything() throws {
        let escape = escapeName()
        let zip = tempDir.appendingPathComponent("dotdot.zip")
        try TestZipWriter.write([.file("ok.txt", "ok"), .file("../\(escape)", "pwned")], to: zip)
        let destination = tempDir.appendingPathComponent("out", isDirectory: true)
        XCTAssertThrowsError(try GeneiousArchiveTool().extract(archiveURL: zip, to: destination)) { error in
            XCTAssertEqual(error as? GeneiousArchiveToolError, .unsafeMemberPath("../\(escape)"))
        }
        XCTAssertFalse(ArchiveToolFixtures.exists(destination))
        XCTAssertFalse(ArchiveToolFixtures.exists(tempDir.appendingPathComponent(escape)))
    }

    func testGeneiousArchiveToolSymlinkThatLeavesTheRootIsRefused() throws {
        XCTExpectFailure("Base 916a79b07 extracts the link. Lane 13.08 fixes it in its GeneiousArchiveTool commit.")
        let zip = tempDir.appendingPathComponent("link.zip")
        try TestZipWriter.write([.file("ok.txt", "ok"), .symlink("link", to: "../outside")], to: zip)
        XCTAssertThrowsError(
            try GeneiousArchiveTool().extract(archiveURL: zip, to: tempDir.appendingPathComponent("out", isDirectory: true))
        )
    }

    // MARK: - CzIdImportPreview (ditto, CzIdImportPreview.swift:130)

    private static let czIdReport = [
        "sample_name\tproject_id\tpipeline_version\tnt_db_version\tnr_db_version\ttax_id\ttaxon_name\trank\tnt_read_count\tnt_rpm\tnr_read_count\tnr_rpm",
        "Sample-CZ-001\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t1\troot\troot\t1200\t1000000\t1200\t1000000",
        "Sample-CZ-001\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t10239\tViruses\tsuperkingdom\t88\t73333\t12\t10000",
        "Sample-CZ-001\tProject-42\t8.4\tnt_2025_12_01\tnr_2025_12_01\t2697049\tSevere acute respiratory syndrome coronavirus 2\tspecies\t42\t35000\t5\t4166.7",
    ].joined(separator: "\n") + "\n"

    func testCzIdZipWithAParentDirectoryEntryStaysInsideTheStagingFolder() async throws {
        let escape = escapeName()
        let zip = tempDir.appendingPathComponent("czid.zip")
        try TestZipWriter.write([.file("taxon_report.tsv", Self.czIdReport), .file("../\(escape)", "pwned")], to: zip)
        let preview = try await CzIdImportPreview.scan(zip)
        XCTAssertEqual(preview.sourceKind, .zipArchive)
        XCTAssertEqual(preview.rowCount, 3)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(escape)
        XCTAssertFalse(ArchiveToolFixtures.exists(outside))
    }

    func testCzIdBrokenZipNamesTheArchiveAndTheStderrOfDitto() async throws {
        let zip = tempDir.appendingPathComponent("broken.zip")
        try Data(repeating: 7, count: 100).write(to: zip)
        do {
            _ = try await CzIdImportPreview.scan(zip)
            XCTFail("expected a failure")
        } catch CzIdImportPreviewError.archiveExtractionFailed(let url, let detail) {
            XCTAssertEqual(url.standardizedFileURL, zip.standardizedFileURL)
            XCTAssertTrue(detail.contains("ditto"), detail)
        }
    }

    func testCzIdZipWithASymlinkThatLeavesTheRootIsRefused() async throws {
        XCTExpectFailure("Base 916a79b07 extracts the link. Lane 13.08 fixes it in its CzIdImportPreview commit.")
        let zip = tempDir.appendingPathComponent("czid-link.zip")
        try TestZipWriter.write([.file("taxon_report.tsv", Self.czIdReport), .symlink("link", to: "../outside")], to: zip)
        do {
            _ = try await CzIdImportPreview.scan(zip)
            XCTFail("the archive was accepted")
        } catch {
            // Refused.
        }
    }

    // MARK: - MetagenomicsDatabaseInstaller (tar, MetagenomicsDatabaseInstaller.swift:299)

    func testInstallerTarExtractRecordsItsArgvAndVersionAndTarRefusesAParentDirectoryEntry() async throws {
        let escape = escapeName()
        let archive = tempDir.appendingPathComponent("db.tar.gz")
        try TestTarWriter.write([.file("ok.txt", "ok"), .file("../\(escape)", "pwned")], to: archive)
        let destination = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let result = try await URLSessionTarDatabaseArchiveTransfer().extract(archive: archive, destination: destination)

        XCTAssertEqual(result.argv, ["/usr/bin/tar", "xzf", archive.path, "-C", destination.path])
        XCTAssertTrue(result.toolVersion.hasPrefix("bsdtar "), result.toolVersion)
        XCTAssertEqual(result.exitStatus, 1)
        XCTAssertTrue(result.stderr.contains("Path contains '..'"), result.stderr)
        XCTAssertFalse(ArchiveToolFixtures.exists(tempDir.appendingPathComponent(escape)))
        XCTAssertTrue(ArchiveToolFixtures.exists(destination.appendingPathComponent("ok.txt")))
    }

    func testInstallerTarExtractOfASymlinkThatLeavesTheRootIsRefused() async throws {
        XCTExpectFailure("Base 916a79b07 extracts the link. Lane 13.08 fixes it in its MetagenomicsDatabaseInstaller commit.")
        let archive = tempDir.appendingPathComponent("db-link.tar.gz")
        try TestTarWriter.write([.file("ok.txt", "ok"), .symlink("link", to: "../outside")], to: archive)
        let destination = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            let result = try await URLSessionTarDatabaseArchiveTransfer().extract(archive: archive, destination: destination)
            XCTAssertNotEqual(result.exitStatus, 0, "the archive was accepted")
        } catch {
            // Refused.
        }
    }

    // MARK: - CondaOfflinePackService (tar, CondaOfflinePackService.swift:1083)

    func testCondaRunTarRefusesAParentDirectoryEntryWithTarsOwnWords() throws {
        let escape = escapeName()
        let archive = tempDir.appendingPathComponent("pack.tgz")
        try TestTarWriter.write([.file("ok.txt", "ok"), .file("../\(escape)", "pwned")], to: archive)
        let destination = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try CondaOfflinePackService.runTar(
                executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xf", archive.path, "-C", destination.path],
                operation: "extract"
            )
        ) { error in
            guard case CondaOfflinePackError.archiveFailed(let operation, let stderr) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(operation, "extract")
            XCTAssertTrue(stderr.contains("Path contains '..'"), stderr)
        }
        XCTAssertFalse(ArchiveToolFixtures.exists(tempDir.appendingPathComponent(escape)))
    }
}
