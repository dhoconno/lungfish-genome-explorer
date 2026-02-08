// SequenceAppearanceTests.swift - Unit tests for SequenceAppearance struct
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishCore

final class SequenceAppearanceTests: XCTestCase {

    // MARK: - Test Constants

    /// Unique UserDefaults key for testing to avoid conflicts with production settings
    private static let testUserDefaultsKey = "SequenceAppearance_TestSuite"

    // MARK: - Setup and Teardown

    override func setUp() {
        super.setUp()
        // Clean up any existing test data before each test
        UserDefaults.standard.removeObject(forKey: Self.testUserDefaultsKey)
        // Also reset the production key to ensure clean state
        _ = SequenceAppearance.resetToDefaults()
    }

    override func tearDown() {
        // Clean up after each test
        UserDefaults.standard.removeObject(forKey: Self.testUserDefaultsKey)
        _ = SequenceAppearance.resetToDefaults()
        super.tearDown()
    }

    // MARK: - Default Appearance Tests

    func testDefaultAppearanceExists() {
        let appearance = SequenceAppearance.default

        XCTAssertNotNil(appearance)
    }

    func testDefaultTrackHeight() {
        let appearance = SequenceAppearance.default

        XCTAssertEqual(appearance.trackHeight, 20.0)  // Updated default from 50 to 28
    }

    func testDefaultShowQualityOverlay() {
        let appearance = SequenceAppearance.default

        XCTAssertFalse(appearance.showQualityOverlay)
    }

    func testDefaultBaseColorsContainsAllBases() {
        let appearance = SequenceAppearance.default

        XCTAssertNotNil(appearance.baseColors["A"])
        XCTAssertNotNil(appearance.baseColors["T"])
        XCTAssertNotNil(appearance.baseColors["G"])
        XCTAssertNotNil(appearance.baseColors["C"])
        XCTAssertNotNil(appearance.baseColors["N"])
        XCTAssertNotNil(appearance.baseColors["U"])
    }

    func testDefaultAdenineColor() {
        let appearance = SequenceAppearance.default

        // A (Adenine): Green (#00A000)
        XCTAssertEqual(appearance.baseColors["A"], "#00A000")
    }

    func testDefaultThymineColor() {
        let appearance = SequenceAppearance.default

        // T (Thymine): Red (#FF0000)
        XCTAssertEqual(appearance.baseColors["T"], "#FF0000")
    }

    func testDefaultGuanineColor() {
        let appearance = SequenceAppearance.default

        // G (Guanine): Yellow/Gold (#FFD700)
        XCTAssertEqual(appearance.baseColors["G"], "#FFD700")
    }

    func testDefaultCytosineColor() {
        let appearance = SequenceAppearance.default

        // C (Cytosine): Blue (#0000FF)
        XCTAssertEqual(appearance.baseColors["C"], "#0000FF")
    }

    func testDefaultUnknownBaseColor() {
        let appearance = SequenceAppearance.default

        // N (Unknown): Gray (#808080)
        XCTAssertEqual(appearance.baseColors["N"], "#808080")
    }

    func testDefaultUracilColor() {
        let appearance = SequenceAppearance.default

        // U (Uracil): Same as T (#FF0000)
        XCTAssertEqual(appearance.baseColors["U"], "#FF0000")
    }

    // MARK: - Color For Base Tests

    func testColorForBaseAdenine() {
        let appearance = SequenceAppearance.default

        let color = appearance.color(forBase: "A")

        // Verify color is approximately green (RGB: 0, 160, 0)
        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }
        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 0)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 160)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 0)
    }

    func testColorForBaseThymine() {
        let appearance = SequenceAppearance.default

        let color = appearance.color(forBase: "T")

        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }
        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 255)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 0)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 0)
    }

    func testColorForBaseGuanine() {
        let appearance = SequenceAppearance.default

        let color = appearance.color(forBase: "G")

        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }
        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 255)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 215)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 0)
    }

    func testColorForBaseCytosine() {
        let appearance = SequenceAppearance.default

        let color = appearance.color(forBase: "C")

        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }
        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 0)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 0)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 255)
    }

    func testColorForBaseUnknown() {
        let appearance = SequenceAppearance.default

        let color = appearance.color(forBase: "N")

        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }
        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 128)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 128)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 128)
    }

    func testColorForBaseLowercase() {
        let appearance = SequenceAppearance.default

        // Lowercase should be converted to uppercase
        let colorLower = appearance.color(forBase: "a")
        let colorUpper = appearance.color(forBase: "A")

        guard let rgbLower = colorLower.usingColorSpace(.sRGB),
              let rgbUpper = colorUpper.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert colors to sRGB")
            return
        }

        XCTAssertEqual(rgbLower.redComponent, rgbUpper.redComponent, accuracy: 0.01)
        XCTAssertEqual(rgbLower.greenComponent, rgbUpper.greenComponent, accuracy: 0.01)
        XCTAssertEqual(rgbLower.blueComponent, rgbUpper.blueComponent, accuracy: 0.01)
    }

    func testColorForUnknownBaseReturnsFallback() {
        let appearance = SequenceAppearance.default

        // Unknown base should return gray fallback
        let color = appearance.color(forBase: "X")

        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }
        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 128)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 128)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 128)
    }

    // MARK: - Set Color Tests

    func testSetColorUpdatesBaseColor() {
        var appearance = SequenceAppearance.default

        let purpleColor = NSColor(srgbRed: 0.5, green: 0.0, blue: 0.5, alpha: 1.0)
        appearance.setColor(purpleColor, forBase: "A")

        let retrievedColor = appearance.color(forBase: "A")
        guard let rgb = retrievedColor.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }

        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 128)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 0)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 128)
    }

    func testSetColorForLowercaseBase() {
        var appearance = SequenceAppearance.default

        let orangeColor = NSColor(srgbRed: 1.0, green: 0.5, blue: 0.0, alpha: 1.0)
        appearance.setColor(orangeColor, forBase: "t")  // Lowercase

        // Should be stored as uppercase
        XCTAssertNotNil(appearance.baseColors["T"])

        let retrievedColor = appearance.color(forBase: "T")
        guard let rgb = retrievedColor.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }

        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 255)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 128)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 0)
    }

    func testSetColorForNewBase() {
        var appearance = SequenceAppearance.default

        let customColor = NSColor(srgbRed: 0.25, green: 0.75, blue: 0.5, alpha: 1.0)
        appearance.setColor(customColor, forBase: "Z")

        XCTAssertNotNil(appearance.baseColors["Z"])
    }

    // MARK: - Hex Color Conversion Tests

    func testHexColorConversionRoundTrip() {
        var appearance = SequenceAppearance.default

        // Set a specific color
        let originalColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1.0)
        appearance.setColor(originalColor, forBase: "A")

        // Retrieve the color
        let retrievedColor = appearance.color(forBase: "A")

        // Compare within rounding tolerance
        guard let originalRGB = originalColor.usingColorSpace(.sRGB),
              let retrievedRGB = retrievedColor.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert colors to sRGB")
            return
        }

        XCTAssertEqual(originalRGB.redComponent, retrievedRGB.redComponent, accuracy: 0.01)
        XCTAssertEqual(originalRGB.greenComponent, retrievedRGB.greenComponent, accuracy: 0.01)
        XCTAssertEqual(originalRGB.blueComponent, retrievedRGB.blueComponent, accuracy: 0.01)
    }

    func testHexColorParsingWithHash() {
        var appearance = SequenceAppearance.default
        appearance.baseColors["A"] = "#FF5500"

        let color = appearance.color(forBase: "A")
        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }

        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 255)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 85)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 0)
    }

    func testHexColorParsingWithoutHash() {
        var appearance = SequenceAppearance.default
        appearance.baseColors["A"] = "00FF00"

        let color = appearance.color(forBase: "A")
        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }

        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 0)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 255)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 0)
    }

    func testHexColorParsing3DigitWithHash() {
        var appearance = SequenceAppearance.default
        appearance.baseColors["A"] = "#F00"  // Shorthand for FF0000

        let color = appearance.color(forBase: "A")
        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }

        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 255)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 0)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 0)
    }

    func testHexColorParsing3DigitWithoutHash() {
        var appearance = SequenceAppearance.default
        appearance.baseColors["A"] = "0F0"  // Shorthand for 00FF00

        let color = appearance.color(forBase: "A")
        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }

        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 0)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 255)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 0)
    }

    func testInvalidHexColorReturnsFallback() {
        var appearance = SequenceAppearance.default
        appearance.baseColors["A"] = "invalid"

        let color = appearance.color(forBase: "A")
        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }

        // Should return gray fallback
        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 128)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 128)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 128)
    }

    func testHexColorParsingWithWhitespace() {
        var appearance = SequenceAppearance.default
        appearance.baseColors["A"] = "  #FF0000  "

        let color = appearance.color(forBase: "A")
        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }

        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 255)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 0)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 0)
    }

    // MARK: - Persistence Tests

    func testSaveAndLoad() {
        // Create a custom appearance
        var appearance = SequenceAppearance.default
        appearance.trackHeight = 75.0
        appearance.showQualityOverlay = true
        let customColor = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1.0)
        appearance.setColor(customColor, forBase: "A")

        // Save it
        appearance.save()

        // Load it
        let loaded = SequenceAppearance.load()

        XCTAssertEqual(loaded.trackHeight, 75.0)
        XCTAssertTrue(loaded.showQualityOverlay)

        // Verify the custom color was persisted
        let loadedColor = loaded.color(forBase: "A")
        guard let rgb = loadedColor.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }
        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 230)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 26)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 26)
    }

    func testLoadReturnsDefaultWhenNoSavedData() {
        // Ensure no saved data exists
        _ = SequenceAppearance.resetToDefaults()

        let loaded = SequenceAppearance.load()

        XCTAssertEqual(loaded.trackHeight, 20.0)  // Default track height
        XCTAssertFalse(loaded.showQualityOverlay)
    }

    func testResetToDefaultsClearsSavedSettings() {
        // Save custom settings
        var appearance = SequenceAppearance.default
        appearance.trackHeight = 100.0
        appearance.showQualityOverlay = true
        appearance.save()

        // Verify it was saved
        let savedAppearance = SequenceAppearance.load()
        XCTAssertEqual(savedAppearance.trackHeight, 100.0)

        // Reset to defaults
        let resetAppearance = SequenceAppearance.resetToDefaults()

        // Verify reset returns default values
        XCTAssertEqual(resetAppearance.trackHeight, 20.0)  // Default track height
        XCTAssertFalse(resetAppearance.showQualityOverlay)

        // Verify load returns defaults after reset
        let loadedAfterReset = SequenceAppearance.load()
        XCTAssertEqual(loadedAfterReset.trackHeight, 20.0)  // Default track height
        XCTAssertFalse(loadedAfterReset.showQualityOverlay)
    }

    func testMultipleSaveOverwrites() {
        var appearance1 = SequenceAppearance.default
        appearance1.trackHeight = 60.0
        appearance1.save()

        var appearance2 = SequenceAppearance.default
        appearance2.trackHeight = 80.0
        appearance2.save()

        let loaded = SequenceAppearance.load()
        XCTAssertEqual(loaded.trackHeight, 80.0)
    }

    // MARK: - Equatable Tests

    func testEqualityWithSameValues() {
        let appearance1 = SequenceAppearance.default
        let appearance2 = SequenceAppearance.default

        XCTAssertEqual(appearance1, appearance2)
    }

    func testInequalityWithDifferentTrackHeight() {
        let appearance1 = SequenceAppearance.default
        var appearance2 = SequenceAppearance.default
        appearance2.trackHeight = 100.0

        XCTAssertNotEqual(appearance1, appearance2)
    }

    func testInequalityWithDifferentShowQualityOverlay() {
        let appearance1 = SequenceAppearance.default
        var appearance2 = SequenceAppearance.default
        appearance2.showQualityOverlay = true

        XCTAssertNotEqual(appearance1, appearance2)
    }

    func testInequalityWithDifferentBaseColors() {
        let appearance1 = SequenceAppearance.default
        var appearance2 = SequenceAppearance.default
        appearance2.baseColors["A"] = "#FFFFFF"

        XCTAssertNotEqual(appearance1, appearance2)
    }

    // MARK: - Hashable Tests

    func testHashableConsistency() {
        let appearance1 = SequenceAppearance.default
        let appearance2 = SequenceAppearance.default

        XCTAssertEqual(appearance1.hashValue, appearance2.hashValue)
    }

    func testHashableInSet() {
        let appearance1 = SequenceAppearance.default
        var appearance2 = SequenceAppearance.default
        appearance2.trackHeight = 100.0

        var set = Set<SequenceAppearance>()
        set.insert(appearance1)
        set.insert(appearance2)

        XCTAssertEqual(set.count, 2)
    }

    func testHashableDuplicateInSet() {
        let appearance1 = SequenceAppearance.default
        let appearance2 = SequenceAppearance.default

        var set = Set<SequenceAppearance>()
        set.insert(appearance1)
        set.insert(appearance2)

        XCTAssertEqual(set.count, 1)
    }

    // MARK: - Codable Tests

    func testCodableRoundTrip() throws {
        var original = SequenceAppearance.default
        original.trackHeight = 75.0
        original.showQualityOverlay = true
        original.setColor(NSColor.systemPurple, forBase: "A")

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SequenceAppearance.self, from: data)

        XCTAssertEqual(decoded.trackHeight, 75.0)
        XCTAssertTrue(decoded.showQualityOverlay)
    }

    func testCodablePreservesAllBaseColors() throws {
        let original = SequenceAppearance.default

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SequenceAppearance.self, from: data)

        XCTAssertEqual(decoded.baseColors.count, original.baseColors.count)
        for (key, value) in original.baseColors {
            XCTAssertEqual(decoded.baseColors[key], value)
        }
    }

    // MARK: - Sendable Tests

    func testSequenceAppearanceIsSendable() {
        let expectation = XCTestExpectation(description: "Sendable test")

        Task {
            let appearance = SequenceAppearance.default
            XCTAssertEqual(appearance.trackHeight, 20.0)  // Updated default from 50 to 28
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Initialization Tests

    func testCustomInitialization() {
        let customColors = [
            "A": "#112233",
            "T": "#445566",
            "G": "#778899",
            "C": "#AABBCC"
        ]

        let appearance = SequenceAppearance(
            baseColors: customColors,
            trackHeight: 100.0,
            showQualityOverlay: true
        )

        XCTAssertEqual(appearance.baseColors["A"], "#112233")
        XCTAssertEqual(appearance.trackHeight, 100.0)
        XCTAssertTrue(appearance.showQualityOverlay)
    }

    // MARK: - Edge Cases

    func testTrackHeightZero() {
        var appearance = SequenceAppearance.default
        appearance.trackHeight = 0.0

        XCTAssertEqual(appearance.trackHeight, 0.0)
    }

    func testTrackHeightNegative() {
        var appearance = SequenceAppearance.default
        appearance.trackHeight = -10.0

        // No validation, so negative values are allowed
        XCTAssertEqual(appearance.trackHeight, -10.0)
    }

    func testTrackHeightVeryLarge() {
        var appearance = SequenceAppearance.default
        appearance.trackHeight = 10000.0

        XCTAssertEqual(appearance.trackHeight, 10000.0)
    }

    func testEmptyBaseColors() {
        let appearance = SequenceAppearance(
            baseColors: [:],
            trackHeight: 50.0,
            showQualityOverlay: false
        )

        // Unknown bases should still return gray fallback
        let color = appearance.color(forBase: "A")
        guard let rgb = color.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert color to sRGB")
            return
        }
        XCTAssertEqual(Int(round(rgb.redComponent * 255)), 128)
        XCTAssertEqual(Int(round(rgb.greenComponent * 255)), 128)
        XCTAssertEqual(Int(round(rgb.blueComponent * 255)), 128)
    }
}
