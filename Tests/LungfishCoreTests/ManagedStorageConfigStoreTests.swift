import XCTest
@testable import LungfishCore

final class ManagedStorageConfigStoreTests: XCTestCase {
    private func makeTemporaryHomeDirectory() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: home)
        }
        return home
    }

    func testBootstrapConfigIncludesLegacySchemaFields() {
        let config = ManagedStorageBootstrapConfig(
            activeRootPath: "/tmp/new-root",
            previousRootPath: "/tmp/old-root",
            migrationState: .pending
        )

        XCTAssertEqual(config.activeRootPath, "/tmp/new-root")
        XCTAssertEqual(config.previousRootPath, "/tmp/old-root")
        XCTAssertEqual(config.migrationState, .pending)
    }

    func testBootstrapConfigLoadStateDistinguishesMissingAndMalformedBootstrap() throws {
        let home = try makeTemporaryHomeDirectory()
        let store = ManagedStorageConfigStore(homeDirectory: home)

        XCTAssertEqual(store.bootstrapConfigLoadState(), .missing)

        try FileManager.default.createDirectory(
            at: store.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: store.configURL, options: [.atomic])

        XCTAssertEqual(store.bootstrapConfigLoadState(), .malformed)
    }

    func testCurrentLocationDefaultsToDotLungfishUnderHome() throws {
        let home = try makeTemporaryHomeDirectory()
        let store = ManagedStorageConfigStore(homeDirectory: home)

        XCTAssertEqual(store.configURL.path, home.appendingPathComponent(".config/lungfish/storage-location.json").path)
        XCTAssertEqual(store.currentLocation().rootURL.path, home.appendingPathComponent(".lungfish").path)
    }

    func testCurrentLocationFallsBackToDefaultWhenLegacyDatabaseStorageLocationIsInvalid() throws {
        let home = try makeTemporaryHomeDirectory()
        let legacyRoot = URL(fileURLWithPath: "/Volumes/My SSD/Lungfish", isDirectory: true)
        let legacyKey = "DatabaseStorageLocation"

        UserDefaults.standard.set(legacyRoot.path, forKey: legacyKey)
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }

        let store = ManagedStorageConfigStore(homeDirectory: home)
        XCTAssertEqual(store.currentLocation().rootURL.standardizedFileURL.path, home.appendingPathComponent(".lungfish").standardizedFileURL.path)
    }

    func testCurrentLocationFallsBackToLegacyDatabaseStorageLocationWhenBootstrapMissing() throws {
        let home = try makeTemporaryHomeDirectory()
        let legacyRoot = URL(fileURLWithPath: "/tmp/legacy-lungfish", isDirectory: true)
        let legacyKey = "DatabaseStorageLocation"

        UserDefaults.standard.set(legacyRoot.path, forKey: legacyKey)
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }

        let store = ManagedStorageConfigStore(homeDirectory: home)
        XCTAssertEqual(store.currentLocation().rootURL.standardizedFileURL.path, legacyRoot.standardizedFileURL.path)
    }

    func testCurrentCondaRootRejectsEnvironmentOverrideWithSpaces() throws {
        let home = try makeTemporaryHomeDirectory()
        let store = ManagedStorageConfigStore(homeDirectory: home)
        let invalidOverride = "/tmp/Lungfish Conda Root"

        let resolved = store.currentCondaRootURL(environment: [
            "LUNGFISH_CONDA_ROOT": invalidOverride,
        ])

        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            store.currentLocation().condaRootURL.standardizedFileURL.path
        )
    }

    func testSettingDefaultRootOverridesLegacyDatabaseFallback() throws {
        let home = try makeTemporaryHomeDirectory()
        let legacyRoot = URL(fileURLWithPath: "/tmp/legacy-lungfish", isDirectory: true)
        let legacyKey = "DatabaseStorageLocation"

        UserDefaults.standard.set(legacyRoot.path, forKey: legacyKey)
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }

        let store = ManagedStorageConfigStore(homeDirectory: home)
        try store.setActiveRoot(home.appendingPathComponent(".lungfish", isDirectory: true))

        XCTAssertEqual(store.currentLocation().rootURL.standardizedFileURL.path, home.appendingPathComponent(".lungfish").standardizedFileURL.path)

        switch store.bootstrapConfigLoadState() {
        case .loaded(let config):
            XCTAssertEqual(config.activeRootPath, home.appendingPathComponent(".lungfish").path)
        default:
            XCTFail("Expected explicit default bootstrap config to override legacy fallback")
        }
    }

    func testSetActiveRootPersistsBootstrapConfig() throws {
        let home = try makeTemporaryHomeDirectory()
        let customRoot = URL(fileURLWithPath: "/tmp/custom-lungfish", isDirectory: true)

        let store = ManagedStorageConfigStore(homeDirectory: home)
        try store.setActiveRoot(customRoot)

        let reloaded = ManagedStorageConfigStore(homeDirectory: home)
        XCTAssertEqual(reloaded.currentLocation().rootURL.standardizedFileURL.path, customRoot.standardizedFileURL.path)
    }
}
