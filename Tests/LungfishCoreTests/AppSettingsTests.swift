// AppSettingsTests.swift - Tests for centralized application preferences
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

@MainActor private var appSettingsTestsOriginalManagedStorageStore: ManagedStorageConfigStore?
@MainActor private var appSettingsTestsManagedStorageHomeDirectory: URL?

final class AppSettingsTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        MainActor.assumeIsolated {
            // Clear any persisted settings before each test
            UserDefaults.standard.removeObject(forKey: "com.lungfish.appSettings")
            // Reset shared instance to defaults
            AppSettings.shared.resetToDefaults()

            appSettingsTestsOriginalManagedStorageStore = ManagedStorageConfigStore.shared
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            appSettingsTestsManagedStorageHomeDirectory = home
            ManagedStorageConfigStore.shared = ManagedStorageConfigStore(homeDirectory: home)
        }
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated {
            ManagedStorageConfigStore.shared = appSettingsTestsOriginalManagedStorageStore ?? ManagedStorageConfigStore()
            if let managedStorageHomeDirectory = appSettingsTestsManagedStorageHomeDirectory {
                try? FileManager.default.removeItem(at: managedStorageHomeDirectory)
            }
            appSettingsTestsManagedStorageHomeDirectory = nil
            appSettingsTestsOriginalManagedStorageStore = nil
        }
        try super.tearDownWithError()
    }

    // MARK: - Default Values

    @MainActor
    func testDefaultValues() {
        let settings = AppSettings.shared
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
        XCTAssertEqual(settings.defaultAnnotationHeight, 16)
        XCTAssertEqual(settings.defaultAnnotationSpacing, 2)
        XCTAssertEqual(settings.horizontalScrollDirection, .traditional)
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
        settings.defaultZoomWindow = 50_000
        settings.maxAnnotationRows = 100
        settings.vcfImportProfile = "fast"
        settings.tooltipDelay = 0.5
        settings.aiSearchEnabled = true
        settings.openAIModel = "gpt-4-turbo"
        settings.save()

        // Reset in-memory state
        settings.resetToDefaults()
        XCTAssertEqual(settings.defaultZoomWindow, 10_000)
        XCTAssertEqual(settings.maxAnnotationRows, 50)

        // Load from UserDefaults
        AppSettings.load()
        XCTAssertEqual(settings.defaultZoomWindow, 50_000)
        XCTAssertEqual(settings.maxAnnotationRows, 100)
        XCTAssertEqual(settings.vcfImportProfile, "fast")
        XCTAssertEqual(settings.tooltipDelay, 0.5)
        XCTAssertTrue(settings.aiSearchEnabled)
        XCTAssertEqual(settings.openAIModel, "gpt-4-turbo")
    }

    // MARK: - Reset

    @MainActor
    func testResetToDefaults() {
        let settings = AppSettings.shared
        settings.maxAnnotationRows = 200
        settings.defaultZoomWindow = 99_999
        settings.aiSearchEnabled = true
        settings.save()

        settings.resetToDefaults()
        XCTAssertEqual(settings.maxAnnotationRows, 50)
        XCTAssertEqual(settings.defaultZoomWindow, 10_000)
        XCTAssertFalse(settings.aiSearchEnabled)
    }

    @MainActor
    func testResetToDefaultsClearsManagedStorageBootstrapAndLegacyFallback() throws {
        let customRoot = URL(fileURLWithPath: "/tmp/custom-lungfish", isDirectory: true)
        let legacyKey = "DatabaseStorageLocation"
        UserDefaults.standard.set("/tmp/legacy-lungfish", forKey: legacyKey)
        try ManagedStorageConfigStore.shared.setActiveRoot(customRoot)

        AppSettings.shared.resetToDefaults()

        XCTAssertEqual(ManagedStorageConfigStore.shared.bootstrapConfigLoadState(), .missing)
        XCTAssertEqual(ManagedStorageConfigStore.shared.currentLocation().rootURL.standardizedFileURL.path, ManagedStorageConfigStore.shared.defaultLocation.rootURL.standardizedFileURL.path)
        XCTAssertNil(UserDefaults.standard.string(forKey: legacyKey))
    }

    @MainActor
    func testResetSection() {
        let settings = AppSettings.shared

        // Change values across multiple sections
        settings.defaultZoomWindow = 50_000      // general
        settings.maxAnnotationRows = 200         // rendering
        settings.annotationTypeColorHexes["gene"] = "#FF0000"  // appearance

        // Reset only the general section
        settings.resetSection(.general)
        XCTAssertEqual(settings.defaultZoomWindow, 10_000, "General section should be reset")
        XCTAssertEqual(settings.maxAnnotationRows, 200, "Rendering section should be unchanged")
        XCTAssertEqual(settings.annotationTypeColorHexes["gene"], "#FF0000", "Appearance section should be unchanged")

        // Reset rendering section
        settings.resetSection(.rendering)
        XCTAssertEqual(settings.maxAnnotationRows, 50, "Rendering section should be reset")

        // Reset appearance section
        settings.resetSection(.appearance)
        XCTAssertEqual(settings.annotationTypeColorHexes["gene"], "#339933", "Appearance section should be reset")
    }

    @MainActor
    func testResetStorageSectionClearsManagedStorageBootstrapAndLegacyFallback() throws {
        let customRoot = URL(fileURLWithPath: "/tmp/custom-lungfish", isDirectory: true)
        let legacyKey = "DatabaseStorageLocation"
        UserDefaults.standard.set("/tmp/legacy-lungfish", forKey: legacyKey)
        try ManagedStorageConfigStore.shared.setActiveRoot(customRoot)

        AppSettings.shared.resetSection(.storage)

        XCTAssertEqual(ManagedStorageConfigStore.shared.bootstrapConfigLoadState(), .missing)
        XCTAssertEqual(ManagedStorageConfigStore.shared.currentLocation().rootURL.standardizedFileURL.path, ManagedStorageConfigStore.shared.defaultLocation.rootURL.standardizedFileURL.path)
        XCTAssertNil(UserDefaults.standard.string(forKey: legacyKey))
    }

    @MainActor
    func testMalformedBootstrapIsSurfacedInManagedStorageDisplayState() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = ManagedStorageConfigStore(homeDirectory: home)
        try FileManager.default.createDirectory(
            at: store.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: store.configURL, options: [.atomic])

        let originalStore = ManagedStorageConfigStore.shared
        ManagedStorageConfigStore.shared = store
        defer { ManagedStorageConfigStore.shared = originalStore }

        let settings = AppSettings.shared
        XCTAssertEqual(settings.managedStorageDisplayState, .malformedBootstrap)
        XCTAssertFalse(settings.isManagedStorageDefault)
        XCTAssertEqual(settings.managedStorageRootURL.standardizedFileURL.path, store.defaultLocation.rootURL.standardizedFileURL.path)
    }

    // MARK: - Decode Robustness

    @MainActor
    func testLoadFromPartialSnapshotUsesDefaultsForMissingFields() {
        let partialJSON = #"{"defaultZoomWindow":42000}"#
        UserDefaults.standard.set(partialJSON.data(using: .utf8), forKey: "com.lungfish.appSettings")

        AppSettings.load()

        let settings = AppSettings.shared
        XCTAssertEqual(settings.defaultZoomWindow, 42_000)
        XCTAssertEqual(settings.maxUndoLevels, 100)
        XCTAssertEqual(settings.vcfImportProfile, "auto")
        XCTAssertEqual(settings.variantColorThemeName, VariantColorTheme.modern.name)
        XCTAssertEqual(settings.horizontalScrollDirection, .traditional)
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
          "tooltipDelay": 20
        }
        """
        UserDefaults.standard.set(invalidJSON.data(using: .utf8), forKey: "com.lungfish.appSettings")

        AppSettings.load()
        let settings = AppSettings.shared

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

    // MARK: - Annotation Color Helpers

    @MainActor
    func testAnnotationColorFromHex() {
        let color = AppSettings.color(from: "#FF0000")
        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert to sRGB")
            return
        }
        XCTAssertEqual(rgb.redComponent, 1.0, accuracy: 0.01)
        XCTAssertEqual(rgb.greenComponent, 0.0, accuracy: 0.01)
        XCTAssertEqual(rgb.blueComponent, 0.0, accuracy: 0.01)
    }

    @MainActor
    func testHexStringFromColor() {
        let color = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.2, alpha: 1.0)
        let hex = AppSettings.hexString(from: color)
        XCTAssertEqual(hex, "#339933")
    }

    @MainActor
    func testAnnotationColorForType() {
        let settings = AppSettings.shared
        let geneColor = settings.annotationColor(for: .gene)
        guard let rgb = geneColor.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert to sRGB")
            return
        }
        // Default gene color is #339933
        XCTAssertEqual(rgb.redComponent, 0.2, accuracy: 0.01)
        XCTAssertEqual(rgb.greenComponent, 0.6, accuracy: 0.01)
        XCTAssertEqual(rgb.blueComponent, 0.2, accuracy: 0.01)
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
}
