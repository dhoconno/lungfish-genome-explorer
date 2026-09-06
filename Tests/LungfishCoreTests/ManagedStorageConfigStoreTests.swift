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

extension ManagedStorageConfigStoreTests {
    func testDebugSubprocessReceivesSharedRootAsExplicitOverride() throws {
        let home = try makeTemporaryHomeDirectory()
        let root = home.appendingPathComponent("preview-storage", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment = ["LUNGFISH_SHARED_PREVIEW_ROOT": root.path, "PATH": "/test/bin"]
        let gui = ManagedStorageConfigStore(homeDirectory: home, appIdentity: .debug, environmentProvider: { environment })
        let inherited = gui.subprocessEnvironment()
        let cli = ManagedStorageConfigStore(homeDirectory: home, appIdentity: .stable, environmentProvider: { inherited })
        XCTAssertEqual(inherited["PATH"], "/test/bin")
        XCTAssertEqual(inherited["LUNGFISH_STORAGE_ROOT"], root.path)
        XCTAssertEqual(cli.currentLocation().rootURL, gui.currentLocation().rootURL)
        XCTAssertEqual(cli.currentCondaRootURL(), gui.currentCondaRootURL())
    }

    func testDebugSubprocessKeepsIsolatedFallbackAndExplicitCondaOverride() throws {
        let home = try makeTemporaryHomeDirectory()
        let gui = ManagedStorageConfigStore(homeDirectory: home, appIdentity: .debug, environmentProvider: { [:] })
        XCTAssertEqual(gui.subprocessEnvironment()["LUNGFISH_STORAGE_ROOT"], gui.defaultLocation.rootURL.path)
        XCTAssertEqual(gui.subprocessEnvironment()["LUNGFISH_CONDA_ROOT"], gui.defaultLocation.condaRootURL.path)
        let custom = home.appendingPathComponent("custom", isDirectory: true)
        try gui.setActiveRoot(custom)
        let conda = home.appendingPathComponent("separate-conda", isDirectory: true)
        let environment = gui.subprocessEnvironment(environment: ["LUNGFISH_CONDA_ROOT": conda.path])
        XCTAssertEqual(environment["LUNGFISH_STORAGE_ROOT"], custom.path)
        XCTAssertEqual(environment["LUNGFISH_CONDA_ROOT"], conda.path)
    }

    func testNonDebugSubprocessEnvironmentIsUnchanged() throws {
        let home = try makeTemporaryHomeDirectory()
        let environment = ["PATH": "/test/bin", "LUNGFISH_SHARED_PREVIEW_ROOT": "/ignored"]
        for identity in [LungfishAppIdentity.preview, .stable] {
            let store = ManagedStorageConfigStore(homeDirectory: home, appIdentity: identity, environmentProvider: { environment })
            XCTAssertEqual(store.subprocessEnvironment(), environment)
        }
    }

    func testDebugUsesSharedPreviewMarkerWithoutPersistingIt() throws {
        let home = try makeTemporaryHomeDirectory()
        let root = home.appendingPathComponent("preview-storage", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment = ["LUNGFISH_SHARED_PREVIEW_ROOT": root.path]
        let store = ManagedStorageConfigStore(homeDirectory: home, appIdentity: .debug, environmentProvider: { environment })

        XCTAssertEqual(store.automaticallySharedPreviewLocation?.rootURL, root)
        XCTAssertEqual(store.currentLocation().rootURL, root)
        XCTAssertEqual(store.currentCondaRootURL(), root.appendingPathComponent("conda", isDirectory: true))
        XCTAssertEqual(store.bootstrapConfigLoadState(), .missing)
        XCTAssertEqual(store.currentLocation(environment: [:]).rootURL, store.defaultLocation.rootURL)
    }

    func testExplicitRootsPreventAutomaticPreviewSharing() throws {
        let home = try makeTemporaryHomeDirectory()
        let root = home.appendingPathComponent("preview-storage", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ManagedStorageConfigStore(homeDirectory: home, appIdentity: .debug, environmentProvider: { [:] })
        for key in ["LUNGFISH_STORAGE_ROOT", "LUNGFISH_CONDA_ROOT"] {
            for value in [home.appendingPathComponent("explicit").path, "/invalid path"] {
                let environment = ["LUNGFISH_SHARED_PREVIEW_ROOT": root.path, key: value]
                XCTAssertNil(store.automaticallySharedPreviewLocation(environment: environment))
                XCTAssertNotEqual(store.currentLocation(environment: environment).rootURL, root)
            }
        }
    }

    func testBootstrapConfigurationPreventsAutomaticPreviewSharing() throws {
        let home = try makeTemporaryHomeDirectory()
        let root = home.appendingPathComponent("preview-storage", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment = ["LUNGFISH_SHARED_PREVIEW_ROOT": root.path]
        let store = ManagedStorageConfigStore(homeDirectory: home, appIdentity: .debug, environmentProvider: { environment })
        let custom = home.appendingPathComponent("custom", isDirectory: true)
        try store.setActiveRoot(custom)
        XCTAssertNil(store.automaticallySharedPreviewLocation)
        XCTAssertEqual(store.currentLocation().rootURL, custom)
        try Data("malformed".utf8).write(to: store.configURL)
        XCTAssertNil(store.automaticallySharedPreviewLocation)
        XCTAssertEqual(store.currentLocation().rootURL, store.defaultLocation.rootURL)
    }

    func testAutomaticPreviewSharingRequiresExistingValidDirectory() throws {
        let home = try makeTemporaryHomeDirectory()
        let file = home.appendingPathComponent("regular-file")
        try Data().write(to: file)
        let invalidDirectory = home.appendingPathComponent("contains spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        let store = ManagedStorageConfigStore(homeDirectory: home, appIdentity: .debug, environmentProvider: { [:] })
        for path in ["", " ", "relative-root", home.appendingPathComponent("missing").path, file.path, invalidDirectory.path] {
            let environment = ["LUNGFISH_SHARED_PREVIEW_ROOT": path]
            XCTAssertNil(store.automaticallySharedPreviewLocation(environment: environment), path)
            XCTAssertEqual(store.currentLocation(environment: environment).rootURL, store.defaultLocation.rootURL)
        }
    }

    func testAutomaticPreviewSharingIsRestrictedToUpstreamDebug() throws {
        let home = try makeTemporaryHomeDirectory()
        let root = home.appendingPathComponent("preview-storage", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fork = try LungfishAppIdentity.from(infoDictionary: [
            "CFBundleDisplayName": "Example Genome Debug", "CFBundleName": "Example Debug",
            "CFBundleIdentifier": "org.example.genome.debug", "LungfishReleaseChannel": "debug",
            "LungfishIdentitySchemaVersion": 1, "LungfishRuntimeNamespace": "org.example.genome",
        ])
        for identity in [LungfishAppIdentity.preview, .stable, fork] {
            let store = ManagedStorageConfigStore(homeDirectory: home, appIdentity: identity, environmentProvider: { [:] })
            let environment = ["LUNGFISH_SHARED_PREVIEW_ROOT": root.path]
            XCTAssertNil(store.automaticallySharedPreviewLocation(environment: environment))
            XCTAssertNotEqual(store.currentLocation(environment: environment).rootURL, root)
        }
    }

    func testForkNeverMigratesOrRemovesUpstreamLegacyPreference() throws {
        let home = try makeTemporaryHomeDirectory()
        let identity = try LungfishAppIdentity.from(infoDictionary: [
            "CFBundleDisplayName": "Example Genome Preview", "CFBundleName": "Example Preview",
            "CFBundleIdentifier": "org.example.genome.preview", "LungfishReleaseChannel": "preview",
            "LungfishIdentitySchemaVersion": 1, "LungfishRuntimeNamespace": "org.example.genome",
        ])
        let suite = "org.example.storage-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = home.appendingPathComponent("upstream-storage")
        defaults.set(legacy.path, forKey: "DatabaseStorageLocation")
        let store = ManagedStorageConfigStore(homeDirectory: home, appIdentity: identity, environmentProvider: { [:] })
        store.overrideLegacyDefaultsForTesting(defaults)
        XCTAssertEqual(store.currentLocation().rootURL, store.defaultLocation.rootURL)
        XCTAssertEqual(store.configURL.path, home.appendingPathComponent(".config/org.example.genome.preview/storage-location.json").path)
        try store.setActiveRoot(home.appendingPathComponent("fork-selected-storage"))
        try store.resetToDefaultLocation()
        XCTAssertEqual(defaults.string(forKey: "DatabaseStorageLocation"), legacy.path)
        XCTAssertEqual(store.currentLocation().rootURL, store.defaultLocation.rootURL)
        let explicit = home.appendingPathComponent("explicit-override", isDirectory: true)
        XCTAssertEqual(store.currentLocation(environment: ["LUNGFISH_STORAGE_ROOT": explicit.path]).rootURL, explicit)
    }
}
