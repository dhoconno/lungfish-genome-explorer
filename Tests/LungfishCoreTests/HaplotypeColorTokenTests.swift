import XCTest
@testable import LungfishCore

final class HaplotypeColorTokenTests: XCTestCase {
    func testCanonicalPaletteHasSixtyFourTokens() {
        let palette = HaplotypeColorToken.canonicalPalette
        XCTAssertEqual(palette.count, 64,
                       "Palette should expose 64 tokens (Budde 2010 M0-M7 plus 56 extended)")
    }

    func testCanonicalBudde2010TokensAreUntouched() {
        // The first 8 tokens must remain bit-identical to the Budde 2010
        // canonical palette: changing them would silently re-color decades
        // of MCM literature in the GUI.
        let palette = HaplotypeColorToken.canonicalPalette
        let canonical = HaplotypeColorToken.canonicalBudde2010Tokens
        XCTAssertEqual(canonical.count, 8)
        for index in 0..<canonical.count {
            XCTAssertEqual(palette[index], canonical[index],
                           "Canonical Budde 2010 token at index \(index) was modified")
        }
    }

    func testMCMNameAssignmentIsCanonical() {
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M1").canonicalIndex, 1)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M7").canonicalIndex, 7)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M1A").canonicalIndex, 1)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M1E").canonicalIndex, 1)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M7E").canonicalIndex, 7)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M3DR").canonicalIndex, 3)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M7B").canonicalIndex, 7)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M4DP").canonicalIndex, 4)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "M7DP").canonicalIndex, 7)
        XCTAssertEqual(HaplotypeColorToken.assigned(forName: "-").canonicalIndex, 0)
    }

    func testConcreteMCMDPHaplotypesUseBuddeColors() {
        for index in 1...7 {
            XCTAssertEqual(
                HaplotypeColorToken.assigned(forName: "M\(index)DP").canonicalIndex,
                index,
                "M\(index)DP should use canonical M\(index) color"
            )
        }
    }

    func testUnknownNameUsesHashedAssignment() {
        let token = HaplotypeColorToken.assigned(forName: "Mamu-A1*004:01:01")
        XCTAssertGreaterThanOrEqual(token.canonicalIndex, 1,
                                    "Hashed names should never resolve to the absent slot")
        XCTAssertLessThan(token.canonicalIndex, HaplotypeColorToken.canonicalPalette.count)
    }

    func testHashedAssignmentIsStable() {
        let a = HaplotypeColorToken.assigned(forName: "DRB1_04_06_01")
        let b = HaplotypeColorToken.assigned(forName: "DRB1_04_06_01")
        XCTAssertEqual(a.canonicalIndex, b.canonicalIndex)
    }

    func testEveryCanonicalTokenHasDistinctFillColor() {
        let hexes = Set(HaplotypeColorToken.canonicalPalette.map(\.fillColor.hexString))
        XCTAssertEqual(hexes.count, HaplotypeColorToken.canonicalPalette.count,
                       "All 64 tokens should have distinct light-mode fill colors")
    }

    func testEveryCanonicalTokenHasDistinctDarkFillColor() {
        let hexes = Set(HaplotypeColorToken.canonicalPalette.map(\.darkFillColor.hexString))
        XCTAssertEqual(hexes.count, HaplotypeColorToken.canonicalPalette.count,
                       "All 64 tokens should have distinct dark-mode fill colors")
    }

    func testEveryCanonicalTokenHasDistinctDisplayName() {
        let names = Set(HaplotypeColorToken.canonicalPalette.map(\.displayName))
        XCTAssertEqual(names.count, HaplotypeColorToken.canonicalPalette.count,
                       "Display names must be unique so tooltips/legends don't collide")
    }

    func testDarkVariantDiffersFromLight() {
        for token in HaplotypeColorToken.canonicalPalette where token.canonicalIndex != 0 {
            XCTAssertNotEqual(token.fillColor.hexString, token.darkFillColor.hexString,
                              "Token \(token.canonicalIndex) lacks a dark-mode variant")
        }
    }

    func testExtendedPaletteHasUniqueFillColors() {
        let palette = HaplotypeColorToken.extendedRhesusPalette
        XCTAssertEqual(palette.count, 63,
                       "Extended palette should expose 63 tokens (canonicalPalette minus the 'Absent' slot)")
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
        // Generate a varied set of plausible Rhesus / custom names and verify
        // they spread across the new 1..63 range instead of clustering on the
        // 7 canonical M-tokens. We don't require strict uniformity, only that
        // the hash exercises a meaningful portion of the palette.
        var names: [String] = [
            "DRB1_04_06_01", "DRB5_03_09", "A1_004_01_01",
            "B_028", "B_069", "Custom-Foo-2026",
        ]
        for i in 0..<128 {
            names.append("Mamu-A1*\(String(format: "%03d", i)):01:01")
        }
        let indices = Set(names.map { HaplotypeColorToken.assigned(forName: $0).canonicalIndex })
        XCTAssertGreaterThan(indices.count, 20,
                             "With \(names.count) varied names, hash should cover >20 distinct tokens; got \(indices.count)")
        // And nothing should land on index 0 (reserved for absent).
        XCTAssertFalse(indices.contains(0),
                       "Hashed assignment must never produce the 'Absent' slot")
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
