// OfficialDatabaseArchiveConformanceTests.swift - The official database archives install through the real link check
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// SYMLINK-REAL-ARCHIVES (Phase 3.1, `docs/contracts/SCOPE-AND-DELIVERY.md:88`). A change that refuses user input lands
/// only after it passes on the real files users feed it. Database archive install refuses a link that leaves its folder,
/// so this class installs the two official archives through the code the app runs. It reads each archive where the golden
/// environment keeps it and never writes there. An archive that is not on this Mac skips with its path, so no gate
/// downloads anything. The class name holds `Conformance`, so the unit tier does not run it.
final class OfficialDatabaseArchiveConformanceTests: XCTestCase {
    private static let downloads = "/Users/Shared/lungfish-golden/downloads"
    private var scratch: URL!

    /// The scratch root sits under `$TMPDIR` when it is set, so a lane can keep the installs inside its build folder
    /// and never touch the managed storage root. Each test removes it, and the run prints where it was.
    override func setUpWithError() throws {
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        scratch = base.appendingPathComponent("official-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        print("official archive scratch root: \(scratch.path)")
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func officialArchive(_ name: String) throws -> URL {
        let path = "\(Self.downloads)/\(name)"
        try XCTSkipUnless(
            FileManager.default.isReadableFile(atPath: path),
            "The official archive \(name) is not at \(path), so its install was not tried. This test never downloads it."
        )
        return try ownedCopy(of: URL(fileURLWithPath: path))
    }

    /// A copy of an official archive inside the scratch root, so nothing the test runs can delete the original. The
    /// scratch root is removed in `tearDownWithError`, and the copy is a clone on APFS.
    private func ownedCopy(of archive: URL) throws -> URL {
        let copy = scratch.appendingPathComponent(archive.lastPathComponent)
        try FileManager.default.copyItem(at: archive, to: copy)
        return copy
    }

    private func install(
        archive: URL, tool: String, catalogID: String, source: String
    ) async throws -> PreparedMetagenomicsDatabaseInstallation {
        let installer = MetagenomicsDatabaseInstaller(
            toolRunner: NoManagedToolsRunner(),
            archiveTransfer: LocalFileArchiveTransfer(archive: archive),
            provenanceWriter: CanonicalMetagenomicsDatabaseInstallProvenanceWriter()
        )
        let database = MetagenomicsDatabaseInfo(
            name: catalogID, tool: tool, version: "official", sizeBytes: 1, catalogID: catalogID,
            installationRecipe: .archive(url: try XCTUnwrap(URL(string: source))),
            description: "the official archive \(archive.lastPathComponent)", recommendedRAM: 1
        )
        return try await installer.prepareInstallation(
            database: database,
            databasesBaseURL: scratch.appendingPathComponent("databases", isDirectory: true),
            threads: 1,
            progress: { _, _ in }
        )
    }

    private func assertRegularFiles(_ names: [String], in root: URL, file: StaticString = #filePath, line: UInt = #line) {
        for name in names {
            let url = root.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            XCTAssertEqual(values?.isRegularFile, true, "\(name) is missing from the installed database", file: file, line: line)
            XCTAssertGreaterThan(values?.fileSize ?? 0, 0, "\(name) is empty", file: file, line: line)
        }
    }

    /// The Kraken2 viral archive installs through `MetagenomicsDatabaseInstaller`, the route `downloadDatabase` takes
    /// for an archive recipe. Its extract runs `tar` and then the link check, so a refusal throws here.
    func testKraken2ViralArchiveInstalls() async throws {
        let archive = try officialArchive("k2_viral_20260626.tar.gz")
        let prepared = try await install(
            archive: archive, tool: "kraken2", catalogID: "official-kraken2-viral",
            source: "https://genome-idx.s3.amazonaws.com/kraken/k2_viral_20260626.tar.gz"
        )
        assertRegularFiles(
            ["hash.k2d", "opts.k2d", "taxo.k2d", "database150mers.kmer_distrib"], in: prepared.result.finalURL
        )
    }

    /// The EsViritu archive installs through the same installer when a catalog row carries an archive recipe.
    func testEsVirituArchiveInstallsThroughTheInstaller() async throws {
        let archive = try officialArchive("esviritu_db_v3.2.4.tar.gz")
        let prepared = try await install(
            archive: archive, tool: MetagenomicsTool.esviritu.rawValue, catalogID: "official-esviritu",
            source: EsVirituDatabaseManager.downloadURL
        )
        assertRegularFiles(
            ["v3.2.4/virus_pathogen_database.fna", "v3.2.4/virus_pathogen_database.mmi"], in: prepared.result.finalURL
        )
    }

    /// The EsViritu wizard and `lungfish-cli esviritu db download` extract with `EsVirituDatabaseManager`, which strips
    /// the archive's `v3.2.4/` folder and runs the same link check.
    func testEsVirituArchiveExtractsThroughTheDatabaseManager() async throws {
        let archive = try officialArchive("esviritu_db_v3.2.4.tar.gz")
        let manager = EsVirituDatabaseManager(storageRoot: scratch.appendingPathComponent("storage", isDirectory: true))
        let destination = scratch.appendingPathComponent("esviritu-viral-db", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try await manager.extractTarball(at: archive, to: destination)
        assertRegularFiles(
            ["virus_pathogen_database.fna", "virus_pathogen_database.mmi", "virus_pathogen_database.all_metadata.tsv"],
            in: destination
        )
    }
}

/// An archive transfer that hands the installer a file already on disk and extracts it with the real `tar` step.
struct LocalFileArchiveTransfer: MetagenomicsDatabaseArchiveTransferring {
    let archive: URL
    private let real = URLSessionTarDatabaseArchiveTransfer()

    func download(from source: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        progress(1)
        return archive
    }

    func extractionToolVersion() async throws -> String { try await real.extractionToolVersion() }

    func extract(archive: URL, destination: URL) async throws -> MetagenomicsDatabaseToolResult {
        try await real.extract(archive: archive, destination: destination)
    }
}

/// An archive recipe runs no managed tool, so this runner refuses every call.
struct NoManagedToolsRunner: MetagenomicsDatabaseToolRunning {
    func run(
        name: String, arguments: [String], environment: String, workingDirectory: URL, timeout: TimeInterval
    ) async throws -> MetagenomicsDatabaseToolResult {
        throw MetagenomicsDatabaseInstallerError.missingManagedTool(name: name)
    }

    func executableDirectory(environment: String) async throws -> URL {
        throw MetagenomicsDatabaseInstallerError.missingManagedTool(name: environment)
    }
}
