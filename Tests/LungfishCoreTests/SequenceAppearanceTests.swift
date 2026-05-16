// SequenceAppearanceTests.swift - Unit tests for SequenceAppearance struct
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class SequenceAppearanceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = SequenceAppearance.resetToDefaults()
    }

    override func tearDown() {
        _ = SequenceAppearance.resetToDefaults()
        super.tearDown()
    }

    func testDefaultBaseColorsUseStablePersistedHexStrings() {
        let appearance = SequenceAppearance.default

        XCTAssertEqual(appearance.baseColors["A"], "#00CC00")
        XCTAssertEqual(appearance.baseColors["T"], "#CC0000")
        XCTAssertEqual(appearance.baseColors["G"], "#FFB300")
        XCTAssertEqual(appearance.baseColors["C"], "#0000CC")
        XCTAssertEqual(appearance.baseColors["N"], "#888888")
        XCTAssertEqual(appearance.baseColors["U"], "#CC0000")
        XCTAssertEqual(appearance.trackHeight, 20.0)
        XCTAssertFalse(appearance.showQualityOverlay)
    }

    func testColorForBaseReturnsFoundationHexColor() {
        let appearance = SequenceAppearance.default

        XCTAssertEqual(appearance.color(forBase: "A"), HexColor(red: 0.0, green: 0.8, blue: 0.0))
        XCTAssertEqual(appearance.color(forBase: "T").hexString, "#CC0000")
        XCTAssertEqual(appearance.color(forBase: "G").hexString, "#FFB300")
        XCTAssertEqual(appearance.color(forBase: "C").hexString, "#0000CC")
        XCTAssertEqual(appearance.color(forBase: "N").hexString, "#888888")
    }

    func testColorForBaseNormalizesLowercaseBases() {
        let appearance = SequenceAppearance.default

        XCTAssertEqual(appearance.color(forBase: "a"), appearance.color(forBase: "A"))
        XCTAssertEqual(appearance.color(forBase: "u"), appearance.color(forBase: "U"))
    }

    func testUnknownOrInvalidBaseColorsReturnGrayFallback() {
        var appearance = SequenceAppearance.default
        appearance.baseColors["A"] = "invalid"

        XCTAssertEqual(appearance.color(forBase: "A").hexString, "#808080")
        XCTAssertEqual(appearance.color(forBase: "X").hexString, "#808080")
    }

    func testSetColorStoresCanonicalHexString() {
        var appearance = SequenceAppearance.default

        appearance.setColor(HexColor(red: 0.5, green: 0.0, blue: 0.5), forBase: "a")

        XCTAssertEqual(appearance.baseColors["A"], "#800080")
        XCTAssertEqual(appearance.color(forBase: "A").hexString, "#800080")
    }

    func testHexColorParsesPersistedFormats() throws {
        XCTAssertEqual(try HexColor(hex: "#FF5500").hexString, "#FF5500")
        XCTAssertEqual(try HexColor(hex: "00FF00").hexString, "#00FF00")
        XCTAssertEqual(try HexColor(hex: "#F00").hexString, "#FF0000")
        XCTAssertEqual(try HexColor(hex: "0F0").hexString, "#00FF00")
        XCTAssertEqual(try HexColor(hex: "  #336699  ").hexString, "#336699")
    }

    func testHexColorCodableRoundTripPreservesComponents() throws {
        let original = HexColor(red: 0.2, green: 0.4, blue: 0.6)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HexColor.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.hexString, "#336699")
    }

    func testSaveAndLoadPreservesExistingSequenceAppearancePersistenceShape() {
        var appearance = SequenceAppearance.default
        appearance.trackHeight = 75.0
        appearance.showQualityOverlay = true
        appearance.setColor(HexColor(red: 0.9, green: 0.1, blue: 0.1), forBase: "A")

        appearance.save()
        let loaded = SequenceAppearance.load()

        XCTAssertEqual(loaded.trackHeight, 75.0)
        XCTAssertTrue(loaded.showQualityOverlay)
        XCTAssertEqual(loaded.baseColors["A"], "#E61A1A")
        XCTAssertEqual(loaded.color(forBase: "A").hexString, "#E61A1A")
    }

    func testLoadReturnsDefaultWhenNoSavedData() {
        _ = SequenceAppearance.resetToDefaults()

        let loaded = SequenceAppearance.load()

        XCTAssertEqual(loaded.trackHeight, 20.0)
        XCTAssertFalse(loaded.showQualityOverlay)
        XCTAssertEqual(loaded.baseColors, SemanticColors.DNA.defaultHexColors)
    }

    func testResetToDefaultsClearsSavedSettings() {
        var appearance = SequenceAppearance.default
        appearance.trackHeight = 100.0
        appearance.showQualityOverlay = true
        appearance.save()

        let resetAppearance = SequenceAppearance.resetToDefaults()
        let loadedAfterReset = SequenceAppearance.load()

        XCTAssertEqual(resetAppearance, .default)
        XCTAssertEqual(loadedAfterReset, .default)
    }

    func testEquatableAndHashableUseStoredValues() {
        let appearance1 = SequenceAppearance.default
        var appearance2 = SequenceAppearance.default
        appearance2.trackHeight = 100.0

        XCTAssertNotEqual(appearance1, appearance2)
        XCTAssertEqual(Set([appearance1, SequenceAppearance.default, appearance2]).count, 2)
    }

    func testCodablePreservesAllBaseColors() throws {
        let original = SequenceAppearance.default
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SequenceAppearance.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.baseColors.count, original.baseColors.count)
    }

    func testSequenceAppearanceIsSendable() {
        let expectation = XCTestExpectation(description: "Sendable test")

        Task {
            let appearance = SequenceAppearance.default
            XCTAssertEqual(appearance.trackHeight, 20.0)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }
}
