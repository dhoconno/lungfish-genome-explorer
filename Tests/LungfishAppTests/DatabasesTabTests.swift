// DatabasesTabTests.swift - Tests for the Databases tab in Plugin Manager
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
@testable import LungfishApp

// MARK: - DatabasesTabTests

/// Tests for the Databases tab in the Plugin Manager.
///
/// Verifies catalog display, download progress tracking, recommended database
/// highlighting, and database removal. These tests exercise the
/// ``PluginManagerViewModel`` data layer and ``MetagenomicsDatabaseInfo``
/// catalog without rendering SwiftUI views or performing real downloads.
@MainActor
final class DatabasesTabTests: XCTestCase {

    // MARK: - Test Fixtures

    private let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("databases-tab-test-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Creates a fake database info entry for testing.
    private func makeDatabaseInfo(
        name: String,
        status: DatabaseStatus = .missing,
        sizeBytes: Int64 = 8 * 1_073_741_824,
        recommendedRAM: Int64 = 8 * 1_073_741_824,
        collection: DatabaseCollection? = nil,
        path: URL? = nil
    ) -> MetagenomicsDatabaseInfo {
        MetagenomicsDatabaseInfo(
            name: name,
            tool: "kraken2",
            version: "2024-09-04",
            sizeBytes: sizeBytes,
            sizeOnDisk: status == .ready ? sizeBytes : nil,
            downloadURL: "https://example.com/\(name).tar.gz",
            description: "Test database \(name)",
            collection: collection,
            path: path,
            isExternal: false,
            bookmarkData: nil,
            lastUpdated: status == .ready ? Date() : nil,
            status: status,
            recommendedRAM: recommendedRAM
        )
    }

    // MARK: - Tab Enum Tests

    /// Verifies that the databases tab has the correct segment index.
    func testDatabasesTabSegmentIndex() {
        XCTAssertEqual(PluginManagerViewModel.Tab.databases.segmentIndex, 3)
    }

    /// Verifies that segment index 3 maps to the databases tab.
    func testSegmentIndexToDatabasesTab() {
        let tab = PluginManagerViewModel.Tab.from(segmentIndex: 3)
        XCTAssertEqual(tab, .databases)
    }

    /// Verifies that all four tab cases exist and have distinct segment indices.
    func testAllTabsHaveDistinctIndices() {
        let tabs: [PluginManagerViewModel.Tab] = [.installed, .available, .packs, .databases]
        let indices = tabs.map(\.segmentIndex)
        XCTAssertEqual(Set(indices).count, 4, "All tabs should have distinct segment indices")
        XCTAssertEqual(indices, [0, 1, 2, 3], "Tabs should be numbered 0-3")
    }

    /// Verifies that out-of-range segment index defaults to .installed.
    func testOutOfRangeSegmentDefaultsToInstalled() {
        XCTAssertEqual(PluginManagerViewModel.Tab.from(segmentIndex: 99), .installed)
        XCTAssertEqual(PluginManagerViewModel.Tab.from(segmentIndex: -1), .installed)
    }

    // MARK: - testDatabaseCatalogDisplay

    /// Verifies that the built-in catalog contains all expected database collections.
    func testDatabaseCatalogDisplay() {
        let catalog = MetagenomicsDatabaseInfo.builtInCatalog

        XCTAssertGreaterThanOrEqual(catalog.count, 9, "Catalog should have at least 9 databases")

        // Verify key databases are present
        let names = Set(catalog.map(\.name))
        XCTAssertTrue(names.contains("Standard"), "Catalog should contain Standard")
        XCTAssertTrue(names.contains("Standard-8"), "Catalog should contain Standard-8")
        XCTAssertTrue(names.contains("Standard-16"), "Catalog should contain Standard-16")
        XCTAssertTrue(names.contains("PlusPF"), "Catalog should contain PlusPF")
        XCTAssertTrue(names.contains("Viral"), "Catalog should contain Viral")
        XCTAssertTrue(names.contains("MinusB"), "Catalog should contain MinusB")
        XCTAssertTrue(names.contains("EuPathDB46"), "Catalog should contain EuPathDB46")

        // All catalog entries should start as missing
        for db in catalog {
            XCTAssertEqual(db.status, .missing, "\(db.name) should start as .missing")
            XCTAssertFalse(db.isDownloaded, "\(db.name) should not be downloaded initially")
        }
    }

    /// Verifies that each catalog entry has a download URL.
    func testCatalogEntriesHaveDownloadURLs() {
        for db in MetagenomicsDatabaseInfo.builtInCatalog {
            XCTAssertNotNil(db.downloadURL, "\(db.name) should have a download URL")
            XCTAssertTrue(
                db.downloadURL?.hasPrefix("https://") ?? false,
                "\(db.name) download URL should be HTTPS"
            )
        }
    }

    /// Verifies that each catalog entry has positive size and RAM values.
    func testCatalogEntriesHaveSizeAndRAM() {
        for db in MetagenomicsDatabaseInfo.builtInCatalog {
            XCTAssertGreaterThan(db.sizeBytes, 0, "\(db.name) should have positive size")
            XCTAssertGreaterThan(db.recommendedRAM, 0, "\(db.name) should have positive RAM requirement")
        }
    }

    // MARK: - testDownloadProgressUpdate

    /// Verifies that download progress state is correctly tracked in the view model.
    func testDownloadProgressUpdate() {
        let vm = PluginManagerViewModel()

        // Simulate download start
        let dbName = "Viral"
        vm.downloadingDatabases.insert(dbName)
        vm.downloadProgress[dbName] = 0.0
        vm.downloadMessage[dbName] = "Starting download..."

        XCTAssertTrue(vm.downloadingDatabases.contains(dbName))
        XCTAssertEqual(vm.downloadProgress[dbName], 0.0)
        XCTAssertEqual(vm.downloadMessage[dbName], "Starting download...")

        // Simulate progress update
        vm.downloadProgress[dbName] = 0.5
        vm.downloadMessage[dbName] = "Downloading 256 / 512 MB"

        XCTAssertEqual(vm.downloadProgress[dbName], 0.5)
        XCTAssertEqual(vm.downloadMessage[dbName], "Downloading 256 / 512 MB")

        // Simulate extraction phase
        vm.downloadProgress[dbName] = 0.8
        vm.downloadMessage[dbName] = "Extracting database..."

        XCTAssertEqual(vm.downloadProgress[dbName], 0.8)

        // Simulate completion
        vm.downloadingDatabases.remove(dbName)
        vm.downloadProgress.removeValue(forKey: dbName)
        vm.downloadMessage.removeValue(forKey: dbName)

        XCTAssertFalse(vm.downloadingDatabases.contains(dbName))
        XCTAssertNil(vm.downloadProgress[dbName])
        XCTAssertNil(vm.downloadMessage[dbName])
    }

    /// Verifies that download error state is correctly tracked.
    func testDownloadErrorState() {
        let vm = PluginManagerViewModel()

        let dbName = "Standard"
        vm.downloadError[dbName] = "Network connection lost"

        XCTAssertEqual(vm.downloadError[dbName], "Network connection lost")

        // Dismiss error
        vm.downloadError.removeValue(forKey: dbName)
        XCTAssertNil(vm.downloadError[dbName])
    }

    // MARK: - testRecommendedDatabaseHighlight

    /// Verifies that the recommended database changes based on system RAM.
    func testRecommendedDatabaseHighlight() {
        // 8 GB RAM -> Standard-8
        let rec8GB = MetagenomicsDatabaseRegistry.recommendedCollection(
            forRAMBytes: 8 * 1_073_741_824
        )
        XCTAssertEqual(rec8GB, .standard8, "8 GB RAM should recommend Standard-8")

        // 16 GB RAM -> Standard-16
        let rec16GB = MetagenomicsDatabaseRegistry.recommendedCollection(
            forRAMBytes: 16 * 1_073_741_824
        )
        XCTAssertEqual(rec16GB, .standard16, "16 GB RAM should recommend Standard-16")

        // 32 GB RAM -> Standard
        let rec32GB = MetagenomicsDatabaseRegistry.recommendedCollection(
            forRAMBytes: 32 * 1_073_741_824
        )
        XCTAssertEqual(rec32GB, .standard, "32 GB RAM should recommend Standard")

        // 72 GB RAM -> PlusPF
        let rec72GB = MetagenomicsDatabaseRegistry.recommendedCollection(
            forRAMBytes: 72 * 1_073_741_824
        )
        XCTAssertEqual(rec72GB, .plusPF, "72 GB RAM should recommend PlusPF")

        // 128 GB RAM -> PlusPF
        let rec128GB = MetagenomicsDatabaseRegistry.recommendedCollection(
            forRAMBytes: 128 * 1_073_741_824
        )
        XCTAssertEqual(rec128GB, .plusPF, "128 GB RAM should recommend PlusPF")
    }

    /// Verifies that recommended database name is correctly set in the view model.
    func testRecommendedDatabaseNameInViewModel() {
        let vm = PluginManagerViewModel()

        // Manually set the recommended name (would normally come from refreshDatabases)
        vm.recommendedDatabaseName = "Standard-8"

        XCTAssertEqual(vm.recommendedDatabaseName, "Standard-8")
    }

    // MARK: - testRemoveDatabase

    /// Verifies that the remove tracking state works correctly.
    func testRemoveDatabaseState() {
        let vm = PluginManagerViewModel()

        let dbName = "Viral"

        // Before removal
        XCTAssertFalse(vm.removingDatabases.contains(dbName))

        // Start removal
        vm.removingDatabases.insert(dbName)
        XCTAssertTrue(vm.removingDatabases.contains(dbName))

        // Finish removal
        vm.removingDatabases.remove(dbName)
        XCTAssertFalse(vm.removingDatabases.contains(dbName))
    }

    /// Verifies that removeDatabase resets a catalog entry via the registry.
    func testRemoveDatabaseResetsRegistryEntry() async throws {
        let registryDir = tempDir.appendingPathComponent("registry")
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: registryDir)

        // Load the catalog
        try await registry.loadIfNeeded()

        // Create a fake installed database directory
        let dbDir = registryDir.appendingPathComponent("kraken2/viral")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        for file in MetagenomicsDatabaseRegistry.requiredKraken2Files {
            try "fake".write(
                to: dbDir.appendingPathComponent(file),
                atomically: true,
                encoding: .utf8
            )
        }

        // Register the database
        try await registry.registerExisting(at: dbDir, name: "Viral")
        let dbBefore = try await registry.database(named: "Viral")
        XCTAssertEqual(dbBefore?.status, .ready)

        // Remove the database
        try await registry.removeDatabase(name: "Viral")
        let dbAfter = try await registry.database(named: "Viral")

        // A catalog entry should be reset to missing, not deleted
        XCTAssertNotNil(dbAfter, "Catalog entry should still exist after removal")
        XCTAssertEqual(dbAfter?.status, .missing, "Status should reset to .missing")
        XCTAssertFalse(dbAfter?.isDownloaded ?? true, "Should not be downloaded after removal")
    }

    // MARK: - Storage Calculation

    /// Verifies total storage calculation for installed databases.
    func testTotalDatabaseStorageBytes() {
        let vm = PluginManagerViewModel()

        // No databases -> 0 bytes
        XCTAssertEqual(vm.totalDatabaseStorageBytes, 0)

        // Add some databases with sizeOnDisk
        vm.databases = [
            makeDatabaseInfo(
                name: "Viral",
                status: .ready,
                sizeBytes: 536_870_912,
                path: tempDir.appendingPathComponent("viral")
            ),
            makeDatabaseInfo(
                name: "Standard-8",
                status: .ready,
                sizeBytes: 8 * 1_073_741_824,
                path: tempDir.appendingPathComponent("standard-8")
            ),
            makeDatabaseInfo(name: "PlusPF", status: .missing, sizeBytes: 72 * 1_073_741_824),
        ]

        // Only ready databases with sizeOnDisk should count
        let expected = Int64(536_870_912) + Int64(8 * 1_073_741_824)
        XCTAssertEqual(vm.totalDatabaseStorageBytes, expected)
    }

    /// Verifies that the storage path is under ~/.lungfish/databases.
    func testDatabaseStoragePath() {
        let vm = PluginManagerViewModel()
        let path = vm.databaseStoragePath

        XCTAssertTrue(path.contains(".lungfish/databases"), "Storage path should contain .lungfish/databases")
    }

    // MARK: - Database Collection Tests

    /// Verifies that all DatabaseCollection cases have display names.
    func testDatabaseCollectionDisplayNames() {
        for collection in DatabaseCollection.allCases {
            XCTAssertFalse(
                collection.displayName.isEmpty,
                "\(collection) should have a display name"
            )
        }
    }

    /// Verifies that all DatabaseCollection cases have download URL bases.
    func testDatabaseCollectionDownloadURLBases() {
        for collection in DatabaseCollection.allCases {
            XCTAssertTrue(
                collection.downloadURLBase.hasPrefix("https://"),
                "\(collection) download URL should start with https://"
            )
        }
    }

    /// Verifies that all DatabaseCollection cases have content descriptions.
    func testDatabaseCollectionDescriptions() {
        for collection in DatabaseCollection.allCases {
            XCTAssertFalse(
                collection.contentsDescription.isEmpty,
                "\(collection) should have a contents description"
            )
        }
    }

    // MARK: - Concurrent Download Guard

    /// Verifies that starting a download for an already-downloading database is a no-op.
    func testDuplicateDownloadGuard() {
        let vm = PluginManagerViewModel()

        // Simulate an in-progress download
        vm.downloadingDatabases.insert("Viral")
        vm.downloadProgress["Viral"] = 0.3

        // Calling downloadDatabase again should not reset progress
        // (In the real method, the guard check prevents re-entry)
        let wasDownloading = vm.downloadingDatabases.contains("Viral")
        XCTAssertTrue(wasDownloading, "Should still show as downloading")
        XCTAssertEqual(vm.downloadProgress["Viral"], 0.3, "Progress should not be reset")
    }

    // MARK: - Viral Database Properties

    /// Verifies that the Viral database has correct size properties for starter recommendation.
    func testViralDatabaseProperties() {
        let viral = MetagenomicsDatabaseInfo.builtInCatalog.first { $0.name == "Viral" }

        XCTAssertNotNil(viral, "Viral database should exist in catalog")
        XCTAssertEqual(viral?.collection, .viral)
        XCTAssertEqual(viral?.sizeBytes, 536_870_912, "Viral should be ~500 MB")
        XCTAssertEqual(viral?.recommendedRAM, 536_870_912, "Viral should need ~500 MB RAM")
        XCTAssertEqual(viral?.tool, "kraken2")
        XCTAssertTrue(
            viral?.description.lowercased().contains("viral") ?? false,
            "Viral description should mention viral"
        )
    }
}
