// AppSettingsTests.swift - Tests for centralized application preferences
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

@MainActor private var appSettingsTestsManagedStorageHomeDirectory: URL?
@MainActor private var appSettingsTestsDefaults: UserDefaults?
@MainActor private var appSettingsTestsSuiteName: String?
@MainActor private var appSettingsTestsRestoreSettings: (@MainActor () -> Void)?
@MainActor private var appSettingsTestsPreviousStorage: ManagedStorageConfigStore?

final class AppSettingsTests: XCTestCase {
    @MainActor private var defaults: UserDefaults { appSettingsTestsDefaults! }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MainActor.assumeIsolated {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let suiteName = "org.lungfish.tests.AppSettings.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            let store = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })
            store.overrideLegacyDefaultsForTesting(defaults)

            appSettingsTestsManagedStorageHomeDirectory = home
            appSettingsTestsDefaults = defaults
            appSettingsTestsSuiteName = suiteName
            appSettingsTestsPreviousStorage = ManagedStorageConfigStore.shared
            ManagedStorageConfigStore.overrideSharedForTesting(store)
            appSettingsTestsRestoreSettings = AppSettings.isolateForTesting(defaults: defaults)
            // All persistence and storage are isolated before this reset.
            AppSettings.shared.resetToDefaults()
        }
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated {
            appSettingsTestsRestoreSettings?()
            appSettingsTestsRestoreSettings = nil
            ManagedStorageConfigStore.overrideSharedForTesting(appSettingsTestsPreviousStorage)
            appSettingsTestsPreviousStorage = nil
            if let home = appSettingsTestsManagedStorageHomeDirectory {
                try? FileManager.default.removeItem(at: home)
            }
            if let suiteName = appSettingsTestsSuiteName {
                appSettingsTestsDefaults?.removePersistentDomain(forName: suiteName)
            }
            appSettingsTestsDefaults = nil
            appSettingsTestsSuiteName = nil
            appSettingsTestsManagedStorageHomeDirectory = nil
        }
        try super.tearDownWithError()
    }

    // MARK: - Default Values

    @MainActor
    func testIsolatedSettingsScopeRestoresRawValuesWithoutWritingPreviousDefaults() throws {
        let suiteName = "org.lungfish.tests.AppSettings.nested.\(UUID().uuidString)"
        let nestedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { nestedDefaults.removePersistentDomain(forName: suiteName) }
        let retainedData = Data("retained-fixture-settings".utf8)
        defaults.set(retainedData, forKey: "com.lungfish.appSettings")
        AppSettings.shared.defaultZoomWindow = -123
        do {
            let restore = AppSettings.isolateForTesting(defaults: nestedDefaults)
            defer { restore() }
            AppSettings.shared.defaultZoomWindow = 42_000
            AppSettings.shared.save()
            XCTAssertNotNil(nestedDefaults.data(forKey: "com.lungfish.appSettings"))
        }
        XCTAssertEqual(AppSettings.shared.defaultZoomWindow, -123)
        XCTAssertEqual(defaults.data(forKey: "com.lungfish.appSettings"), retainedData)
    }

    @MainActor
    func testFixtureUsesDedicatedPreferencesAndTemporaryStorage() throws {
        XCTAssertFalse(defaults === UserDefaults.standard)
        let home = try XCTUnwrap(appSettingsTestsManagedStorageHomeDirectory)
        XCTAssertTrue(ManagedStorageConfigStore.shared.configURL.standardizedFileURL.path
            .hasPrefix(home.standardizedFileURL.path + "/"))
        // Identity only: this does not enumerate or read any preference values.
        print("AppSettings XCTest host: process=\(ProcessInfo.processInfo.processName), bundle=\(Bundle.main.bundleIdentifier ?? "<none>")")
    }

    @MainActor
    func testDefaultValues() {
        let settings = AppSettings.shared
        XCTAssertEqual(settings.contentTextSizePreference, .system)
        XCTAssertEqual(settings.defaultZoomWindow, 10_000)
        XCTAssertEqual(settings.maxUndoLevels, 100)
        XCTAssertEqual(settings.vcfImportProfile, "auto")
        XCTAssertEqual(settings.tempFileRetentionHours, 24)
        XCTAssertEqual(settings.maxAnnotationRows, 50)
        XCTAssertEqual(settings.sequenceFetchCapKb, 500)
        XCTAssertEqual(settings.maxTableDisplayCount, 5_000)
        XCTAssertEqual(settings.densityThresholdBpPerPixel, 50_000)
        XCTAssertEqual(settings.squishedThresholdBpPerPixel, 500)
        XCTAssertEqual(settings.showLettersThresholdBpPerPixel, 10.0)
        XCTAssertEqual(settings.tooltipDelay, 0.15)
        XCTAssertFalse(settings.aiSearchEnabled)
        XCTAssertEqual(settings.openAIModel, "gpt-5.5")
        XCTAssertEqual(settings.anthropicModel, "claude-sonnet-4-6")
        XCTAssertEqual(settings.geminiModel, "gemini-3.5-flash")
        XCTAssertFalse(settings.openAIHostedEndpointEnabled)
        XCTAssertEqual(settings.openAIHostedEndpointKind, "azure")
        XCTAssertEqual(settings.openAIHostedEndpoint, "")
        XCTAssertEqual(settings.openAIHostedDeployment, "")
        XCTAssertEqual(settings.defaultAnnotationHeight, 16)
        XCTAssertEqual(settings.defaultAnnotationSpacing, 2)
        XCTAssertEqual(settings.horizontalScrollDirection, .traditional)
        XCTAssertEqual(settings.provenanceSigningProvider, "off")
        XCTAssertEqual(settings.provenanceSigningPublicKeyPath, "")
        XCTAssertEqual(settings.analystIdentityOverride, "")
        XCTAssertEqual(settings.resolvedAnalystIdentity(fallback: "fallback analyst"), "fallback analyst")
        XCTAssertEqual(settings.experimentalFeaturesEnabled, AppSettings.defaultExperimentalFeaturesEnabled)
    }

    @MainActor
    func testLegacyDatabaseDefaultUsesIdentityAwareManagedStorage() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        XCTAssertEqual(
            AppSettings.databaseStorageDefaultURL(homeDirectory: home, appIdentity: .stable).path,
            "/Users/example/.lungfish/databases"
        )
        XCTAssertEqual(
            AppSettings.databaseStorageDefaultURL(homeDirectory: home, appIdentity: .preview).path,
            "/Users/example/.lungfish/databases"
        )
        XCTAssertEqual(
            AppSettings.databaseStorageDefaultURL(homeDirectory: home, appIdentity: .debug).path,
            "/Users/example/.lungfish-debug/databases"
        )
    }

    @MainActor
    func testAnalystIdentityOverrideUsesTrimmedValueOrFallback() {
        let settings = AppSettings.shared

        settings.analystIdentityOverride = "   "
        XCTAssertEqual(settings.resolvedAnalystIdentity(fallback: "fallback analyst"), "fallback analyst")

        settings.analystIdentityOverride = "  Dr. Ada Lovelace  "
        XCTAssertEqual(settings.resolvedAnalystIdentity(fallback: "fallback analyst"), "Dr. Ada Lovelace")
    }

    @MainActor
    func testManagedStorageDisplayStateUsesSharedConfigStore() throws {
        let settings = AppSettings.shared
        let expectedDefaultRoot = ManagedStorageConfigStore.shared.defaultLocation.rootURL.standardizedFileURL

        XCTAssertEqual(settings.managedStorageDisplayState, .defaultRoot)
        XCTAssertEqual(settings.managedStorageRootURL.standardizedFileURL.path, expectedDefaultRoot.path)
        XCTAssertTrue(settings.isManagedStorageDefault)

        let customRoot = URL(fileURLWithPath: "/tmp/custom-lungfish", isDirectory: true)
        try ManagedStorageConfigStore.shared.setActiveRoot(customRoot)

        XCTAssertEqual(settings.managedStorageDisplayState, .customRoot(ManagedStorageLocation(rootURL: customRoot)))
        XCTAssertEqual(settings.managedStorageRootURL.standardizedFileURL.path, customRoot.standardizedFileURL.path)
        XCTAssertFalse(settings.isManagedStorageDefault)
    }

    // MARK: - Save/Load Roundtrip

    @MainActor
    func testSaveLoadRoundtrip() {
        let settings = AppSettings.shared

        // Modify several values
        settings.contentTextSizePreference = .custom(150)
        settings.defaultZoomWindow = 50_000
        settings.maxAnnotationRows = 100
        settings.vcfImportProfile = "fast"
        settings.tooltipDelay = 0.5
        settings.aiSearchEnabled = true
        settings.openAIModel = "gpt-4-turbo"
        settings.openAIHostedEndpointEnabled = true
        settings.openAIHostedEndpoint = " https://oc-aiservices.openai.azure.com/ "
        settings.openAIHostedDeployment = " gpt-5-mini "
        settings.provenanceSigningProvider = "local"
        settings.provenanceSigningPublicKeyPath = "/tmp/lungfish-provenance.pub"
        settings.analystIdentityOverride = "  Dr. Ada Lovelace  "
        settings.experimentalFeaturesEnabled = false
        settings.save()

        // Reset in-memory state
        settings.resetToDefaults()
        XCTAssertEqual(settings.defaultZoomWindow, 10_000)
        XCTAssertEqual(settings.maxAnnotationRows, 50)

        // Load from UserDefaults
        AppSettings.load()
        XCTAssertEqual(settings.contentTextSizePreference, .custom(150))
        XCTAssertEqual(settings.defaultZoomWindow, 50_000)
        XCTAssertEqual(settings.maxAnnotationRows, 100)
        XCTAssertEqual(settings.vcfImportProfile, "fast")
        XCTAssertEqual(settings.tooltipDelay, 0.5)
        XCTAssertTrue(settings.aiSearchEnabled)
        XCTAssertEqual(settings.openAIModel, "gpt-4-turbo")
        XCTAssertTrue(settings.openAIHostedEndpointEnabled)
        XCTAssertEqual(settings.openAIHostedEndpoint, "https://oc-aiservices.openai.azure.com")
        XCTAssertEqual(settings.openAIHostedDeployment, "gpt-5-mini")
        XCTAssertEqual(settings.provenanceSigningProvider, "local")
        XCTAssertEqual(settings.provenanceSigningPublicKeyPath, "/tmp/lungfish-provenance.pub")
        XCTAssertEqual(settings.analystIdentityOverride, "Dr. Ada Lovelace")
        XCTAssertEqual(settings.resolvedAnalystIdentity(fallback: "fallback analyst"), "Dr. Ada Lovelace")
        XCTAssertFalse(settings.experimentalFeaturesEnabled)
    }

    @MainActor
    func testOpenAIHostedEndpointConfigurationUsesAzureWhenEnabled() throws {
        let settings = AppSettings.shared
        settings.openAIHostedEndpointEnabled = true
        settings.openAIHostedEndpoint = "https://oc-aiservices.openai.azure.com/"
        settings.openAIHostedDeployment = "gpt-5-mini"

        let configuration = try settings.openAIEndpointConfiguration()

        XCTAssertEqual(
            configuration,
            .azure(
                endpoint: URL(string: "https://oc-aiservices.openai.azure.com")!,
                deployment: "gpt-5-mini"
            )
        )
    }

    @MainActor
    func testOpenAIHostedEndpointConfigurationUsesAzureV1URLs() throws {
        let settings = AppSettings.shared
        settings.openAIHostedEndpointEnabled = true
        settings.openAIHostedEndpoint = "https://oc-aiservices.cognitiveservices.azure.com/"
        settings.openAIHostedDeployment = "gpt-5-5"

        let configuration = try settings.openAIEndpointConfiguration()

        XCTAssertEqual(
            configuration,
            .azure(
                endpoint: URL(string: "https://oc-aiservices.cognitiveservices.azure.com")!,
                deployment: "gpt-5-5"
            )
        )
        XCTAssertEqual(configuration.chatCompletionsURL.absoluteString, "https://oc-aiservices.cognitiveservices.azure.com/openai/v1/chat/completions")
        XCTAssertEqual(configuration.responsesURL.absoluteString, "https://oc-aiservices.cognitiveservices.azure.com/openai/v1/responses")
    }

    @MainActor
    func testProvenanceSigningProviderNormalizesInvalidValues() {
        let invalidJSON = """
        {
          "provenanceSigningProvider": "unknown",
          "provenanceSigningPublicKeyPath": "   /tmp/key.pub   "
        }
        """
        defaults.set(invalidJSON.data(using: .utf8), forKey: "com.lungfish.appSettings")

        AppSettings.load()

        XCTAssertEqual(AppSettings.shared.provenanceSigningProvider, "off")
        XCTAssertEqual(AppSettings.shared.provenanceSigningPublicKeyPath, "/tmp/key.pub")
    }

    // MARK: - Reset

    @MainActor
    func testResetToDefaults() {
        let settings = AppSettings.shared
        settings.contentTextSizePreference = .custom(200)
        settings.maxAnnotationRows = 200
        settings.defaultZoomWindow = 99_999
        settings.aiSearchEnabled = true
        settings.analystIdentityOverride = "Dr. Ada Lovelace"
        settings.save()

        settings.resetToDefaults()
        XCTAssertEqual(settings.contentTextSizePreference, .system)
        XCTAssertEqual(settings.maxAnnotationRows, 50)
        XCTAssertEqual(settings.defaultZoomWindow, 10_000)
        XCTAssertFalse(settings.aiSearchEnabled)
        XCTAssertEqual(settings.analystIdentityOverride, "")
        XCTAssertEqual(settings.resolvedAnalystIdentity(fallback: "fallback analyst"), "fallback analyst")
    }

    @MainActor
    func testResetToDefaultsClearsManagedStorageBootstrapAndLegacyFallback() throws {
        let customRoot = URL(fileURLWithPath: "/tmp/custom-lungfish", isDirectory: true)
        let legacyKey = "DatabaseStorageLocation"
        defaults.set("/tmp/legacy-lungfish", forKey: legacyKey)
        try ManagedStorageConfigStore.shared.setActiveRoot(customRoot)

        AppSettings.shared.resetToDefaults()

        XCTAssertEqual(ManagedStorageConfigStore.shared.bootstrapConfigLoadState(), .missing)
        XCTAssertEqual(ManagedStorageConfigStore.shared.currentLocation().rootURL.standardizedFileURL.path, ManagedStorageConfigStore.shared.defaultLocation.rootURL.standardizedFileURL.path)
        XCTAssertNil(defaults.string(forKey: legacyKey))
    }

    @MainActor
    func testResetSection() {
        let settings = AppSettings.shared

        // Change values across multiple sections
        settings.contentTextSizePreference = .custom(175)
        settings.defaultZoomWindow = 50_000      // general
        settings.maxAnnotationRows = 200         // rendering
        settings.annotationTypeColorHexes["gene"] = "#FF0000"  // appearance
        settings.openAIHostedEndpointEnabled = true // aiServices
        settings.openAIHostedEndpoint = "https://oc-aiservices.openai.azure.com"
        settings.openAIHostedDeployment = "gpt-5-mini"
        settings.analystIdentityOverride = "Dr. Ada Lovelace"
        settings.experimentalFeaturesEnabled = !AppSettings.defaultExperimentalFeaturesEnabled // advanced

        // Reset only the general section
        settings.resetSection(.general)
        XCTAssertEqual(settings.defaultZoomWindow, 10_000, "General section should be reset")
        XCTAssertEqual(settings.maxAnnotationRows, 200, "Rendering section should be unchanged")
        XCTAssertEqual(settings.annotationTypeColorHexes["gene"], "#FF0000", "Appearance section should be unchanged")
        XCTAssertTrue(settings.openAIHostedEndpointEnabled, "AI Services section should be unchanged")
        XCTAssertEqual(settings.analystIdentityOverride, "", "General section should clear analyst identity")
        XCTAssertEqual(settings.experimentalFeaturesEnabled, !AppSettings.defaultExperimentalFeaturesEnabled, "Advanced section should be unchanged")

        // Reset rendering section
        settings.resetSection(.rendering)
        XCTAssertEqual(settings.maxAnnotationRows, 50, "Rendering section should be reset")

        // Reset appearance section
        settings.resetSection(.appearance)
        XCTAssertEqual(settings.contentTextSizePreference, .system)
        XCTAssertEqual(settings.annotationTypeColorHexes["gene"], "#339933", "Appearance section should be reset")

        // Reset AI Services section
        settings.resetSection(.aiServices)
        XCTAssertFalse(settings.openAIHostedEndpointEnabled, "AI Services section should be reset")
        XCTAssertEqual(settings.openAIHostedEndpoint, "")
        XCTAssertEqual(settings.openAIHostedDeployment, "")

        // Reset advanced section
        settings.resetSection(.advanced)
        XCTAssertEqual(settings.experimentalFeaturesEnabled, AppSettings.defaultExperimentalFeaturesEnabled, "Advanced section should be reset")
    }

    @MainActor
    func testResetStorageSectionClearsManagedStorageBootstrapAndLegacyFallback() throws {
        let customRoot = URL(fileURLWithPath: "/tmp/custom-lungfish", isDirectory: true)
        let legacyKey = "DatabaseStorageLocation"
        defaults.set("/tmp/legacy-lungfish", forKey: legacyKey)
        try ManagedStorageConfigStore.shared.setActiveRoot(customRoot)

        AppSettings.shared.resetSection(.storage)

        XCTAssertEqual(ManagedStorageConfigStore.shared.bootstrapConfigLoadState(), .missing)
        XCTAssertEqual(ManagedStorageConfigStore.shared.currentLocation().rootURL.standardizedFileURL.path, ManagedStorageConfigStore.shared.defaultLocation.rootURL.standardizedFileURL.path)
        XCTAssertNil(defaults.string(forKey: legacyKey))
    }

    @MainActor
    func testMalformedBootstrapIsSurfacedInManagedStorageDisplayState() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })
        store.overrideLegacyDefaultsForTesting(defaults)
        try FileManager.default.createDirectory(
            at: store.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: store.configURL, options: [.atomic])

        let previousStore = ManagedStorageConfigStore.shared
        ManagedStorageConfigStore.overrideSharedForTesting(store)
        defer { ManagedStorageConfigStore.overrideSharedForTesting(previousStore) }

        let settings = AppSettings.shared
        XCTAssertEqual(settings.managedStorageDisplayState, .malformedBootstrap)
        XCTAssertFalse(settings.isManagedStorageDefault)
        XCTAssertEqual(settings.managedStorageRootURL.standardizedFileURL.path, store.defaultLocation.rootURL.standardizedFileURL.path)
    }

    // MARK: - Decode Robustness

    @MainActor
    func testLoadFromPartialSnapshotUsesDefaultsForMissingFields() {
        let partialJSON = #"{"defaultZoomWindow":42000}"#
        defaults.set(partialJSON.data(using: .utf8), forKey: "com.lungfish.appSettings")

        AppSettings.load()

        let settings = AppSettings.shared
        XCTAssertEqual(settings.contentTextSizePreference, .system)
        XCTAssertEqual(settings.defaultZoomWindow, 42_000)
        XCTAssertEqual(settings.maxUndoLevels, 100)
        XCTAssertEqual(settings.vcfImportProfile, "auto")
        XCTAssertEqual(settings.variantColorThemeName, VariantColorTheme.modern.name)
        XCTAssertEqual(settings.horizontalScrollDirection, .traditional)
        XCTAssertEqual(settings.analystIdentityOverride, "")
        XCTAssertEqual(settings.resolvedAnalystIdentity(fallback: "fallback analyst"), "fallback analyst")
    }

    @MainActor
    func testLoadClampsInvalidPersistedValues() {
        let invalidJSON = """
        {
          "defaultZoomWindow": 9999999,
          "maxUndoLevels": -4,
          "vcfImportProfile": "invalid",
          "tempFileRetentionHours": -200,
          "variantColorThemeName": "Unknown Theme",
          "defaultAnnotationHeight": 999,
          "defaultAnnotationSpacing": -5,
          "maxAnnotationRows": 0,
          "sequenceFetchCapKb": 999999,
          "maxTableDisplayCount": 10,
          "densityThresholdBpPerPixel": 1,
          "squishedThresholdBpPerPixel": 999999,
          "showLettersThresholdBpPerPixel": 999,
          "tooltipDelay": 20,
          "contentTextSizePreference": 137
        }
        """
        defaults.set(invalidJSON.data(using: .utf8), forKey: "com.lungfish.appSettings")

        AppSettings.load()
        let settings = AppSettings.shared

        XCTAssertEqual(settings.contentTextSizePreference, .custom(125))
        XCTAssertEqual(settings.defaultZoomWindow, 1_000_000)
        XCTAssertEqual(settings.maxUndoLevels, 10)
        XCTAssertEqual(settings.vcfImportProfile, "auto")
        XCTAssertEqual(settings.tempFileRetentionHours, 1)
        XCTAssertEqual(settings.variantColorThemeName, VariantColorTheme.modern.name)
        XCTAssertEqual(settings.defaultAnnotationHeight, 32)
        XCTAssertEqual(settings.defaultAnnotationSpacing, 0)
        XCTAssertEqual(settings.maxAnnotationRows, 10)
        XCTAssertEqual(settings.sequenceFetchCapKb, 5_000)
        XCTAssertEqual(settings.maxTableDisplayCount, 1_000)
        XCTAssertEqual(settings.densityThresholdBpPerPixel, 10_000)
        XCTAssertEqual(settings.squishedThresholdBpPerPixel, 5_000)
        XCTAssertEqual(settings.showLettersThresholdBpPerPixel, 50)
        XCTAssertEqual(settings.tooltipDelay, 1.0)
    }

    // MARK: - Annotation Color Hex Helpers

    @MainActor
    func testAnnotationHexColorFromHex() {
        let color = AppSettings.hexColor(from: "#FF0000")

        XCTAssertEqual(color.hexString, "#FF0000")
        XCTAssertEqual(color.red, 1.0, accuracy: 0.01)
        XCTAssertEqual(color.green, 0.0, accuracy: 0.01)
        XCTAssertEqual(color.blue, 0.0, accuracy: 0.01)
    }

    @MainActor
    func testInvalidAnnotationHexColorFallsBackToGray() {
        let color = AppSettings.hexColor(from: "not-a-color")

        XCTAssertEqual(color.hexString, "#808080")
    }

    @MainActor
    func testAnnotationColorHexForType() {
        let settings = AppSettings.shared

        XCTAssertEqual(settings.annotationColorHex(for: .gene), "#339933")
        XCTAssertEqual(settings.annotationHexColor(for: .gene).hexString, "#339933")
    }

    @MainActor
    func testDefaultAnnotationTypeColorsMatchExpected() {
        let defaults = AppSettings.defaultAnnotationTypeColorHexes
        XCTAssertEqual(defaults["gene"], "#339933")
        XCTAssertEqual(defaults["CDS"], "#3366CC")
        XCTAssertEqual(defaults["exon"], "#994DCC")
        XCTAssertEqual(defaults["mRNA"], "#CC6633")
        XCTAssertEqual(defaults["transcript"], "#B38050")
        XCTAssertEqual(defaults["misc_feature"], "#808080")
        XCTAssertEqual(defaults["region"], "#66B3B3")
        XCTAssertEqual(defaults["primer"], "#33CC33")
        XCTAssertEqual(defaults["restriction_site"], "#CC3333")
    }

    // MARK: - Notification

    @MainActor
    func testSavePostsNotification() {
        let expectation = expectation(forNotification: .appSettingsChanged, object: nil)
        AppSettings.shared.maxAnnotationRows = 99
        AppSettings.shared.save()
        wait(for: [expectation], timeout: 1.0)
    }

    @MainActor
    func testSavePostsAppearanceNotification() {
        let expectation = expectation(forNotification: .appearanceChanged, object: nil)
        AppSettings.shared.annotationTypeColorHexes["gene"] = "#FF0000"
        AppSettings.shared.save()
        wait(for: [expectation], timeout: 1.0)
    }

    @MainActor
    func testContentTextSizeSupportedStopsAndNavigation() {
        XCTAssertEqual(ContentTextSizePreference.supportedPercentages, [90, 100, 125, 150, 175, 200])
        XCTAssertEqual(ContentTextSizePreference.system.larger, .custom(125))
        XCTAssertEqual(ContentTextSizePreference.system.smaller, .custom(90))
        XCTAssertEqual(ContentTextSizePreference.custom(125).larger, .custom(150))
        XCTAssertEqual(ContentTextSizePreference.custom(125).smaller, .custom(100))
        XCTAssertEqual(ContentTextSizePreference.custom(200).larger, .custom(200))
        XCTAssertEqual(ContentTextSizePreference.custom(90).smaller, .custom(90))
    }

    @MainActor
    func testContentTextSizeNotificationPostsOnlyForNormalizedPreferenceChange() {
        let notifications = AppSettingsNotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                notifications.count += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        AppSettings.shared.maxAnnotationRows = 99
        AppSettings.shared.save()
        XCTAssertEqual(notifications.count, 0)

        AppSettings.shared.contentTextSizePreference = .custom(137)
        AppSettings.shared.save()
        XCTAssertEqual(AppSettings.shared.contentTextSizePreference, .custom(125))
        XCTAssertEqual(notifications.count, 1)

        AppSettings.shared.contentTextSizePreference = .custom(126)
        AppSettings.shared.save()
        XCTAssertEqual(AppSettings.shared.contentTextSizePreference, .custom(125))
        XCTAssertEqual(notifications.count, 1)
    }
}

@MainActor
private final class AppSettingsNotificationCounter {
    var count = 0
}
