// DatabaseArchiveLinkRefusalWordsTests.swift - A database archive refused for a link says which link, why, and what to try next
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// SYMLINK-REAL-ARCHIVES (Phase 3.1, step 4, words). A refused link names the entry and the reason, says that nothing was
/// installed, and says what to try next. These words are read by meaning, so each check names one fact the person needs.
final class DatabaseArchiveLinkRefusalWordsTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try DemoProjectFixtures.makeTempDirectory("link-words")
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// What the person reads when the installer refuses the archive, or nil when it accepts the extract.
    private func installerRefusal(of archive: URL) async -> String? {
        let installer = MetagenomicsDatabaseInstaller(
            toolRunner: NoManagedToolsRunner(),
            archiveTransfer: LocalFileArchiveTransfer(archive: archive),
            provenanceWriter: CanonicalMetagenomicsDatabaseInstallProvenanceWriter()
        )
        let database = MetagenomicsDatabaseInfo(
            name: "words", tool: "kraken2", version: "words", sizeBytes: 1, catalogID: "words",
            installationRecipe: .archive(url: URL(string: "https://example.invalid/words.tar.gz")!),
            description: "a database archive with a link", recommendedRAM: 1
        )
        do {
            _ = try await installer.prepareInstallation(
                database: database,
                databasesBaseURL: scratch.appendingPathComponent("databases", isDirectory: true),
                threads: 1,
                progress: { _, _ in }
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// What the person reads when the EsViritu extract refuses the archive, or nil when it accepts it.
    private func esVirituRefusal(of archive: URL) async throws -> String? {
        let manager = EsVirituDatabaseManager(storageRoot: scratch.appendingPathComponent("storage", isDirectory: true))
        let destination = scratch.appendingPathComponent("esviritu-viral-db", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try await manager.extractTarball(at: archive, to: destination)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func assertNamesLinkReasonAndNextStep(
        _ message: String?, link: String, reason: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let message = try XCTUnwrap(message, "the archive was accepted", file: file, line: line)
        XCTAssertTrue(message.contains("\u{201C}\(link)\u{201D}"), "the entry is not named: \(message)", file: file, line: line)
        XCTAssertTrue(message.contains(reason), "the reason is not given: \(message)", file: file, line: line)
        XCTAssertTrue(message.contains("Nothing was installed."), "it does not say nothing was installed: \(message)", file: file, line: line)
        XCTAssertTrue(
            message.contains("Download the archive again from its official source."),
            "it does not say to download the archive again: \(message)", file: file, line: line
        )
        XCTAssertTrue(
            message.contains("repack it with each link replaced by a copy of the file it points to"),
            "it does not say how to repack an archive of your own: \(message)", file: file, line: line
        )
    }

    func testInstallerNamesALinkThatLeavesTheDatabaseFolderAndWhatToTryNext() async throws {
        let archive = scratch.appendingPathComponent("outside.tar.gz")
        try TestTarWriter.write([.file("hash.k2d", "h"), .symlink("link", to: "../../outside")], to: archive)
        try assertNamesLinkReasonAndNextStep(
            await installerRefusal(of: archive), link: "link",
            reason: "points outside the database folder (../../outside)"
        )
    }

    func testInstallerNamesAnAbsoluteLinkAndWhatToTryNext() async throws {
        let archive = scratch.appendingPathComponent("absolute.tar.gz")
        try TestTarWriter.write([.file("hash.k2d", "h"), .symlink("link", to: "/etc/hosts")], to: archive)
        try assertNamesLinkReasonAndNextStep(
            await installerRefusal(of: archive), link: "link", reason: "points to the absolute path /etc/hosts"
        )
    }

    func testEsVirituNamesALinkThatLeavesTheDatabaseFolderAndWhatToTryNext() async throws {
        let archive = scratch.appendingPathComponent("esviritu-outside.tar.gz")
        try TestTarWriter.write([.file("db/ok.fna", "ok"), .symlink("db/link", to: "../../outside")], to: archive)
        try assertNamesLinkReasonAndNextStep(
            try await esVirituRefusal(of: archive), link: "link",
            reason: "points outside the database folder (../../outside)"
        )
    }

    /// A link that stays inside the folder installs, as it did before the words changed. This pins the accepted side.
    func testARelativeLinkThatStaysInsideTheFolderIsAccepted() async throws {
        let archive = scratch.appendingPathComponent("inside.tar.gz")
        try TestTarWriter.write(
            [.file("hash.k2d", "h"), .directory("sub"), .file("sub/data.txt", "d"), .symlink("sub/alias", to: "data.txt")],
            to: archive
        )
        let destination = scratch.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let result = try await URLSessionTarDatabaseArchiveTransfer().extract(archive: archive, destination: destination)
        XCTAssertEqual(result.exitStatus, 0, result.stderr)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("sub/alias").path),
            "data.txt"
        )
    }
}
