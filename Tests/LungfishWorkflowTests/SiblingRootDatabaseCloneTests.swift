// SiblingRootDatabaseCloneTests.swift - Installing a database by cloning another channel's copy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Darwin
import XCTest
@testable import LungfishWorkflow
import LungfishCore

final class SiblingRootDatabaseCloneTests: XCTestCase {
    private var tempDir: URL!
    private var preferencesSuiteName: String!
    private var preferences: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sibling-clone-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        preferencesSuiteName = "SiblingRootDatabaseCloneTests-\(UUID().uuidString)"
        preferences = try XCTUnwrap(UserDefaults(suiteName: preferencesSuiteName))
    }

    override func tearDown() async throws {
        if let preferencesSuiteName { preferences?.removePersistentDomain(forName: preferencesSuiteName) }
        preferences = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private static func inode(_ url: URL) -> ino_t {
        var metadata = stat()
        _ = lstat(url.path, &metadata)
        return metadata.st_ino
    }

    private static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func bundledDatabasesRoot() throws -> URL {
        let root = tempDir.appendingPathComponent("bundled-databases", isDirectory: true)
        for databaseID in ["human-scrubber", "deacon-panhuman", "deacon-ribokmers"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(databaseID, isDirectory: true), withIntermediateDirectories: true
            )
        }
        return root
    }

    // MARK: - DatabaseRegistry (human-scrubber)

    func testHumanScrubberInstallClonesVerifiedSiblingInsteadOfDownloading() async throws {
        let bundledRoot = try bundledDatabasesRoot()
        let siblingDatabases = tempDir.appendingPathComponent("stable-root/databases", isDirectory: true)
        let currentDatabases = tempDir.appendingPathComponent("preview-root/databases", isDirectory: true)
        let downloadDirectory = tempDir.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        var generated = Data(count: 256 * 1024)
        generated.withUnsafeMutableBytes { buffer in
            for index in 0..<buffer.count { buffer[index] = UInt8(truncatingIfNeeded: index * 31) }
        }
        let payload = generated
        let expectedMD5 = Self.md5Hex(payload)

        // The sibling installs through a normal download, which writes the receipt
        // the clone path verifies against.
        let siblingDownloader: ManagedDatabaseDownloader = { url, progress in
            let outputURL = downloadDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            let data = url.lastPathComponent.hasSuffix(".md5")
                ? Data("\(expectedMD5)  human_filter.db.20260706v2\n".utf8) : payload
            try data.write(to: outputURL)
            progress(1.0, Int64(data.count), Int64(data.count))
            return ManagedDatabaseDownloadResult(fileURL: outputURL, wallTime: 0.1)
        }
        let siblingRegistry = DatabaseRegistry(
            bundledDatabasesRoot: bundledRoot, userDatabasesRoot: siblingDatabases,
            managedDatabaseDownloader: siblingDownloader, preferences: UserDefaults(suiteName: preferencesSuiteName)
        )
        let siblingInstalled = try await siblingRegistry.installManagedDatabase("human-scrubber", reinstall: true)
        preferences.removePersistentDomain(forName: preferencesSuiteName)

        // The current channel may fetch the small checksum but must never
        // download the database itself.
        let currentDownloader: ManagedDatabaseDownloader = { url, progress in
            guard url.lastPathComponent.hasSuffix(".md5") else {
                XCTFail("Database payload downloaded although a verified sibling copy exists")
                throw URLError(.badServerResponse)
            }
            let outputURL = downloadDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try Data("\(expectedMD5)  human_filter.db.20260706v2\n".utf8).write(to: outputURL)
            progress(1.0, 1, 1)
            return ManagedDatabaseDownloadResult(fileURL: outputURL, wallTime: 0.01)
        }
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: bundledRoot, userDatabasesRoot: currentDatabases,
            managedDatabaseDownloader: currentDownloader, preferences: UserDefaults(suiteName: preferencesSuiteName),
            siblingDatabaseRoots: [siblingDatabases]
        )

        let installed = try await registry.installManagedDatabase("human-scrubber")

        XCTAssertEqual(installed, currentDatabases.appendingPathComponent("human-scrubber/human_filter.db.20260706v2"))
        XCTAssertEqual(try Data(contentsOf: installed), payload)
        XCTAssertNotEqual(Self.inode(installed), Self.inode(siblingInstalled))
        if APFSCloneSupport.isAPFSVolume(tempDir), let siblingClone = APFSCloneSupport.cloneIdentifier(of: siblingInstalled) {
            XCTAssertEqual(APFSCloneSupport.cloneIdentifier(of: installed), siblingClone)
        }
        let sidecar = installed.deletingLastPathComponent().appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        // JSONEncoder escapes "/" as "\/" in the sidecar, so unescape before matching paths.
        let receipt = try String(contentsOf: sidecar, encoding: .utf8).replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(receipt.contains("sibling-root-clone"), "receipt should name the sibling as the install source")
        XCTAssertTrue(receipt.contains(siblingInstalled.path), "receipt should record the sibling path")
        XCTAssertTrue(receipt.contains(expectedMD5), "receipt should record the verified MD5")
        XCTAssertEqual(preferences.string(forKey: "database.human-scrubber.overrideFilename"), installed.lastPathComponent)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
            .filter { $0.contains(".clone-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testHumanScrubberInstallDownloadsWhenSiblingCopyDoesNotVerify() async throws {
        let bundledRoot = try bundledDatabasesRoot()
        let siblingDatabases = tempDir.appendingPathComponent("stable-root/databases", isDirectory: true)
        let currentDatabases = tempDir.appendingPathComponent("preview-root/databases", isDirectory: true)
        let downloadDirectory = tempDir.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let payload = Data("human-scrubber-payload\n".utf8)
        let expectedMD5 = Self.md5Hex(payload)
        // A sibling file without any receipt cannot be verified, so it is ignored.
        let siblingFile = siblingDatabases.appendingPathComponent("human-scrubber/human_filter.db.20260706v2")
        try FileManager.default.createDirectory(at: siblingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("tampered\n".utf8).write(to: siblingFile)

        let downloads = DownloadLog()
        let downloader: ManagedDatabaseDownloader = { url, progress in
            await downloads.record(url.lastPathComponent)
            let outputURL = downloadDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            let data = url.lastPathComponent.hasSuffix(".md5")
                ? Data("\(expectedMD5)  human_filter.db.20260706v2\n".utf8) : payload
            try data.write(to: outputURL)
            progress(1.0, Int64(data.count), Int64(data.count))
            return ManagedDatabaseDownloadResult(fileURL: outputURL, wallTime: 0.1)
        }
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: bundledRoot, userDatabasesRoot: currentDatabases,
            managedDatabaseDownloader: downloader, preferences: UserDefaults(suiteName: preferencesSuiteName),
            siblingDatabaseRoots: [siblingDatabases]
        )

        let installed = try await registry.installManagedDatabase("human-scrubber")

        XCTAssertEqual(try Data(contentsOf: installed), payload)
        let recorded = await downloads.names
        XCTAssertTrue(recorded.contains("human_filter.db.20260706v2"))
        XCTAssertEqual(try Data(contentsOf: siblingFile), Data("tampered\n".utf8))
    }

    private actor DownloadLog {
        var names: [String] = []
        func record(_ name: String) { names.append(name) }
    }

    // MARK: - MetagenomicsDatabaseRegistry

    private struct RefusingInstaller: MetagenomicsDatabaseInstalling {
        struct Refused: Error {}
        func prepareInstallation(
            database: MetagenomicsDatabaseInfo, databasesBaseURL: URL, threads: Int,
            progress: @Sendable @escaping (Double, String) -> Void
        ) async throws -> PreparedMetagenomicsDatabaseInstallation { throw Refused() }
        func finalize(_ prepared: PreparedMetagenomicsDatabaseInstallation) throws {}
        func rollback(_ prepared: PreparedMetagenomicsDatabaseInstallation) throws {}
    }

    private func fixtureEntry(recipe: MetagenomicsDatabaseInstallationRecipe) -> MetagenomicsDatabaseInfo {
        MetagenomicsDatabaseInfo(
            name: "Fixture Viral", tool: "kraken2", version: nil, sizeBytes: 1,
            catalogID: "fixture-viral", installationRecipe: recipe, description: "fixture", recommendedRAM: 1
        )
    }

    private func writeSiblingKrakenDatabase(
        databasesRoot: URL, recipe: MetagenomicsDatabaseInstallationRecipe, digestOverride: String? = nil
    ) throws -> (path: URL, digest: String) {
        let path = databasesRoot.appendingPathComponent("kraken2/fixture-viral", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        for (name, seed) in [("hash.k2d", 11), ("opts.k2d", 13), ("taxo.k2d", 17)] {
            var data = Data(count: 128 * 1024)
            data.withUnsafeMutableBytes { buffer in
                for index in 0..<buffer.count { buffer[index] = UInt8(truncatingIfNeeded: index &* seed) }
            }
            try data.write(to: path.appendingPathComponent(name))
        }
        try Data("{\"note\":\"sibling receipt\"}".utf8).write(to: path.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        let digest = try MetagenomicsDatabasePayloadDigester.snapshot(at: path).aggregateSHA256
        var entry = fixtureEntry(recipe: recipe)
        entry.path = path
        entry.status = .ready
        entry.version = "built-20260901-abcdef012345"
        entry.payloadDigest = digestOverride ?? digest
        entry.installedAt = Date()
        entry.lastUpdated = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(DatabaseManifest(version: 1, databases: [entry]))
            .write(to: databasesRoot.appendingPathComponent("metagenomics-db-registry.json"))
        return (path, digest)
    }

    func testMetagenomicsDownloadClonesSiblingCopyAndRecordsSource() async throws {
        let recipe = MetagenomicsDatabaseInstallationRecipe.archive(url: URL(string: "https://example.org/fixture-viral.tar.gz")!)
        let siblingDatabases = tempDir.appendingPathComponent("stable-root/databases", isDirectory: true)
        let currentDatabases = tempDir.appendingPathComponent("preview-root/databases", isDirectory: true)
        let sibling = try writeSiblingKrakenDatabase(databasesRoot: siblingDatabases, recipe: recipe)
        let registry = MetagenomicsDatabaseRegistry(
            baseDirectory: currentDatabases, catalog: [fixtureEntry(recipe: recipe)],
            databaseInstaller: RefusingInstaller(),
            siblingCloneInstaller: MetagenomicsSiblingRootCloneInstaller(siblingDatabaseRoots: { _ in [siblingDatabases] })
        )

        let installed = try await registry.downloadDatabase(name: "Fixture Viral") { _, _ in }

        XCTAssertEqual(installed, currentDatabases.appendingPathComponent("kraken2/fixture-viral", isDirectory: true).standardizedFileURL)
        for name in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent(name)),
                           try Data(contentsOf: sibling.path.appendingPathComponent(name)))
            XCTAssertNotEqual(Self.inode(installed.appendingPathComponent(name)), Self.inode(sibling.path.appendingPathComponent(name)))
        }
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(
            fromSidecar: installed.appendingPathComponent(ProvenanceWriter.provenanceFilename)))
        XCTAssertEqual(envelope.options.resolvedDefaults["installSource"]?.stringValue, "sibling-root-clone")
        XCTAssertEqual(envelope.options.resolvedDefaults["clonedFrom"]?.stringValue, sibling.path.path)
        XCTAssertEqual(envelope.options.resolvedDefaults["payloadAggregateSHA256"]?.stringValue, sibling.digest)
        let installedRow = try await registry.installedDatabase(tool: .kraken2)
        let row = try XCTUnwrap(installedRow)
        XCTAssertEqual(row.status, .ready)
        XCTAssertEqual(row.payloadDigest, sibling.digest)
        XCTAssertEqual(row.version, "built-20260901-abcdef012345")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".install-") || $0.hasPrefix(".backup-") }
        XCTAssertTrue(leftovers.isEmpty)
        if APFSCloneSupport.isAPFSVolume(tempDir),
           let siblingClone = APFSCloneSupport.cloneIdentifier(of: sibling.path.appendingPathComponent("hash.k2d")) {
            XCTAssertEqual(APFSCloneSupport.cloneIdentifier(of: installed.appendingPathComponent("hash.k2d")), siblingClone)
        }
    }

    func testMetagenomicsDownloadFallsBackWhenSiblingDigestDoesNotMatch() async throws {
        let recipe = MetagenomicsDatabaseInstallationRecipe.archive(url: URL(string: "https://example.org/fixture-viral.tar.gz")!)
        let siblingDatabases = tempDir.appendingPathComponent("stable-root/databases", isDirectory: true)
        let currentDatabases = tempDir.appendingPathComponent("preview-root/databases", isDirectory: true)
        _ = try writeSiblingKrakenDatabase(databasesRoot: siblingDatabases, recipe: recipe, digestOverride: String(repeating: "0", count: 64))
        let registry = MetagenomicsDatabaseRegistry(
            baseDirectory: currentDatabases, catalog: [fixtureEntry(recipe: recipe)],
            databaseInstaller: RefusingInstaller(),
            siblingCloneInstaller: MetagenomicsSiblingRootCloneInstaller(siblingDatabaseRoots: { _ in [siblingDatabases] })
        )

        do {
            _ = try await registry.downloadDatabase(name: "Fixture Viral") { _, _ in }
            XCTFail("Expected the refusing installer to be reached")
        } catch let error as MetagenomicsDatabaseRegistryError {
            guard case .downloadFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let kraken2 = currentDatabases.appendingPathComponent("kraken2", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: kraken2.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "a rejected clone must leave no staging or payload behind: \(leftovers)")
    }
}
