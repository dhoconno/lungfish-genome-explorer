// DatabaseUpdateFlowTests.swift - Staged, checksum-verified database updates
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import CryptoKit
@testable import LungfishWorkflow
import LungfishTestSupport

/// Covers the update flow that stages a new database copy beside the installed one,
/// verifies it, swaps it in atomically, and removes the superseded copy.
final class DatabaseUpdateFlowTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("database-update-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Metagenomics registry

    func testMetagenomicsUpdateSwapsAndRemovesOld() async throws {
        let base = tempDir!
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await registry.loadIfNeeded()

        let oldDir = base.appendingPathComponent("kraken2/viral", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try writeKraken2Payload(at: oldDir, marker: "old")
        _ = try await registry.registerExisting(at: oldDir, name: "Viral")

        await registry.setArchiveInstallerForTesting { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Self.writeKraken2Payload(at: destination, marker: "new")
            return nil
        }

        try await registry.updateDatabase(catalogID: "kraken2-viral") { _, _ in }

        let stored = try await registry.database(named: "Viral")
        let db = try XCTUnwrap(stored)
        XCTAssertEqual(db.version, ManagedToolLock.bundled.database(id: "kraken2-viral")?.version)
        let installedPath = try XCTUnwrap(db.path)
        XCTAssertEqual(installedPath.standardizedFileURL, oldDir.standardizedFileURL)
        XCTAssertEqual(
            try String(contentsOf: installedPath.appendingPathComponent("hash.k2d"), encoding: .utf8),
            "new"
        )
        XCTAssertEqual(db.status, .ready)

        // The promoted copy carries a canonical install receipt naming the new version.
        let sidecar = installedPath.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(fromSidecar: sidecar))
        XCTAssertEqual(envelope.workflowName, "metagenomics.database.install")
        XCTAssertEqual(
            envelope.options.resolvedDefaults["updatedToVersion"]?.stringValue,
            ManagedToolLock.bundled.database(id: "kraken2-viral")?.version
        )
        XCTAssertEqual(
            envelope.options.resolvedDefaults["intendedFinalPath"]?.stringValue,
            installedPath.standardizedFileURL.path
        )

        // No staging or backup residue is left behind.
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: base.appendingPathComponent("kraken2").path
        )
        XCTAssertEqual(siblings.sorted(), ["viral"])
    }

    func testMetagenomicsUpdatePersistsNewVersionAcrossReload() async throws {
        let base = tempDir!
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await registry.loadIfNeeded()

        let oldDir = base.appendingPathComponent("kraken2/viral", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try writeKraken2Payload(at: oldDir, marker: "old")
        _ = try await registry.registerExisting(at: oldDir, name: "Viral")

        await registry.setArchiveInstallerForTesting { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Self.writeKraken2Payload(at: destination, marker: "new")
            return nil
        }
        try await registry.updateDatabase(catalogID: "kraken2-viral") { _, _ in }

        let reloaded = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await reloaded.loadIfNeeded()
        let stored = try await reloaded.database(named: "Viral")
        let db = try XCTUnwrap(stored)
        XCTAssertEqual(db.version, ManagedToolLock.bundled.database(id: "kraken2-viral")?.version)
        XCTAssertNotNil(db.installedAt)
    }

    func testChecksumMismatchKeepsOldCopy() async throws {
        let base = tempDir!
        let oldDir = try seedInstalledEsVirituDatabase(in: base, marker: "old")
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await registry.loadIfNeeded()

        let archiveURL = tempDir.appendingPathComponent("payload.tar.gz")
        try Data("archive".utf8).write(to: archiveURL)
        await registry.setArchiveInstallerForTesting { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try "new".write(to: destination.appendingPathComponent("db.fna"), atomically: true, encoding: .utf8)
            return archiveURL
        }
        // The shipped manifest carries no checksum for this entry, so the expectation
        // seam supplies one; the compute seam returns a value that cannot match it.
        await registry.setExpectedChecksumForTesting { _ in
            MetagenomicsDatabaseChecksum(algorithm: .md5, hex: "deadbeef")
        }
        await registry.setComputeChecksumForTesting { _, _ in "feedface" }

        await XCTAssertThrowsErrorAsync(
            try await registry.updateDatabase(catalogID: "esviritu-viral-v3") { _, _ in }
        ) { error in
            guard case MetagenomicsDatabaseRegistryError.checksumMismatch(let name, _, _) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(name, "EsViritu Viral DB")
        }

        XCTAssertEqual(
            try String(contentsOf: oldDir.appendingPathComponent("db.fna"), encoding: .utf8),
            "old"
        )
        let stored = try await registry.database(named: "EsViritu Viral DB")
        let db = try XCTUnwrap(stored)
        XCTAssertEqual(db.path?.standardizedFileURL, oldDir.standardizedFileURL)
        XCTAssertNotEqual(db.version, "v3.2.4")

        // Staging is cleaned up on the failure path.
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: base.appendingPathComponent("esviritu").path
        )
        XCTAssertEqual(siblings.sorted(), ["esviritu-viral-db"])
    }

    func testMatchingChecksumCompletesUpdate() async throws {
        let base = tempDir!
        let oldDir = try seedInstalledEsVirituDatabase(in: base, marker: "old")
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await registry.loadIfNeeded()

        let archiveURL = tempDir.appendingPathComponent("payload.tar.gz")
        try Data("archive".utf8).write(to: archiveURL)
        await registry.setArchiveInstallerForTesting { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try "new".write(to: destination.appendingPathComponent("db.fna"), atomically: true, encoding: .utf8)
            return archiveURL
        }
        await registry.setExpectedChecksumForTesting { _ in
            MetagenomicsDatabaseChecksum(algorithm: .sha256, hex: "ABC123")
        }
        await registry.setComputeChecksumForTesting { _, _ in "abc123" }

        try await registry.updateDatabase(catalogID: "esviritu-viral-v3") { _, _ in }

        let stored = try await registry.database(named: "EsViritu Viral DB")
        let db = try XCTUnwrap(stored)
        XCTAssertEqual(db.version, "v3.2.4")
        XCTAssertEqual(
            try String(contentsOf: XCTUnwrap(db.path).appendingPathComponent("db.fna"), encoding: .utf8),
            "new"
        )
    }

    func testUpdateRestoresOldCopyWhenStagedPayloadIsInvalid() async throws {
        let base = tempDir!
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await registry.loadIfNeeded()

        let oldDir = base.appendingPathComponent("kraken2/viral", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try writeKraken2Payload(at: oldDir, marker: "old")
        _ = try await registry.registerExisting(at: oldDir, name: "Viral")

        // Staging lands an incomplete Kraken2 payload (no opts.k2d / taxo.k2d).
        await registry.setArchiveInstallerForTesting { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try "new".write(to: destination.appendingPathComponent("hash.k2d"), atomically: true, encoding: .utf8)
            return nil
        }

        await XCTAssertThrowsErrorAsync(
            try await registry.updateDatabase(catalogID: "kraken2-viral") { _, _ in }
        )

        XCTAssertEqual(
            try String(contentsOf: oldDir.appendingPathComponent("hash.k2d"), encoding: .utf8),
            "old"
        )
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: base.appendingPathComponent("kraken2").path
        )
        XCTAssertEqual(siblings.sorted(), ["viral"])
    }

    func testUpdateRejectsLocallyBuiltSpecialDatabases() async throws {
        let base = tempDir!
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await registry.loadIfNeeded()

        guard let special = MetagenomicsDatabaseInfo.builtInCatalog.first(where: { entry in
            if case .kraken2Special = entry.installationRecipe { return true }
            return false
        }), let catalogID = special.catalogID else {
            throw XCTSkip("Manifest pins no locally built Kraken2 special database")
        }

        let installDir = base.appendingPathComponent("kraken2/special", isDirectory: true)
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        try writeKraken2Payload(at: installDir, marker: "old")
        _ = try await registry.registerExisting(at: installDir, name: special.name)

        await XCTAssertThrowsErrorAsync(
            try await registry.updateDatabase(catalogID: catalogID) { _, _ in }
        ) { error in
            guard case MetagenomicsDatabaseRegistryError.updateNotSupported = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testUpdateThrowsWhenCatalogEntryIsNotInstalled() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        try await registry.loadIfNeeded()

        await XCTAssertThrowsErrorAsync(
            try await registry.updateDatabase(catalogID: "kraken2-viral") { _, _ in }
        ) { error in
            guard case MetagenomicsDatabaseRegistryError.databaseNotFound = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    // MARK: - Crash recovery

    /// A crash between the two renames leaves the installed directory missing and a
    /// `.old-*` sibling holding the previous payload. Load must put it back.
    func testLoadRestoresPreviousCopyAfterInterruptedSwap() async throws {
        let base = tempDir!
        let installedPath = try seedInstalledViralDatabase(in: base, marker: "old")

        // Simulate the crash state: installed dir renamed away, staging left behind.
        let retired = base.appendingPathComponent("kraken2/.viral.old-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: installedPath, to: retired)
        let staging = base.appendingPathComponent("kraken2/.viral.staging-20240904", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Self.writeKraken2Payload(at: staging, marker: "new")

        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await registry.loadIfNeeded()

        let stored = try await registry.database(named: "Viral")
        let db = try XCTUnwrap(stored)
        let recoveredPath = try XCTUnwrap(db.path)
        XCTAssertEqual(recoveredPath.standardizedFileURL, installedPath.standardizedFileURL)
        XCTAssertEqual(db.status, .ready)
        XCTAssertEqual(
            try String(contentsOf: recoveredPath.appendingPathComponent("hash.k2d"), encoding: .utf8),
            "old"
        )
        // Both orphans are swept.
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: base.appendingPathComponent("kraken2").path
        )
        XCTAssertEqual(siblings.sorted(), ["viral"])
    }

    /// If only a complete staging copy survives, it is promoted and the row takes the
    /// version recorded in the staging directory name.
    func testLoadPromotesCompleteStagingCopyWhenNoPreviousCopySurvives() async throws {
        let base = tempDir!
        let installedPath = try seedInstalledViralDatabase(in: base, marker: "old")
        try FileManager.default.removeItem(at: installedPath)

        let staging = base.appendingPathComponent("kraken2/.viral.staging-20240904", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Self.writeKraken2Payload(at: staging, marker: "new")

        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await registry.loadIfNeeded()

        let stored = try await registry.database(named: "Viral")
        let db = try XCTUnwrap(stored)
        let recoveredPath = try XCTUnwrap(db.path)
        XCTAssertEqual(db.status, .ready)
        XCTAssertEqual(db.version, "20240904")
        XCTAssertEqual(
            try String(contentsOf: recoveredPath.appendingPathComponent("hash.k2d"), encoding: .utf8),
            "new"
        )
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: base.appendingPathComponent("kraken2").path
        )
        XCTAssertEqual(siblings.sorted(), ["viral"])
    }

    /// An incomplete staging copy is not a database: the row is marked missing rather
    /// than pointed at a broken payload.
    func testLoadMarksRowMissingWhenNoUsableCopySurvives() async throws {
        let base = tempDir!
        let installedPath = try seedInstalledViralDatabase(in: base, marker: "old")
        try FileManager.default.removeItem(at: installedPath)

        // Staging exists but is incomplete (hash.k2d only).
        let staging = base.appendingPathComponent("kraken2/.viral.staging-20240904", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "new".write(to: staging.appendingPathComponent("hash.k2d"), atomically: true, encoding: .utf8)

        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await registry.loadIfNeeded()

        let stored = try await registry.database(named: "Viral")
        let db = try XCTUnwrap(stored)
        XCTAssertEqual(db.status, .missing)
        XCTAssertNil(db.path)
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: base.appendingPathComponent("kraken2").path
        )
        XCTAssertTrue(siblings.isEmpty, "Unusable orphans should be swept, got \(siblings)")
    }

    /// A database missing for ordinary reasons (deleted, unmounted volume) has no
    /// transaction residue and must not be touched by recovery.
    func testLoadLeavesOrdinaryMissingDatabaseAlone() async throws {
        let base = tempDir!
        let installedPath = try seedInstalledViralDatabase(in: base, marker: "old")
        try FileManager.default.removeItem(at: installedPath)

        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await registry.loadIfNeeded()

        let stored = try await registry.database(named: "Viral")
        let db = try XCTUnwrap(stored)
        // Recovery did not run, so the row still claims its path; `verify` owns this case.
        XCTAssertEqual(db.path?.standardizedFileURL, installedPath.standardizedFileURL)
        XCTAssertEqual(db.status, .ready)
    }

    /// An unmounted external volume looks like a missing directory. Recovery must not
    /// claim it, because `resolveAllBookmarks`/`verify` model it as `.volumeNotMounted`.
    func testLoadDoesNotClaimUnmountedExternalDatabase() async throws {
        let base = tempDir!
        let installedPath = try seedInstalledViralDatabase(in: base, marker: "old", isExternal: true)
        try FileManager.default.removeItem(at: installedPath)

        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await registry.loadIfNeeded()

        let stored = try await registry.database(named: "Viral")
        let db = try XCTUnwrap(stored)
        XCTAssertEqual(db.path?.standardizedFileURL, installedPath.standardizedFileURL)
        XCTAssertNotEqual(db.status, .missing)
    }

    // MARK: - External volumes

    func testUpdateRefreshesBookmarkForExternalDatabase() async throws {
        let base = tempDir!
        let installedPath = try seedInstalledViralDatabase(in: base, marker: "old", isExternal: true)

        let refreshedBookmark = Data("refreshed-bookmark".utf8)
        let registry = MetagenomicsDatabaseRegistry(
            baseDirectory: base,
            externalVolumeDetector: { _ in true },
            bookmarkCreator: { _ in refreshedBookmark },
            securityScopedAccessStarter: { _ in true },
            securityScopedAccessStopper: { _ in }
        )
        try await registry.loadIfNeeded()
        await registry.setArchiveInstallerForTesting { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Self.writeKraken2Payload(at: destination, marker: "new")
            return nil
        }

        try await registry.updateDatabase(catalogID: "kraken2-viral") { _, _ in }

        let stored = try await registry.database(named: "Viral")
        let db = try XCTUnwrap(stored)
        XCTAssertTrue(db.isExternal)
        XCTAssertEqual(db.bookmarkData, refreshedBookmark, "Bookmark must be re-created for the swapped directory")
        XCTAssertEqual(
            try String(contentsOf: XCTUnwrap(db.path).appendingPathComponent("hash.k2d"), encoding: .utf8),
            "new"
        )
        _ = installedPath
    }

    func testUpdateThrowsWhenExternalVolumeIsUnavailable() async throws {
        let base = tempDir!
        _ = try seedInstalledViralDatabase(in: base, marker: "old", isExternal: true)

        let registry = MetagenomicsDatabaseRegistry(
            baseDirectory: base,
            externalVolumeDetector: { _ in true },
            securityScopedAccessStarter: { _ in false },
            securityScopedAccessStopper: { _ in }
        )
        try await registry.loadIfNeeded()
        await registry.setArchiveInstallerForTesting { _, _, _ in
            XCTFail("Update must not download when the volume is unavailable")
            return nil
        }

        await XCTAssertThrowsErrorAsync(
            try await registry.updateDatabase(catalogID: "kraken2-viral") { _, _ in }
        ) { error in
            guard case MetagenomicsDatabaseRegistryError.updateNotSupported(let name, _) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(name, "Viral")
        }
    }

    // MARK: - Managed sidecar registry

    func testManagedDatabaseReinstallRemovesSupersededCopies() async throws {
        let userRoot = tempDir.appendingPathComponent("user-databases", isDirectory: true)
        let installDirectory = userRoot.appendingPathComponent("human-scrubber", isDirectory: true)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let staleURL = installDirectory.appendingPathComponent("human_filter.db.OLD")
        try Data("stale".utf8).write(to: staleURL)

        let downloadDirectory = tempDir.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let payload = Data("fresh-human-scrubber-payload\n".utf8)
        let expectedMD5 = Self.md5Hex(payload)
        let downloader: ManagedDatabaseDownloader = { url, progress in
            let outputURL = downloadDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            let data = url.lastPathComponent.hasSuffix(".md5")
                ? Data("\(expectedMD5)  human_filter.db\n".utf8)
                : payload
            try data.write(to: outputURL)
            progress(1.0, Int64(data.count), Int64(data.count))
            return ManagedDatabaseDownloadResult(fileURL: outputURL, wallTime: 0.1)
        }

        let registry = DatabaseRegistry(
            bundledDatabasesRoot: nil,
            userDatabasesRoot: userRoot,
            managedDatabaseDownloader: downloader
        )
        defer {
            UserDefaults.standard.removeObject(forKey: "database.human-scrubber.overrideFilename")
        }

        let installed = try await registry.installManagedDatabase("human-scrubber", reinstall: true)

        XCTAssertEqual(try Data(contentsOf: installed), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))

        let remainingPayloads = try FileManager.default
            .contentsOfDirectory(atPath: installDirectory.path)
            .filter { !$0.hasPrefix(".") && $0 != ProvenanceRecorder.provenanceFilename }
        XCTAssertEqual(remainingPayloads, [installed.lastPathComponent])
    }

    func testManagedDatabaseInPlaceUpdateRemovesSupersededCopies() async throws {
        // A non-reinstall install into a directory that already holds an older
        // payload must still leave exactly one payload behind.
        let userRoot = tempDir.appendingPathComponent("user-databases", isDirectory: true)
        let installDirectory = userRoot.appendingPathComponent("human-scrubber", isDirectory: true)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let staleURL = installDirectory.appendingPathComponent("human_filter.db.20240101v1")
        try Data("stale".utf8).write(to: staleURL)

        let downloadDirectory = tempDir.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let payload = Data("fresh-human-scrubber-payload\n".utf8)
        let expectedMD5 = Self.md5Hex(payload)
        let downloader: ManagedDatabaseDownloader = { url, progress in
            let outputURL = downloadDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            let data = url.lastPathComponent.hasSuffix(".md5")
                ? Data("\(expectedMD5)  human_filter.db\n".utf8)
                : payload
            try data.write(to: outputURL)
            progress(1.0, Int64(data.count), Int64(data.count))
            return ManagedDatabaseDownloadResult(fileURL: outputURL, wallTime: 0.1)
        }

        let registry = DatabaseRegistry(
            bundledDatabasesRoot: nil,
            userDatabasesRoot: userRoot,
            managedDatabaseDownloader: downloader
        )
        defer {
            UserDefaults.standard.removeObject(forKey: "database.human-scrubber.overrideFilename")
        }
        UserDefaults.standard.removeObject(forKey: "database.human-scrubber.overrideFilename")

        let installed = try await registry.installManagedDatabase("human-scrubber", reinstall: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        let remainingPayloads = try FileManager.default
            .contentsOfDirectory(atPath: installDirectory.path)
            .filter { !$0.hasPrefix(".") && $0 != ProvenanceRecorder.provenanceFilename }
        XCTAssertEqual(remainingPayloads, [installed.lastPathComponent])
    }

    // MARK: - Helpers

    /// Seeds an installed Kraken2 Viral catalog entry by writing the registry manifest
    /// directly, so a registry constructed later loads it as already installed.
    ///
    /// Recovery tests need the persisted row to exist *before* `loadIfNeeded()` runs,
    /// which `registerExisting` cannot provide (it requires a live registry and the
    /// directory to be present).
    @discardableResult
    private func seedInstalledViralDatabase(
        in base: URL,
        marker: String,
        isExternal: Bool = false
    ) throws -> URL {
        let directory = base.appendingPathComponent("kraken2/viral", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.writeKraken2Payload(at: directory, marker: marker)

        guard var entry = MetagenomicsDatabaseInfo.catalogEntry(catalogID: "kraken2-viral") else {
            throw XCTSkip("Manifest pins no kraken2-viral entry")
        }
        entry.path = directory
        entry.status = .ready
        entry.version = "20230605-installed"
        entry.isExternal = isExternal
        entry.bookmarkData = isExternal ? Data("stale-bookmark".utf8) : nil
        entry.installedAt = Date()
        entry.lastUpdated = Date()

        try writeRegistryManifest([entry], in: base)
        return directory
    }

    private func writeRegistryManifest(
        _ entries: [MetagenomicsDatabaseInfo],
        in base: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifest = DatabaseManifest(version: 1, databases: entries)
        try encoder.encode(manifest).write(
            to: base.appendingPathComponent("metagenomics-db-registry.json"),
            options: .atomic
        )
    }

    /// Seeds an installed EsViritu catalog entry by writing the registry manifest
    /// directly.
    ///
    /// `registerExisting` validates every candidate against the Kraken2 file list, so
    /// it cannot register an EsViritu directory. A real EsViritu install reaches this
    /// state through `downloadDatabase`, which persists exactly this row.
    private func seedInstalledEsVirituDatabase(in base: URL, marker: String) throws -> URL {
        let directory = base.appendingPathComponent("esviritu/esviritu-viral-db", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try marker.write(
            to: directory.appendingPathComponent("db.fna"),
            atomically: true,
            encoding: .utf8
        )

        guard var entry = MetagenomicsDatabaseInfo.catalogEntry(catalogID: "esviritu-viral-v3") else {
            throw XCTSkip("Manifest pins no esviritu-viral-v3 entry")
        }
        entry.path = directory
        entry.status = .ready
        entry.version = "v3.0.0-installed"
        entry.installedAt = Date()
        entry.lastUpdated = Date()

        try writeRegistryManifest([entry], in: base)
        return directory
    }

    private func writeKraken2Payload(at directory: URL, marker: String) throws {
        try Self.writeKraken2Payload(at: directory, marker: marker)
    }

    private static func writeKraken2Payload(at directory: URL, marker: String) throws {
        for filename in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try marker.write(
                to: directory.appendingPathComponent(filename),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
