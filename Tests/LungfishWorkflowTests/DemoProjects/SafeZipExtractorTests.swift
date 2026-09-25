// SafeZipExtractorTests.swift - Zip-slip, absolute path and symlink refusal
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class SafeZipExtractorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try DemoProjectFixtures.makeTempDirectory("zip")
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testExtractsAValidArchiveWithAnInternalSymlink() async throws {
        let zip = tempDir.appendingPathComponent("ok.zip")
        try DemoProjectFixtures.writeProjectArchive(to: zip)
        let destination = tempDir.appendingPathComponent("out", isDirectory: true)

        try await SafeZipExtractor().extract(zip, to: destination)

        let project = destination.appendingPathComponent(DemoProjectFixtures.folderName)
        let ref = project.appendingPathComponent("Reference Sequences/ref.fa")
        XCTAssertEqual(try String(contentsOf: ref, encoding: .utf8), ">chr1\nACGT\n")
        let link = project.appendingPathComponent("latest.fa")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "Reference Sequences/ref.fa")
    }

    func testCentralDirectoryReportsNamesAndModes() throws {
        let zip = tempDir.appendingPathComponent("ok.zip")
        try DemoProjectFixtures.writeProjectArchive(to: zip)
        let entries = try SafeZipExtractor.readCentralDirectory(of: zip)
        XCTAssertEqual(entries.count, 5)
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertTrue(entries[4].isSymbolicLink)
        XCTAssertEqual(entries[1].path, "\(DemoProjectFixtures.folderName)/metadata.json")
    }

    func testRefusesZipSlipBeforeWritingAnything() async throws {
        try await assertRefused(
            [.file("Project.lungfish/ok.txt", "ok"), .file("Project.lungfish/../../evil.txt", "pwned")],
            reason: "climbs out"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("evil.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("out").path))
    }

    func testRefusesAbsolutePaths() async throws {
        let target = tempDir.appendingPathComponent("absolute-target.txt").path
        try await assertRefused([.file(target, "pwned")], reason: "absolute path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testRefusesBackslashTraversalAndDriveLetters() async throws {
        try await assertRefused([.file("..\\evil.txt", "x")], reason: "backslash")
        try await assertRefused([.file("C:/evil.txt", "x")], reason: "drive letter")
    }

    func testRefusesEntriesWrittenThroughASymlink() async throws {
        let outside = tempDir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try await assertRefused(
            [.symlink("Project.lungfish/link", to: outside.path), .file("Project.lungfish/link/evil.txt", "pwned")],
            reason: "through the symbolic link"
        )
        // Case-insensitive volumes treat LINK and link as the same path.
        try await assertRefused(
            [.symlink("Project.lungfish/link", to: "../.."), .file("Project.lungfish/LINK/evil.txt", "pwned")],
            reason: "through the symbolic link"
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testRefusesSymlinksThatPointOutsideTheDestination() async throws {
        try await assertRefused([.symlink("Project.lungfish/escape", to: "../../../etc/passwd")], reason: "points outside")
        try await assertRefused([.symlink("Project.lungfish/abs", to: "/etc/passwd")], reason: "absolute path")
    }

    func testRefusesDuplicateEntries() async throws {
        try await assertRefused([.file("a.txt", "1"), .file("A.txt", "2")], reason: "more than once")
    }

    func testNonZipFileIsAnExtractionError() async throws {
        let bogus = tempDir.appendingPathComponent("bogus.zip")
        try Data(repeating: 7, count: 100).write(to: bogus)
        do {
            try await SafeZipExtractor().extract(bogus, to: tempDir.appendingPathComponent("out"))
            XCTFail("expected failure")
        } catch DemoProjectError.extractionFailed(let message) {
            XCTAssertTrue(message.contains("not a ZIP archive"), message)
        }
    }

    // MARK: - Helpers

    private func assertRefused(
        _ entries: [TestZipWriter.Entry],
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let zip = tempDir.appendingPathComponent("bad-\(UUID().uuidString).zip")
        try TestZipWriter.write(entries, to: zip)
        let destination = tempDir.appendingPathComponent("out", isDirectory: true)
        do {
            try await SafeZipExtractor().extract(zip, to: destination)
            XCTFail("expected the archive to be refused", file: file, line: line)
        } catch DemoProjectError.unsafeArchive(let message) {
            XCTAssertTrue(message.contains(reason), "“\(message)” lacks “\(reason)”", file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
        try? FileManager.default.removeItem(at: destination)
    }
}
