// MetagenomicsDatabaseTests.swift - Tests for metagenomics database registry
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishCore

// MARK: - MetagenomicsDatabaseInfoTests

final class MetagenomicsDatabaseInfoTests: XCTestCase {

    // MARK: - Creation

    func testDatabaseInfoCreation() {
        let info = MetagenomicsDatabaseInfo(
            name: "Standard-8",
            tool: "kraken2",
            version: "2024-09-04",
            sizeBytes: 8 * 1_073_741_824,
            sizeOnDisk: 8 * 1_073_741_824,
            downloadURL: "https://example.com/k2_standard_08gb.tar.gz",
            description: "Same as Standard, capped at 8 GB",
            collection: .standard8,
            path: nil,
            isExternal: false,
            bookmarkData: nil,
            lastUpdated: nil,
            status: .missing,
            recommendedRAM: 8 * 1_073_741_824
        )

        XCTAssertEqual(info.id, "Standard-8")
        XCTAssertEqual(info.name, "Standard-8")
        XCTAssertEqual(info.tool, "kraken2")
        XCTAssertEqual(info.version, "2024-09-04")
        XCTAssertEqual(info.sizeBytes, 8 * 1_073_741_824)
        XCTAssertEqual(info.description, "Same as Standard, capped at 8 GB")
        XCTAssertEqual(info.collection, .standard8)
        XCTAssertFalse(info.isDownloaded)
        XCTAssertFalse(info.isExternal)
        XCTAssertNil(info.bookmarkData)
        XCTAssertNil(info.lastUpdated)
        XCTAssertEqual(info.status, .missing)
        XCTAssertEqual(info.recommendedRAM, 8 * 1_073_741_824)
    }

    func testDatabaseInfoIsDownloadedWhenPathSet() {
        var info = makeTestDatabaseInfo(name: "Test")
        XCTAssertFalse(info.isDownloaded)

        info.path = URL(fileURLWithPath: "/tmp/test-db")
        XCTAssertTrue(info.isDownloaded)
    }

    func testDatabaseInfoIdentifiableByName() {
        let info = makeTestDatabaseInfo(name: "Viral")
        XCTAssertEqual(info.id, "Viral")
    }

    // MARK: - Codable

    func testDatabaseInfoCodable() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000) // fixed date for determinism
        let original = MetagenomicsDatabaseInfo(
            name: "PlusPF",
            tool: "kraken2",
            version: "2024-09-04",
            sizeBytes: 72 * 1_073_741_824,
            sizeOnDisk: 72 * 1_073_741_824,
            downloadURL: "https://genome-idx.s3.amazonaws.com/kraken/k2_pluspf_20240904.tar.gz",
            description: "Standard + protozoa + fungi",
            collection: .plusPF,
            path: URL(fileURLWithPath: "/Users/test/.lungfish/databases/kraken2/pluspf"),
            isExternal: false,
            bookmarkData: nil,
            lastUpdated: date,
            status: .ready,
            recommendedRAM: 72 * 1_073_741_824
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MetagenomicsDatabaseInfo.self, from: data)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.tool, original.tool)
        XCTAssertEqual(decoded.version, original.version)
        XCTAssertEqual(decoded.sizeBytes, original.sizeBytes)
        XCTAssertEqual(decoded.sizeOnDisk, original.sizeOnDisk)
        XCTAssertEqual(decoded.downloadURL, original.downloadURL)
        XCTAssertEqual(decoded.description, original.description)
        XCTAssertEqual(decoded.collection, original.collection)
        XCTAssertEqual(decoded.isExternal, original.isExternal)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.recommendedRAM, original.recommendedRAM)
        // Path is file URL; compare paths.
        XCTAssertEqual(decoded.path?.path, original.path?.path)
    }

    func testDatabaseInfoCodableWithBookmarkData() throws {
        let bookmarkData = Data([0x01, 0x02, 0x03, 0x04, 0xAA, 0xBB])
        let info = MetagenomicsDatabaseInfo(
            name: "External-DB",
            tool: "kraken2",
            version: "2024-09-04",
            sizeBytes: 16 * 1_073_741_824,
            description: "Test DB with bookmark",
            path: URL(fileURLWithPath: "/Volumes/BioData/kraken2/standard16"),
            isExternal: true,
            bookmarkData: bookmarkData,
            status: .ready,
            recommendedRAM: 16 * 1_073_741_824
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(info)
        let decoded = try JSONDecoder().decode(MetagenomicsDatabaseInfo.self, from: data)

        XCTAssertEqual(decoded.bookmarkData, bookmarkData)
        XCTAssertTrue(decoded.isExternal)
    }

    func testDatabaseInfoCodableWithNilOptionals() throws {
        let info = MetagenomicsDatabaseInfo(
            name: "Minimal",
            tool: "kraken2",
            sizeBytes: 1024,
            description: "Minimal entry",
            status: .missing,
            recommendedRAM: 1024
        )

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(MetagenomicsDatabaseInfo.self, from: data)

        XCTAssertNil(decoded.version)
        XCTAssertNil(decoded.sizeOnDisk)
        XCTAssertNil(decoded.downloadURL)
        XCTAssertNil(decoded.path)
        XCTAssertNil(decoded.bookmarkData)
        XCTAssertNil(decoded.lastUpdated)
        XCTAssertNil(decoded.collection)
    }

    // MARK: - Built-in Catalog

    func testBuiltInCatalogComplete() {
        let catalog = MetagenomicsDatabaseInfo.builtInCatalog

        // Must have at least as many entries as DatabaseCollection cases (Kraken2)
        // plus additional tool databases (EsViritu, etc.)
        XCTAssertGreaterThanOrEqual(catalog.count, DatabaseCollection.allCases.count)

        // Every Kraken2 collection should be represented.
        let collections = Set(catalog.compactMap(\.collection))
        for collection in DatabaseCollection.allCases {
            XCTAssertTrue(
                collections.contains(collection),
                "Missing catalog entry for \(collection.displayName)"
            )
        }

        // EsViritu database should be present
        let esvirituDBs = catalog.filter { $0.tool == MetagenomicsTool.esviritu.rawValue }
        XCTAssertFalse(esvirituDBs.isEmpty, "Catalog should include EsViritu databases")

        // Every entry must have required fields populated.
        for entry in catalog {
            XCTAssertFalse(entry.name.isEmpty, "Catalog entry has empty name")
            XCTAssertFalse(entry.tool.isEmpty, "Catalog entry '\(entry.name)' has empty tool")
            XCTAssertNotNil(entry.version, "Catalog entry '\(entry.name)' has nil version")
            XCTAssertGreaterThan(entry.sizeBytes, 0, "Catalog entry '\(entry.name)' has zero size")
            XCTAssertNotNil(entry.downloadURL, "Catalog entry '\(entry.name)' has nil download URL")
            XCTAssertFalse(entry.description.isEmpty, "Catalog entry '\(entry.name)' has empty description")
            XCTAssertGreaterThan(entry.recommendedRAM, 0, "Catalog entry '\(entry.name)' has zero RAM")
            XCTAssertEqual(entry.status, .missing, "Catalog entry '\(entry.name)' should start as .missing")
            XCTAssertFalse(entry.isDownloaded, "Catalog entry '\(entry.name)' should not be downloaded")
        }
    }

    func testBuiltInCatalogDownloadURLsAreValid() {
        for entry in MetagenomicsDatabaseInfo.builtInCatalog {
            guard let urlString = entry.downloadURL else {
                XCTFail("Catalog entry '\(entry.name)' has nil download URL")
                continue
            }
            XCTAssertNotNil(
                URL(string: urlString),
                "Catalog entry '\(entry.name)' has invalid download URL: \(urlString)"
            )
            XCTAssertTrue(
                urlString.hasSuffix(".tar.gz"),
                "Catalog entry '\(entry.name)' download URL does not end with .tar.gz"
            )
            // Kraken2 databases come from AWS, EsViritu from Zenodo, NCBI Taxonomy from NCBI FTP
            let isKnownHost = urlString.contains("genome-idx.s3.amazonaws.com")
                || urlString.contains("zenodo.org")
                || urlString.contains("ftp.ncbi.nlm.nih.gov")
            XCTAssertTrue(
                isKnownHost,
                "Catalog entry '\(entry.name)' download URL is not from a known host: \(urlString)"
            )
        }
    }

    func testViralDatabaseIsSmallestKraken2() {
        // Among Kraken2 databases, "Viral" should be the smallest
        let kraken2Catalog = MetagenomicsDatabaseInfo.builtInCatalog.filter { $0.tool == "kraken2" }
        let viral = kraken2Catalog.first { $0.name == "Viral" }
        XCTAssertNotNil(viral)

        guard let viralDB = viral else { return }

        for entry in kraken2Catalog where entry.name != "Viral" {
            XCTAssertLessThan(
                viralDB.sizeBytes, entry.sizeBytes,
                "Viral (\(viralDB.sizeBytes)) should be smaller than \(entry.name) (\(entry.sizeBytes))"
            )
        }
    }

    func testCatalogEntryLookup() {
        let entry = MetagenomicsDatabaseInfo.catalogEntry(for: .standard8)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.name, "Standard-8")
        XCTAssertEqual(entry?.collection, .standard8)
    }

    // MARK: - DatabaseCollection

    func testDatabaseCollectionDisplayNames() {
        XCTAssertEqual(DatabaseCollection.standard.displayName, "Standard")
        XCTAssertEqual(DatabaseCollection.standard8.displayName, "Standard-8")
        XCTAssertEqual(DatabaseCollection.standard16.displayName, "Standard-16")
        XCTAssertEqual(DatabaseCollection.plusPF.displayName, "PlusPF")
        XCTAssertEqual(DatabaseCollection.plusPF8.displayName, "PlusPF-8")
        XCTAssertEqual(DatabaseCollection.plusPF16.displayName, "PlusPF-16")
        XCTAssertEqual(DatabaseCollection.viral.displayName, "Viral")
        XCTAssertEqual(DatabaseCollection.minusB.displayName, "MinusB")
        XCTAssertEqual(DatabaseCollection.euPathDB46.displayName, "EuPathDB46")
    }

    func testDatabaseCollectionAllCasesCount() {
        XCTAssertEqual(DatabaseCollection.allCases.count, 9)
    }

    func testDatabaseCollectionSizesArePositive() {
        for collection in DatabaseCollection.allCases {
            XCTAssertGreaterThan(
                collection.approximateSizeBytes, 0,
                "\(collection.displayName) has zero size"
            )
            XCTAssertGreaterThan(
                collection.approximateRAMBytes, 0,
                "\(collection.displayName) has zero RAM"
            )
        }
    }

    func testDatabaseCollectionContentsDescriptions() {
        for collection in DatabaseCollection.allCases {
            XCTAssertFalse(
                collection.contentsDescription.isEmpty,
                "\(collection.displayName) has empty description"
            )
        }
    }

    // MARK: - DatabaseStatus

    func testDatabaseStatusCodable() throws {
        let statuses: [DatabaseStatus] = [.ready, .downloading, .verifying, .corrupt, .volumeNotMounted, .missing]
        for status in statuses {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(DatabaseStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    // MARK: - DatabaseLocation

    func testDatabaseLocationLocalCodable() throws {
        let location = DatabaseLocation.local(path: "/Users/test/.lungfish/databases/kraken2/viral")
        let data = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(DatabaseLocation.self, from: data)
        XCTAssertEqual(decoded, location)
    }

    func testDatabaseLocationBookmarkCodable() throws {
        let bookmark = Data(repeating: 0xAA, count: 32)
        let location = DatabaseLocation.bookmark(data: bookmark, lastKnownPath: "/Volumes/BioData/kraken2")
        let data = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(DatabaseLocation.self, from: data)
        XCTAssertEqual(decoded, location)
    }

    // MARK: - Helpers

    private func makeTestDatabaseInfo(name: String) -> MetagenomicsDatabaseInfo {
        MetagenomicsDatabaseInfo(
            name: name,
            tool: "kraken2",
            sizeBytes: 1024,
            description: "Test database",
            status: .missing,
            recommendedRAM: 1024
        )
    }
}

// MARK: - MetagenomicsDatabaseRegistryTests

final class MetagenomicsDatabaseRegistryTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-db-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Initialization

    func testRegistryCreatesDirectoryOnLoad() async throws {
        let base = tempDir.appendingPathComponent("new-subdir")
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)

        let dbs = try await registry.availableDatabases()
        XCTAssertFalse(dbs.isEmpty, "Should have loaded built-in catalog")
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
    }

    func testRegistryInitializesWithBuiltInCatalog() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)

        let dbs = try await registry.availableDatabases()
        // Catalog includes Kraken2 collections + EsViritu + any other tool databases
        XCTAssertGreaterThanOrEqual(dbs.count, DatabaseCollection.allCases.count)

        // All should be in .missing status.
        for db in dbs {
            XCTAssertEqual(db.status, .missing, "\(db.name) should start as .missing")
            XCTAssertFalse(db.isDownloaded, "\(db.name) should not be downloaded")
        }
    }

    func testSharedRegistryFollowsActiveRootChangesAfterInitialLoad() async throws {
        let home = tempDir.appendingPathComponent("shared-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let store = ManagedStorageConfigStore(homeDirectory: home)
        let originalShared = MetagenomicsDatabaseRegistry.shared
        MetagenomicsDatabaseRegistry.shared = MetagenomicsDatabaseRegistry(storageConfigStore: store)
        defer { MetagenomicsDatabaseRegistry.shared = originalShared }

        let legacyDatabase = createMockKraken2Database(name: "legacy-only")
        try await MetagenomicsDatabaseRegistry.shared.registerExisting(at: legacyDatabase, name: "LegacyOnly")
        let legacyEntry = try await MetagenomicsDatabaseRegistry.shared.database(named: "LegacyOnly")
        XCTAssertNotNil(legacyEntry)

        let updatedRoot = home.appendingPathComponent("managed-storage", isDirectory: true)
        try store.setActiveRoot(updatedRoot)

        let reloadedDatabases = try await MetagenomicsDatabaseRegistry.shared.availableDatabases()
        let storagePath = await MetagenomicsDatabaseRegistry.shared.storagePath
        XCTAssertNil(reloadedDatabases.first { $0.name == "LegacyOnly" })
        XCTAssertEqual(storagePath, updatedRoot.appendingPathComponent("databases", isDirectory: true).path)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: updatedRoot
                    .appendingPathComponent("databases/metagenomics-db-registry.json")
                    .path
            )
        )
    }

    func testSetStorageLocationPersistsSharedManagedStorageRoot() async throws {
        let home = tempDir.appendingPathComponent("storage-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let legacyKey = "DatabaseStorageLocation"
        let originalLegacyValue = UserDefaults.standard.object(forKey: legacyKey)
        UserDefaults.standard.set("/tmp/legacy-only", forKey: legacyKey)
        addTeardownBlock {
            if let originalLegacyValue {
                UserDefaults.standard.set(originalLegacyValue, forKey: legacyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: legacyKey)
            }
        }

        let store = ManagedStorageConfigStore(homeDirectory: home)
        let registry = MetagenomicsDatabaseRegistry(storageConfigStore: store)
        let targetRoot = home.appendingPathComponent("custom-root", isDirectory: true)

        try await registry.setStorageLocation(
            targetRoot.appendingPathComponent("databases", isDirectory: true)
        )

        let storagePath = await registry.storagePath
        XCTAssertEqual(
            store.currentLocation().rootURL.standardizedFileURL.path,
            targetRoot.standardizedFileURL.path
        )
        XCTAssertNil(UserDefaults.standard.object(forKey: legacyKey))
        XCTAssertEqual(storagePath, targetRoot.appendingPathComponent("databases", isDirectory: true).path)
    }

    // MARK: - Manifest Persistence

    func testManifestSaveLoad() async throws {
        // Create a registry, register a database, then create a new registry
        // reading the same manifest.
        let registry1 = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)

        // Create a mock database directory.
        let dbDir = createMockKraken2Database(name: "test-db")

        try await registry1.registerExisting(at: dbDir, name: "TestDB")

        // Create a second registry reading the same manifest.
        let registry2 = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let dbs = try await registry2.availableDatabases()

        let testDB = dbs.first { $0.name == "TestDB" }
        XCTAssertNotNil(testDB, "TestDB should be in the persisted manifest")
        XCTAssertEqual(testDB?.status, .ready)
        XCTAssertEqual(testDB?.path?.path, dbDir.path)
    }

    func testPersistenceRoundTrip() async throws {
        let registry1 = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)

        // Register two databases.
        let dbDir1 = createMockKraken2Database(name: "db-alpha")
        let dbDir2 = createMockKraken2Database(name: "db-beta")
        try await registry1.registerExisting(at: dbDir1, name: "Alpha")
        try await registry1.registerExisting(at: dbDir2, name: "Beta")

        // Read back with a new registry instance.
        let registry2 = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let dbs = try await registry2.availableDatabases()

        let alpha = dbs.first { $0.name == "Alpha" }
        let beta = dbs.first { $0.name == "Beta" }

        XCTAssertNotNil(alpha)
        XCTAssertNotNil(beta)
        XCTAssertEqual(alpha?.path?.path, dbDir1.path)
        XCTAssertEqual(beta?.path?.path, dbDir2.path)
        XCTAssertEqual(alpha?.status, .ready)
        XCTAssertEqual(beta?.status, .ready)
    }

    func testManifestFileIsValidJSON() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        _ = try await registry.availableDatabases()

        let manifestURL = tempDir.appendingPathComponent("metagenomics-db-registry.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))

        let data = try Data(contentsOf: manifestURL)
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [String: Any], "Manifest should be a JSON object")

        // swiftlint:disable:next force_cast
        let dict = json as! [String: Any]
        XCTAssertEqual(dict["version"] as? Int, 1)
        XCTAssertNotNil(dict["databases"] as? [[String: Any]])
    }

    // MARK: - Register Existing

    func testRegisterLocalDatabase() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let dbDir = createMockKraken2Database(name: "my-kraken2-db")

        let registered = try await registry.registerExisting(at: dbDir, name: "MyDB")

        XCTAssertEqual(registered.name, "MyDB")
        XCTAssertEqual(registered.status, .ready)
        XCTAssertEqual(registered.path?.path, dbDir.path)
        XCTAssertTrue(registered.isDownloaded)
        XCTAssertNotNil(registered.lastUpdated)
    }

    func testRegisterDuplicateThrows() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let dbDir = createMockKraken2Database(name: "dup-test")

        try await registry.registerExisting(at: dbDir, name: "DupDB")

        do {
            try await registry.registerExisting(at: dbDir, name: "DupDB")
            XCTFail("Should have thrown duplicateDatabase error")
        } catch let error as MetagenomicsDatabaseRegistryError {
            if case .duplicateDatabase(let name) = error {
                XCTAssertEqual(name, "DupDB")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testRegisterInvalidDirectoryThrows() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)

        // Create directory without required files.
        let emptyDir = tempDir.appendingPathComponent("empty-db")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        do {
            try await registry.registerExisting(at: emptyDir, name: "EmptyDB")
            XCTFail("Should have thrown invalidDatabaseDirectory error")
        } catch let error as MetagenomicsDatabaseRegistryError {
            if case .invalidDatabaseDirectory(_, let missing) = error {
                XCTAssertTrue(missing.contains("hash.k2d"))
                XCTAssertTrue(missing.contains("opts.k2d"))
                XCTAssertTrue(missing.contains("taxo.k2d"))
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testRegisterExistingUpdatesCatalogEntry() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)

        // Load catalog first.
        _ = try await registry.availableDatabases()

        // Register a directory under the "Viral" catalog entry name.
        let dbDir = createMockKraken2Database(name: "viral")
        let registered = try await registry.registerExisting(at: dbDir, name: "Viral")

        // Should update the existing catalog entry.
        XCTAssertEqual(registered.name, "Viral")
        XCTAssertEqual(registered.status, .ready)
        XCTAssertEqual(registered.collection, .viral)
        XCTAssertTrue(registered.isDownloaded)
    }

    // MARK: - Remove

    func testRemoveDatabase() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let dbDir = createMockKraken2Database(name: "removable")

        try await registry.registerExisting(at: dbDir, name: "RemovableDB")

        // Remove it.
        try await registry.removeDatabase(name: "RemovableDB")

        // Should no longer be in the registry.
        let dbs = try await registry.availableDatabases()
        let removed = dbs.first { $0.name == "RemovableDB" }
        XCTAssertNil(removed)

        // But the files should still exist on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbDir.path))
    }

    func testRemoveCatalogDatabaseResetsToUndownloaded() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)

        // Register the Viral catalog entry.
        let dbDir = createMockKraken2Database(name: "viral")
        try await registry.registerExisting(at: dbDir, name: "Viral")

        // Remove it.
        try await registry.removeDatabase(name: "Viral")

        // Should still exist as a catalog entry, but reset to .missing.
        let dbs = try await registry.availableDatabases()
        let viral = dbs.first { $0.name == "Viral" }
        XCTAssertNotNil(viral)
        XCTAssertEqual(viral?.status, .missing)
        XCTAssertFalse(viral?.isDownloaded ?? true)
    }

    func testDatabaseNotFoundError() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        _ = try await registry.availableDatabases()

        do {
            try await registry.removeDatabase(name: "NonExistentDB")
            XCTFail("Should have thrown databaseNotFound error")
        } catch let error as MetagenomicsDatabaseRegistryError {
            if case .databaseNotFound(let name) = error {
                XCTAssertEqual(name, "NonExistentDB")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    // MARK: - Verification

    func testVerifyValidDatabase() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let dbDir = createMockKraken2Database(name: "valid-db")
        try await registry.registerExisting(at: dbDir, name: "ValidDB")

        let status = try await registry.verify(name: "ValidDB")
        XCTAssertEqual(status, .ready)
    }

    func testVerifyMissingFilesReturnsCorrupt() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let dbDir = createMockKraken2Database(name: "corrupt-db")
        try await registry.registerExisting(at: dbDir, name: "CorruptDB")

        // Delete one of the required files.
        try FileManager.default.removeItem(
            at: dbDir.appendingPathComponent("hash.k2d")
        )

        let status = try await registry.verify(name: "CorruptDB")
        XCTAssertEqual(status, .corrupt)
    }

    func testVerifyMissingDirectoryReturnsMissing() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let dbDir = createMockKraken2Database(name: "vanishing-db")
        try await registry.registerExisting(at: dbDir, name: "VanishingDB")

        // Delete the entire directory.
        try FileManager.default.removeItem(at: dbDir)

        let status = try await registry.verify(name: "VanishingDB")
        XCTAssertEqual(status, .missing)
    }

    func testVerifyUndownloadedReturnsMissing() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        _ = try await registry.availableDatabases()

        // Viral is a catalog entry that hasn't been downloaded.
        let status = try await registry.verify(name: "Viral")
        XCTAssertEqual(status, .missing)
    }

    func testVerifyNonExistentDatabaseThrows() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        _ = try await registry.availableDatabases()

        do {
            _ = try await registry.verify(name: "DoesNotExist")
            XCTFail("Should have thrown databaseNotFound")
        } catch let error as MetagenomicsDatabaseRegistryError {
            if case .databaseNotFound = error {
                // Expected.
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    // MARK: - Relocation

    func testRelocateDatabase() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let dbDir = createMockKraken2Database(name: "relocatable")
        try await registry.registerExisting(at: dbDir, name: "RelocatableDB")

        // Create destination with the required files.
        let newDir = createMockKraken2Database(name: "new-location")

        try await registry.relocateDatabase(name: "RelocatableDB", to: newDir)

        let db = try await registry.database(named: "RelocatableDB")
        XCTAssertEqual(db?.path?.path, newDir.path)
        XCTAssertEqual(db?.status, .ready)
    }

    func testRelocateToInvalidDirectoryThrows() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let dbDir = createMockKraken2Database(name: "source-db")
        try await registry.registerExisting(at: dbDir, name: "SourceDB")

        let emptyDir = tempDir.appendingPathComponent("empty-dest")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        do {
            try await registry.relocateDatabase(name: "SourceDB", to: emptyDir)
            XCTFail("Should have thrown invalidDatabaseDirectory")
        } catch let error as MetagenomicsDatabaseRegistryError {
            if case .invalidDatabaseDirectory = error {
                // Expected.
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    // MARK: - Filtering

    func testDatabasesFilteredByTool() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let dbs = try await registry.databases(for: .kraken2)

        // All built-in catalog entries are kraken2.
        XCTAssertEqual(dbs.count, DatabaseCollection.allCases.count)
        for db in dbs {
            XCTAssertEqual(db.tool, "kraken2")
        }
    }

    func testDatabasesFilteredByNonExistentToolReturnsEmpty() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)

        // metaphlan has no built-in catalog entries.
        let dbs = try await registry.databases(for: .metaphlan)
        XCTAssertTrue(dbs.isEmpty)
    }

    // MARK: - RAM Recommendations

    func testRecommendedDatabaseFor8GBRAM() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let gb8: UInt64 = 8 * 1_073_741_824
        let db = try await registry.recommendedDatabase(ramBytes: gb8)
        XCTAssertEqual(db.name, "Standard-8")
    }

    func testRecommendedDatabaseFor16GBRAM() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let gb16: UInt64 = 16 * 1_073_741_824
        let db = try await registry.recommendedDatabase(ramBytes: gb16)
        XCTAssertEqual(db.name, "Standard-16")
    }

    func testRecommendedDatabaseFor32GBRAM() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let gb32: UInt64 = 32 * 1_073_741_824
        let db = try await registry.recommendedDatabase(ramBytes: gb32)
        XCTAssertEqual(db.name, "Standard")
    }

    func testRecommendedDatabaseFor72GBRAM() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let gb72: UInt64 = 72 * 1_073_741_824
        let db = try await registry.recommendedDatabase(ramBytes: gb72)
        XCTAssertEqual(db.name, "PlusPF")
    }

    func testRecommendedDatabaseFor128GBRAM() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let gb128: UInt64 = 128 * 1_073_741_824
        let db = try await registry.recommendedDatabase(ramBytes: gb128)
        XCTAssertEqual(db.name, "PlusPF")
    }

    func testRecommendedDatabaseForVeryLowRAM() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let gb4: UInt64 = 4 * 1_073_741_824
        let db = try await registry.recommendedDatabase(ramBytes: gb4)
        XCTAssertEqual(db.name, "Standard-8")
    }

    func testRecommendedCollectionStatic() {
        let gb8: UInt64 = 8 * 1_073_741_824
        let gb16: UInt64 = 16 * 1_073_741_824
        let gb32: UInt64 = 32 * 1_073_741_824
        let gb72: UInt64 = 72 * 1_073_741_824
        let gb96: UInt64 = 96 * 1_073_741_824

        XCTAssertEqual(MetagenomicsDatabaseRegistry.recommendedCollection(forRAMBytes: gb8), .standard8)
        XCTAssertEqual(MetagenomicsDatabaseRegistry.recommendedCollection(forRAMBytes: gb16), .standard16)
        XCTAssertEqual(MetagenomicsDatabaseRegistry.recommendedCollection(forRAMBytes: gb32), .standard)
        XCTAssertEqual(MetagenomicsDatabaseRegistry.recommendedCollection(forRAMBytes: gb72), .plusPF)
        XCTAssertEqual(MetagenomicsDatabaseRegistry.recommendedCollection(forRAMBytes: gb96), .plusPF)
    }

    // MARK: - Bookmark Support

    func testBookmarkCreationForLocalPath() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)

        // Creating a bookmark for a local temp directory should succeed.
        // Note: security-scoped bookmarks may behave differently in sandboxed vs
        // non-sandboxed contexts, but the basic API call should not throw for
        // accessible local paths.
        do {
            let data = try await registry.createBookmark(for: tempDir)
            XCTAssertFalse(data.isEmpty, "Bookmark data should not be empty")
        } catch {
            // On some CI environments, bookmark creation may not work.
            // This is not a failure of our code.
            print("Bookmark creation skipped (expected in some CI environments): \(error)")
        }
    }

    func testResolveBookmarkForDatabaseWithoutBookmark() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        let info = MetagenomicsDatabaseInfo(
            name: "NoBookmark",
            tool: "kraken2",
            sizeBytes: 1024,
            description: "Test",
            path: URL(fileURLWithPath: "/tmp/test"),
            status: .ready,
            recommendedRAM: 1024
        )

        let resolved = await registry.resolveBookmark(for: info)
        // Without bookmark data, should return the path directly.
        XCTAssertEqual(resolved?.path, "/tmp/test")
    }

    func testResolveBookmarkWithInvalidData() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)
        _ = try await registry.availableDatabases()

        let info = MetagenomicsDatabaseInfo(
            name: "BadBookmark",
            tool: "kraken2",
            sizeBytes: 1024,
            description: "Test",
            isExternal: true,
            bookmarkData: Data([0x00, 0x01, 0x02]),
            status: .ready,
            recommendedRAM: 1024
        )

        // Invalid bookmark data should return nil.
        let resolved = await registry.resolveBookmark(for: info)
        XCTAssertNil(resolved)
    }

    // MARK: - Required Files Validation

    func testMissingRequiredFiles() {
        let emptyDir = tempDir.appendingPathComponent("empty-check")
        try! FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let missing = MetagenomicsDatabaseRegistry.missingRequiredFiles(in: emptyDir)
        XCTAssertEqual(Set(missing), Set(["hash.k2d", "opts.k2d", "taxo.k2d"]))
    }

    func testNoMissingFilesWhenAllPresent() {
        let dbDir = createMockKraken2Database(name: "complete")
        let missing = MetagenomicsDatabaseRegistry.missingRequiredFiles(in: dbDir)
        XCTAssertTrue(missing.isEmpty)
    }

    func testPartialMissingFiles() {
        let partialDir = tempDir.appendingPathComponent("partial-db")
        try! FileManager.default.createDirectory(at: partialDir, withIntermediateDirectories: true)
        // Only create hash.k2d.
        FileManager.default.createFile(
            atPath: partialDir.appendingPathComponent("hash.k2d").path,
            contents: Data([0x00])
        )

        let missing = MetagenomicsDatabaseRegistry.missingRequiredFiles(in: partialDir)
        XCTAssertEqual(Set(missing), Set(["opts.k2d", "taxo.k2d"]))
    }

    // MARK: - Error Messages

    func testErrorDescriptions() {
        let errors: [MetagenomicsDatabaseRegistryError] = [
            .databaseNotFound(name: "Test"),
            .duplicateDatabase(name: "Test"),
            .invalidDatabaseDirectory(path: "/tmp", missingFiles: ["hash.k2d"]),
            .bookmarkResolutionFailed(name: "Test", reason: "Volume not mounted"),
            .manifestIOError(operation: "save", underlying: NSError(domain: "test", code: 1)),
            .downloadFailed(name: "Test", reason: "Network error"),
            .downloadCancelled(name: "Test"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) has nil description")
            XCTAssertFalse(
                error.errorDescription!.isEmpty,
                "Error \(error) has empty description"
            )
        }
    }

    // MARK: - MetagenomicsTool

    func testMetagenomicsToolRawValues() {
        XCTAssertEqual(MetagenomicsTool.kraken2.rawValue, "kraken2")
        XCTAssertEqual(MetagenomicsTool.bracken.rawValue, "bracken")
        XCTAssertEqual(MetagenomicsTool.metaphlan.rawValue, "metaphlan")
        XCTAssertEqual(MetagenomicsTool.krakentools.rawValue, "krakentools")
    }

    func testMetagenomicsToolCodable() throws {
        for tool in MetagenomicsTool.allCases {
            let data = try JSONEncoder().encode(tool)
            let decoded = try JSONDecoder().decode(MetagenomicsTool.self, from: data)
            XCTAssertEqual(decoded, tool)
        }
    }

    // MARK: - Directory Size

    func testDirectorySize() {
        let sizeDir = tempDir.appendingPathComponent("size-test")
        try! FileManager.default.createDirectory(at: sizeDir, withIntermediateDirectories: true)

        // Create files with known sizes.
        let file1 = sizeDir.appendingPathComponent("file1.dat")
        let file2 = sizeDir.appendingPathComponent("file2.dat")
        FileManager.default.createFile(atPath: file1.path, contents: Data(repeating: 0xAA, count: 1024))
        FileManager.default.createFile(atPath: file2.path, contents: Data(repeating: 0xBB, count: 2048))

        let size = MetagenomicsDatabaseRegistry.directorySize(at: sizeDir)
        XCTAssertEqual(size, 3072)
    }

    // MARK: - Concurrent Access Safety

    func testConcurrentRegistryAccess() async throws {
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tempDir)

        // Access the registry from multiple concurrent tasks.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    do {
                        let dbs = try await registry.availableDatabases()
                        XCTAssertFalse(dbs.isEmpty, "Task \(i) got empty databases")
                    } catch {
                        XCTFail("Task \(i) threw: \(error)")
                    }
                }
            }
        }
    }

    func testProcessCompletionStateOnlyCompletesOnceUnderConcurrentCalls() {
        let state = MetagenomicsProcessCompletionState()
        let successLock = NSLock()
        var successfulCompletions = 0

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            if state.markCompleted() {
                successLock.lock()
                successfulCompletions += 1
                successLock.unlock()
            }
        }

        XCTAssertEqual(successfulCompletions, 1)
    }

    func testProcessCompletionStateAccumulatesStderrUnderConcurrentAppends() {
        let state = MetagenomicsProcessCompletionState()
        let chunks = (0..<250).map { "stderr-chunk-\($0)\n" }

        DispatchQueue.concurrentPerform(iterations: chunks.count) { index in
            state.appendStderr(Data(chunks[index].utf8))
        }

        let stderr = state.stderrText
        for chunk in chunks {
            XCTAssertTrue(stderr.contains(chunk), "Missing stderr chunk: \(chunk)")
        }
    }

    // MARK: - Helpers

    /// Creates a mock Kraken2 database directory with the three required files.
    @discardableResult
    private func createMockKraken2Database(name: String) -> URL {
        let dbDir = tempDir.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        for filename in MetagenomicsDatabaseRegistry.requiredKraken2Files {
            let fileURL = dbDir.appendingPathComponent(filename)
            // Write a small amount of data so the files are non-empty.
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: Data(repeating: 0x42, count: 256)
            )
        }

        return dbDir
    }
}
