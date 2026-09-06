// DatabasesTabTests.swift - Tests for the Databases tab in Plugin Manager
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import os
import XCTest
@testable import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCore

// MARK: - DatabasesTabTests

/// Tests for the Databases tab in the Plugin Manager.
///
/// Verifies catalog display, download progress tracking, recommended database
/// highlighting, and database removal. These tests exercise the
/// ``PluginManagerViewModel`` data layer and ``MetagenomicsDatabaseInfo``
/// catalog without rendering SwiftUI views or performing real downloads.
/// Thrown by `waitUntil` after it has already recorded the timeout as a failure, so the
/// calling test stops instead of failing a second time on a follow-up unwrap.
private struct WaitTimeout: Error {}

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
        MainActor.assumeIsolated {
            ManagedStorageConfigStore.overrideSharedForTesting(nil)
            SettingsNavigationState.shared.selectedTab = .general
        }
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
        XCTAssertEqual(PluginManagerViewModel.Tab.databases.segmentIndex, 2)
    }

    /// Verifies that segment index 2 maps to the databases tab.
    func testSegmentIndexToDatabasesTab() {
        let tab = PluginManagerViewModel.Tab.from(segmentIndex: 2)
        XCTAssertEqual(tab, .databases)
    }

    /// Verifies that all three tab cases exist and have distinct segment indices.
    func testAllTabsHaveDistinctIndices() {
        let tabs: [PluginManagerViewModel.Tab] = [.installed, .packs, .databases]
        let indices = tabs.map(\.segmentIndex)
        XCTAssertEqual(Set(indices).count, 3, "All tabs should have distinct segment indices")
        XCTAssertEqual(indices, [0, 1, 2], "Tabs should be numbered 0-2")
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
        XCTAssertTrue(names.contains("SILVA"), "Kraken2 section should contain SILVA")
        XCTAssertTrue(names.contains("Greengenes"), "Kraken2 section should contain Greengenes")

        for name in ["SILVA", "Greengenes"] {
            let database = catalog.first { $0.name == name }
            XCTAssertEqual(database?.tool, MetagenomicsTool.kraken2.rawValue)
            XCTAssertNil(database?.collection, "Specialist rRNA databases must not receive the general recommendation badge")
        }

        // All catalog entries should start as missing
        for db in catalog {
            XCTAssertEqual(db.status, .missing, "\(db.name) should start as .missing")
            XCTAssertFalse(db.isDownloaded, "\(db.name) should not be downloaded initially")
        }
    }

    func testSpecialDatabaseRowsUseTheExistingGenericControlsAndCopy() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let viewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift"),
            encoding: .utf8
        )
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift"),
            encoding: .utf8
        )
        let combined = viewSource + modelSource

        XCTAssertTrue(viewSource.contains("PluginManagerAccessibilityID.databaseDownloadButton(database.name)"))
        XCTAssertTrue(viewSource.contains("PluginManagerAccessibilityID.databaseCancelButton(database.name)"))
        XCTAssertTrue(viewSource.contains("PluginManagerAccessibilityID.databaseRemoveButton(database.name)"))
        XCTAssertTrue(viewSource.contains("PluginManagerAccessibilityID.databaseUpdateButton(database.name)"))
        XCTAssertTrue(viewSource.contains("Text(\"Download\")"))
        XCTAssertTrue(viewSource.contains("Text(\"Update\")"))
        for specialistCopy in ["kraken2-build", "bracken-build", "local build", "recipe type"] {
            XCTAssertFalse(combined.localizedCaseInsensitiveContains(specialistCopy))
        }
    }

    /// Verifies that each catalog entry has a resolvable installation recipe.
    func testCatalogEntriesHaveInstallationRecipes() {
        for db in MetagenomicsDatabaseInfo.builtInCatalog {
            XCTAssertNotNil(db.installationRecipe, "\(db.name) should have an installation recipe")
            if case .archive(let url) = db.installationRecipe {
                XCTAssertEqual(url.scheme, "https", "\(db.name) archive URL should be HTTPS")
            }
        }
    }

    /// Verifies that each catalog entry has positive size and RAM values.
    func testCatalogEntriesHaveSizeAndRAM() {
        for db in MetagenomicsDatabaseInfo.builtInCatalog {
            XCTAssertGreaterThan(db.sizeBytes, 0, "\(db.name) should have positive size")
            XCTAssertGreaterThan(db.recommendedRAM, 0, "\(db.name) should have positive RAM requirement")
        }
    }

    func testDatabaseTrackingSummaryIncludesInstallDateAndUpdateIndicator() throws {
        let pinnedVersion = try XCTUnwrap(
            ManagedToolLock.bundled.database(id: "kraken2-standard-8")?.version
        )
        let installedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let db = MetagenomicsDatabaseInfo(
            name: "Standard-8",
            tool: MetagenomicsTool.kraken2.rawValue,
            version: "20230101",
            sizeBytes: 8 * 1_073_741_824,
            sizeOnDisk: 8 * 1_073_741_824,
            downloadURL: "https://example.com/standard-8.tar.gz",
            description: "Older installed database",
            collection: .standard8,
            path: URL(fileURLWithPath: "/tmp/standard-8"),
            installedAt: installedAt,
            lastUpdated: installedAt,
            status: .ready,
            recommendedRAM: 8 * 1_073_741_824
        )

        let summary = PluginManagerViewModel.databaseTrackingSummary(for: db)

        XCTAssertTrue(summary.contains("Installed"))
        XCTAssertTrue(summary.contains("Update available"))
        XCTAssertTrue(summary.contains(pinnedVersion))
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
        // 8 GB RAM -> PlusPF-8
        let rec8GB = MetagenomicsDatabaseRegistry.recommendedCollection(
            forRAMBytes: 8 * 1_073_741_824
        )
        XCTAssertEqual(rec8GB, .plusPF8, "8 GB RAM should recommend PlusPF-8")

        // 16 GB RAM -> PlusPF-8
        let rec16GB = MetagenomicsDatabaseRegistry.recommendedCollection(
            forRAMBytes: 16 * 1_073_741_824
        )
        XCTAssertEqual(rec16GB, .plusPF8, "16 GB RAM should recommend PlusPF-8")

        // 32 GB RAM -> PlusPF-16
        let rec32GB = MetagenomicsDatabaseRegistry.recommendedCollection(
            forRAMBytes: 32 * 1_073_741_824
        )
        XCTAssertEqual(rec32GB, .plusPF16, "32 GB RAM should recommend PlusPF-16")

        // 72 GB RAM -> PlusPF-16
        let rec72GB = MetagenomicsDatabaseRegistry.recommendedCollection(
            forRAMBytes: 72 * 1_073_741_824
        )
        XCTAssertEqual(rec72GB, .plusPF16, "72 GB RAM should recommend PlusPF-16")

        // 128 GB RAM -> PlusPF
        let rec128GB = MetagenomicsDatabaseRegistry.recommendedCollection(
            forRAMBytes: 128 * 1_073_741_824
        )
        XCTAssertEqual(rec128GB, .plusPF, "128 GB RAM should recommend PlusPF")
    }

    func testRecommendedDatabaseFor48GBRAMUsesLargestHeadroomFit() {
        let ramBytes: UInt64 = 48 * 1_073_741_824

        let recommended = MetagenomicsDatabaseRegistry.recommendedCollection(forRAMBytes: ramBytes)

        XCTAssertEqual(recommended, .plusPF16)
        XCTAssertLessThanOrEqual(
            UInt64(recommended?.approximateRAMBytes ?? .max),
            UInt64(Double(ramBytes) * 0.6)
        )
    }

    func testRecommendedDatabaseFor128GBRAMUsesLargestHeadroomFit() {
        let ramBytes: UInt64 = 128 * 1_073_741_824

        let recommended = MetagenomicsDatabaseRegistry.recommendedCollection(forRAMBytes: ramBytes)

        XCTAssertEqual(recommended, .plusPF)
        XCTAssertLessThanOrEqual(
            UInt64(recommended?.approximateRAMBytes ?? .max),
            UInt64(Double(ramBytes) * 0.6)
        )
    }

    func testRecommendedDatabaseFor8GBRAMUsesSmallestViableFallback() {
        let ramBytes: UInt64 = 8 * 1_073_741_824

        let recommended = MetagenomicsDatabaseRegistry.recommendedCollection(forRAMBytes: ramBytes)

        XCTAssertEqual(recommended, .plusPF8)
        XCTAssertLessThanOrEqual(UInt64(recommended?.approximateRAMBytes ?? .max), ramBytes)
    }

    func testRecommendedDatabaseForVeryLowRAMHasNoRecommendation() {
        let ramBytes: UInt64 = 4 * 1_073_741_824

        let recommended = MetagenomicsDatabaseRegistry.recommendedCollection(forRAMBytes: ramBytes)

        XCTAssertNil(recommended)
    }

    func testRecommendationBadgeUsesHeaderRecommendationName() {
        let vm = PluginManagerViewModel(automaticallyRefresh: false)
        let recommended = makeDatabaseInfo(
            name: "PlusPF-16",
            recommendedRAM: 1,
            collection: .plusPF16
        )
        vm.applyDatabaseRecommendation(databases: [recommended], recommended: recommended)

        XCTAssertTrue(vm.isRecommendedDatabase(recommended))
        XCTAssertFalse(vm.isRecommendedDatabase(makeDatabaseInfo(name: "Standard")))
    }

    func testRecommendationBadgeRequiresRegistrySelectedSource() {
        let vm = PluginManagerViewModel(automaticallyRefresh: false)
        vm.recommendedDatabaseName = "Oversized"

        XCTAssertFalse(vm.isRecommendedDatabase(makeDatabaseInfo(
            name: "Oversized",
            recommendedRAM: Int64.max
        )))
    }

    func testRecommendationBadgeUsesRegistrySelectedSourceForStalePersistedRow() throws {
        let vm = PluginManagerViewModel(automaticallyRefresh: false)
        let physicalRAMBytes: UInt64 = 48 * 1_073_741_824
        let policyLimitBytes = UInt64(Double(physicalRAMBytes) * 0.6)
        let stalePersistedRAMBytes: Int64 = 32 * 1_073_741_824
        let persistedPlusPF16 = makeDatabaseInfo(
            name: "PlusPF-16",
            recommendedRAM: stalePersistedRAMBytes,
            collection: .plusPF16
        )
        let registrySelectedPlusPF16 = try XCTUnwrap(
            MetagenomicsDatabaseInfo.catalogEntry(for: .plusPF16)
        )

        XCTAssertGreaterThan(UInt64(stalePersistedRAMBytes), policyLimitBytes)
        XCTAssertLessThanOrEqual(UInt64(stalePersistedRAMBytes), physicalRAMBytes)

        vm.applyDatabaseRecommendation(
            databases: [persistedPlusPF16],
            recommended: registrySelectedPlusPF16
        )

        let displayedPlusPF16 = try XCTUnwrap(vm.databases.first)
        XCTAssertEqual(vm.recommendedDatabaseName, "PlusPF-16")
        XCTAssertEqual(displayedPlusPF16.recommendedRAM, 16 * 1_073_741_824)
        XCTAssertTrue(vm.isRecommendedDatabase(displayedPlusPF16))
        XCTAssertFalse(vm.isRecommendedDatabase(persistedPlusPF16))
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

    /// Verifies that the footer path uses the shared managed storage root.
    func testDatabaseStoragePathUsesManagedStorageRoot() throws {
        let home = tempDir.appendingPathComponent("managed-storage-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let store = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })
        let customRoot = home.appendingPathComponent("External/Lungfish", isDirectory: true)
        try store.setActiveRoot(customRoot)
        ManagedStorageConfigStore.overrideSharedForTesting(store)

        let vm = PluginManagerViewModel(automaticallyRefresh: false)
        let path = vm.storageLocationPath

        XCTAssertEqual(path, customRoot.path)
        XCTAssertEqual(vm.storageLocationDisplayState, .customRoot(ManagedStorageLocation(rootURL: customRoot)))
        XCTAssertEqual(vm.storageLocationStatusText, "Custom shared storage")
    }

    func testDatabaseStorageFooterRefreshesAfterStorageChangeNotification() throws {
        let home = tempDir.appendingPathComponent("managed-storage-notification-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let store = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })
        ManagedStorageConfigStore.overrideSharedForTesting(store)

        let vm = PluginManagerViewModel(automaticallyRefresh: false)
        let defaultPath = store.defaultLocation.rootURL.path
        let customRoot = home.appendingPathComponent("External/Lungfish", isDirectory: true)
        try store.setActiveRoot(customRoot)

        XCTAssertEqual(vm.storageLocationPath, defaultPath)
        XCTAssertEqual(vm.storageLocationDisplayState, .defaultRoot)

        NotificationCenter.default.post(name: .databaseStorageLocationChanged, object: nil)

        XCTAssertEqual(vm.storageLocationPath, customRoot.path)
        XCTAssertEqual(vm.storageLocationDisplayState, .customRoot(ManagedStorageLocation(rootURL: customRoot)))
        XCTAssertEqual(vm.storageLocationStatusText, "Custom shared storage")
    }

    func testOpenStorageSettingsSelectsStorageTab() {
        SettingsNavigationState.shared.selectedTab = .general
        let vm = PluginManagerViewModel(automaticallyRefresh: false)

        vm.openStorageSettings()

        XCTAssertEqual(SettingsNavigationState.shared.selectedTab, .storage)
    }

    func testDatabaseStorageLocationChangePostsManagedResourcesDidChange() {
        let originalURL = AppSettings.shared.databaseStorageURL
        defer { AppSettings.shared.databaseStorageURL = originalURL }

        let exp = expectation(forNotification: .managedResourcesDidChange, object: nil)
        AppSettings.shared.databaseStorageURL = tempDir.appendingPathComponent("db-storage-change")
        wait(for: [exp], timeout: 1.0)
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

    /// Verifies that the manifest pins an HTTPS download for every DatabaseCollection case.
    func testDatabaseCollectionDownloadURLsComeFromManifest() throws {
        for collection in DatabaseCollection.allCases {
            let spec = try XCTUnwrap(
                ManagedToolLock.bundled.database(id: "kraken2-\(collection.rawValue)"),
                "\(collection) is missing from the dependency manifest"
            )
            let url = try XCTUnwrap(spec.url, "\(collection) has no pinned download URL")
            XCTAssertTrue(url.hasPrefix("https://"), "\(collection) download URL should start with https://")
            XCTAssertEqual(
                MetagenomicsDatabaseInfo.catalogEntry(for: collection)?.downloadURL,
                url,
                "\(collection) catalog entry should use the manifest URL"
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

    // MARK: - Database Update Action

    /// An installed row whose version predates the pinned one, so it advertises an update.
    private func outdatedStandard8(catalogID: String? = nil) throws -> MetagenomicsDatabaseInfo {
        MetagenomicsDatabaseInfo(
            name: "Standard-8",
            tool: MetagenomicsTool.kraken2.rawValue,
            version: "20230101",
            sizeBytes: 1024,
            catalogID: catalogID,
            description: "Older installed database",
            collection: .standard8,
            path: URL(fileURLWithPath: "/tmp/standard-8"),
            status: .ready,
            recommendedRAM: 1024
        )
    }

    /// The Update action must address the registry by the *resolved* catalog id, so a row
    /// registered from disk (which records none) updates like a catalog-installed one.
    func testUpdateDatabasePassesTheResolvedCatalogID() async throws {
        let database = try outdatedStandard8()
        XCTAssertNil(database.catalogID, "fixture models a registerExisting row")

        let recorded = OSAllocatedUnfairLock<[String]>(initialState: [])
        let vm = PluginManagerViewModel(
            automaticallyRefresh: false,
            updateDatabaseAction: { catalogID, progress in
                recorded.withLock { $0.append(catalogID) }
                progress(1.0, "done")
            }
        )

        vm.updateDatabase(database)
        try await waitUntil { recorded.withLock { !$0.isEmpty } }

        XCTAssertEqual(recorded.withLock { $0 }, ["kraken2-standard-8"])
    }

    /// A row with no update on offer, one already updating, and one whose name matches no
    /// catalog entry are all ineligible, so the button cannot start work that would fail.
    func testUpdateEnablement() throws {
        let vm = PluginManagerViewModel(automaticallyRefresh: false)
        let outdated = try outdatedStandard8()
        XCTAssertTrue(vm.canUpdateDatabase(outdated))

        let current = MetagenomicsDatabaseInfo(
            name: "Standard-8",
            tool: MetagenomicsTool.kraken2.rawValue,
            version: try XCTUnwrap(ManagedToolLock.bundled.database(id: "kraken2-standard-8")?.version),
            sizeBytes: 1024, description: "", collection: .standard8,
            path: URL(fileURLWithPath: "/tmp/standard-8"), status: .ready, recommendedRAM: 1024
        )
        XCTAssertFalse(vm.canUpdateDatabase(current), "an up-to-date row offers nothing to apply")

        let imported = MetagenomicsDatabaseInfo(
            name: "My Custom DB", tool: MetagenomicsTool.kraken2.rawValue, version: "1.0",
            sizeBytes: 1024, description: "", path: URL(fileURLWithPath: "/tmp/custom"),
            status: .ready, recommendedRAM: 1024
        )
        XCTAssertFalse(vm.canUpdateDatabase(imported), "a row outside the catalog has no update target")

        vm.updatingDatabases.insert(outdated.name)
        XCTAssertFalse(vm.canUpdateDatabase(outdated), "a second click must not stack two swaps")
        vm.updatingDatabases.remove(outdated.name)

        vm.removingDatabases.insert(outdated.name)
        XCTAssertFalse(vm.canUpdateDatabase(outdated))
    }

    /// A database that cannot be swapped in place reports guidance on the row, not an error
    /// alert, and leaves no failure recorded against the download.
    func testUpdateNotSupportedIsSurfacedInline() async throws {
        let database = try outdatedStandard8()
        let vm = PluginManagerViewModel(
            automaticallyRefresh: false,
            updateDatabaseAction: { _, _ in
                throw MetagenomicsDatabaseRegistryError.updateNotSupported(
                    name: "Standard-8",
                    reason: "it is rebuilt by reinstalling"
                )
            }
        )

        vm.updateDatabase(database)
        try await waitUntil { vm.databaseUpdateNotice["Standard-8"] != nil }

        let notice = try XCTUnwrap(vm.databaseUpdateNotice["Standard-8"])
        XCTAssertTrue(notice.contains("rebuilt by reinstalling"), notice)
        XCTAssertNil(vm.downloadError["Standard-8"], "guidance must not masquerade as a download failure")
        XCTAssertFalse(vm.updatingDatabases.contains("Standard-8"))
    }

    /// A real failure lands in the row's error slot so the existing Dismiss affordance clears it.
    func testUpdateFailureIsRecordedAsAnError() async throws {
        let database = try outdatedStandard8()
        struct Boom: LocalizedError { var errorDescription: String? { "network went away" } }
        let vm = PluginManagerViewModel(
            automaticallyRefresh: false,
            updateDatabaseAction: { _, _ in throw Boom() }
        )

        vm.updateDatabase(database)
        try await waitUntil { vm.downloadError["Standard-8"] != nil }

        XCTAssertEqual(vm.downloadError["Standard-8"], "network went away")
        XCTAssertNil(vm.databaseUpdateNotice["Standard-8"])
    }

    /// Polls on the main actor until `condition` holds, so a test can await a `Task` the
    /// view model started without the view model having to expose its handle.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout)s")
                throw WaitTimeout()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
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
