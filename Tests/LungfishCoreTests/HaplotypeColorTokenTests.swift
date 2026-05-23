import XCTest
@testable import LungfishCore

final class HaplotypeColorTokenTests: XCTestCase {
    func testCanonicalPaletteHasEightTokens() {
        let palette = HaplotypeColorToken.canonicalPalette
        XCTAssertEqual(palette.count, 8)
    }

    func testMCMNameAssignmentIsCanonical() {
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M1A").canonicalIndex, 1)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M3DR").canonicalIndex, 3)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M7B").canonicalIndex, 7)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "-").canonicalIndex, 0)
    }

    func testUnknownNameUsesHashedAssignment() {
        let token = HaplotypeColorToken.assigned(forName: "Mamu-A1*004:01:01")
        XCTAssertGreaterThanOrEqual(token.canonicalIndex, 0)
        XCTAssertLessThan(token.canonicalIndex, 8)
    }

    func testHashedAssignmentIsStable() {
        let a = HaplotypeColorToken.assigned(forName: "DRB1_04_06_01")
        let b = HaplotypeColorToken.assigned(forName: "DRB1_04_06_01")
        XCTAssertEqual(a.canonicalIndex, b.canonicalIndex)
    }

    func testEveryTokenHasDistinctGlyph() {
        let glyphs = Set(HaplotypeColorToken.canonicalPalette.map(\.glyph))
        XCTAssertEqual(glyphs.count, HaplotypeColorToken.canonicalPalette.count)
    }

    func testDarkVariantDiffersFromLight() {
        for token in HaplotypeColorToken.canonicalPalette where token.canonicalIndex != 0 {
            XCTAssertNotEqual(token.fillColor.hexString, token.darkFillColor.hexString,
                              "Token \(token.canonicalIndex) lacks a dark-mode variant")
        }
    }
}

final class HaplotypeBlockGlyphTests: XCTestCase {
    func testAllGlyphsHaveDistinctSymbols() {
        let symbols = Set(HaplotypeBlockGlyph.allCases.map(\.symbol))
        XCTAssertEqual(symbols.count, HaplotypeBlockGlyph.allCases.count)
    }
}

final class HaplotypeSlotTests: XCTestCase {
    func testDisplayName() {
        XCTAssertEqual(HaplotypeSlot.h1.displayName, "H1")
        XCTAssertEqual(HaplotypeSlot.h2.displayName, "H2")
    }
}
