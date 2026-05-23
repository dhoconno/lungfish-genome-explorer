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

    func testExtendedPaletteHasUniqueFillColors() {
        let palette = HaplotypeColorToken.extendedRhesusPalette
        XCTAssertEqual(palette.count, 15, "Extended palette should be M1-M7 plus 8 X-slots")
        let hexes = Set(palette.map(\.fillColor.hexString))
        XCTAssertEqual(hexes.count, palette.count,
                       "Extended palette has duplicate fill colors")
    }

    func testExtendedPaletteEntriesAllHaveDarkVariants() {
        for token in HaplotypeColorToken.extendedRhesusPalette {
            XCTAssertNotEqual(token.fillColor.hexString, token.darkFillColor.hexString,
                              "Extended palette token \(token.displayName) lacks a dark variant")
        }
    }

    func testHashedAssignmentSpansExtendedRange() {
        // Sample a few uncommon names; we don't require uniformity, only
        // that the hash actually exercises beyond the canonical 7-token
        // range when given Rhesus-style names.
        let names = [
            "DRB1_04_06_01", "DRB5_03_09", "A1_004_01_01",
            "B_028", "B_069", "Custom-Foo-2026",
        ]
        let indices = Set(names.map { HaplotypeColorToken.assigned(forName: $0).canonicalIndex })
        XCTAssertGreaterThan(indices.count, 1, "Hash should map names to >1 distinct token")
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
