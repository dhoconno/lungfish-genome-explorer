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

    func testInjectedEnvironmentPreservesExplicitOverridePrecedence() throws {
        let home = try makeTemporaryHomeDirectory()
        let injectedRoot = home.appendingPathComponent("injected-root", isDirectory: true)
        let injectedConda = home.appendingPathComponent("injected-conda", isDirectory: true)
        let store = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: {
            ["LUNGFISH_STORAGE_ROOT": injectedRoot.path, "LUNGFISH_CONDA_ROOT": injectedConda.path]
        })
        try store.setActiveRoot(home.appendingPathComponent("configured-root", isDirectory: true))

        XCTAssertEqual(store.currentLocation().rootURL.standardizedFileURL, injectedRoot.standardizedFileURL)
        XCTAssertEqual(store.currentCondaRootURL().standardizedFileURL, injectedConda.standardizedFileURL)
        let explicitRoot = home.appendingPathComponent("explicit-root", isDirectory: true)
        let explicitEnvironment = ["LUNGFISH_STORAGE_ROOT": explicitRoot.path]
        XCTAssertEqual(store.currentLocation(environment: explicitEnvironment).rootURL.standardizedFileURL,
            explicitRoot.standardizedFileURL)
        XCTAssertEqual(store.currentCondaRootURL(environment: explicitEnvironment).standardizedFileURL,
            explicitRoot.appendingPathComponent("conda", isDirectory: true).standardizedFileURL)
        XCTAssertEqual(store.currentLocation(environment: [:]).rootURL.standardizedFileURL,
            home.appendingPathComponent("configured-root", isDirectory: true).standardizedFileURL)
    }

    func testBootstrapConfigLoadStateDistinguishesMissingAndMalformedBootstrap() throws {
        let home = try makeTemporaryHomeDirectory()
        let store = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })

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
        let store = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })

        XCTAssertEqual(store.configURL.path, home.appendingPathComponent(".config/lungfish/storage-location.json").path)
        XCTAssertEqual(store.currentLocation().rootURL.path, home.appendingPathComponent(".lungfish").path)
    }

    func testDebugDefaultsUseIsolatedConfigAndManagedStorageRoots() throws {
        let home = try makeTemporaryHomeDirectory()
        let store = ManagedStorageConfigStore(
            homeDirectory: home,
            appIdentity: .debug
        )

        XCTAssertEqual(
            store.configURL.path,
            home.appendingPathComponent(".config/lungfish-debug/storage-location.json").path
        )
        XCTAssertEqual(
            store.currentLocation(environment: [:]).rootURL.path,
            home.appendingPathComponent(".lungfish-debug").path
        )
    }

    func testDebugDoesNotReadStableLegacyStoragePreference() throws {
        let home = try makeTemporaryHomeDirectory()
        let legacyRoot = URL(fileURLWithPath: "/tmp/legacy-lungfish", isDirectory: true)
        let legacyKey = "DatabaseStorageLocation"
        UserDefaults.standard.set(legacyRoot.path, forKey: legacyKey)
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }

        let store = ManagedStorageConfigStore(homeDirectory: home, appIdentity: .debug, environmentProvider: { [:] })

        XCTAssertEqual(
            store.currentLocation(environment: [:]).rootURL.standardizedFileURL,
            home.appendingPathComponent(".lungfish-debug", isDirectory: true).standardizedFileURL
        )
    }

    func testCurrentLocationFallsBackToDefaultWhenLegacyDatabaseStorageLocationIsInvalid() throws {
        let home = try makeTemporaryHomeDirectory()
        let legacyRoot = URL(fileURLWithPath: "/Volumes/My SSD/Lungfish", isDirectory: true)
        let legacyKey = "DatabaseStorageLocation"

        UserDefaults.standard.set(legacyRoot.path, forKey: legacyKey)
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }

        let store = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })
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

        let store = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })
        XCTAssertEqual(store.currentLocation().rootURL.standardizedFileURL.path, legacyRoot.standardizedFileURL.path)
    }

    func testCurrentCondaRootRejectsEnvironmentOverrideWithSpaces() throws {
        let home = try makeTemporaryHomeDirectory()
        let store = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })
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

        let store = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })
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

        let store = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })
        try store.setActiveRoot(customRoot)

        let reloaded = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })
        XCTAssertEqual(reloaded.currentLocation().rootURL.standardizedFileURL.path, customRoot.standardizedFileURL.path)
    }

    func testStorageRootEnvironmentOverrideWins() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lgeroot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tmp)
        }
        let store = ManagedStorageConfigStore()
        let env = ["LUNGFISH_STORAGE_ROOT": tmp.path]
        XCTAssertEqual(store.currentLocation(environment: env).rootURL.standardizedFileURL, tmp.standardizedFileURL)
        XCTAssertEqual(store.currentCondaRootURL(environment: env), tmp.appendingPathComponent("conda", isDirectory: true).standardizedFileURL)
    }

    func testCondaRootOverrideStillWinsOverStorageRootForConda() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID().uuidString)")
        let conda = FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString)")
        for u in [root, conda] { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: conda)
        }
        let store = ManagedStorageConfigStore()
        let env = ["LUNGFISH_STORAGE_ROOT": root.path, "LUNGFISH_CONDA_ROOT": conda.path]
        XCTAssertEqual(store.currentCondaRootURL(environment: env), conda.standardizedFileURL)
    }

    func testStorageRootEnvironmentOverrideWithSpacesIsIgnored() throws {
        let home = try makeTemporaryHomeDirectory()
        let store = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })
        let invalidOverride = "/tmp/Lungfish Storage Root"

        let resolved = store.currentLocation(environment: [
            "LUNGFISH_STORAGE_ROOT": invalidOverride,
        ])

        XCTAssertEqual(
            resolved.rootURL.standardizedFileURL.path,
            home.appendingPathComponent(".lungfish").standardizedFileURL.path
        )
    }
}
