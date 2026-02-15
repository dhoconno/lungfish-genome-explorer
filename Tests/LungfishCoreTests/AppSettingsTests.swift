// AppSettingsTests.swift - Tests for centralized application preferences
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

@MainActor
final class AppSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear any persisted settings before each test
        UserDefaults.standard.removeObject(forKey: "com.lungfish.appSettings")
        UserDefaults.standard.removeObject(forKey: "SequenceAppearance")
        UserDefaults.standard.removeObject(forKey: "VCFImportProfile")
        // Reset shared instance to defaults
        AppSettings.shared.resetToDefaults()
    }

    // MARK: - Default Values

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
    }

    // MARK: - Save/Load Roundtrip

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

    // MARK: - Legacy Migration

    func testMigratesLegacySequenceAppearance() {
        // Save a SequenceAppearance under the legacy key
        var customAppearance = SequenceAppearance.default
        customAppearance.trackHeight = 42.0
        customAppearance.save()  // Saves under "SequenceAppearance" key

        // Ensure no new settings key exists
        UserDefaults.standard.removeObject(forKey: "com.lungfish.appSettings")

        // Load should migrate
        AppSettings.load()
        XCTAssertEqual(AppSettings.shared.sequenceAppearance.trackHeight, 42.0,
                       "Should migrate legacy SequenceAppearance")
    }

    func testMigratesLegacyVCFImportProfile() {
        // Set legacy VCF import profile
        UserDefaults.standard.set("lowMemory", forKey: "VCFImportProfile")
        UserDefaults.standard.removeObject(forKey: "com.lungfish.appSettings")

        AppSettings.load()
        XCTAssertEqual(AppSettings.shared.vcfImportProfile, "lowMemory",
                       "Should migrate legacy VCFImportProfile")
    }

    // MARK: - Annotation Color Helpers

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

    func testHexStringFromColor() {
        let color = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.2, alpha: 1.0)
        let hex = AppSettings.hexString(from: color)
        XCTAssertEqual(hex, "#339933")
    }

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

    func testSavePostsNotification() {
        let expectation = expectation(forNotification: .appSettingsChanged, object: nil)
        AppSettings.shared.maxAnnotationRows = 99
        AppSettings.shared.save()
        wait(for: [expectation], timeout: 1.0)
    }

    func testSavePostsAppearanceNotification() {
        let expectation = expectation(forNotification: .appearanceChanged, object: nil)
        AppSettings.shared.annotationTypeColorHexes["gene"] = "#FF0000"
        AppSettings.shared.save()
        wait(for: [expectation], timeout: 1.0)
    }
}
