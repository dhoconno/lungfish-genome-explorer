import XCTest
import LungfishCore
@testable import LungfishIO

final class BuiltInGenotypeHaplotypeColorTokenTests: XCTestCase {
    func testCanonicalMNameAssignsCanonicalToken() {
        // Names matching the canonical M1-M7 scheme derive a stable token
        // index from the name when no explicit index is supplied.
        let m3A = GenotypeHaplotypeDefinition(name: "M3A", diagnosticAlleles: ["x"])
        XCTAssertEqual(m3A.colorTokenIndex, 3)
    }

    func testNonCanonicalNamesStayWithinPaletteRange() {
        // Names that don't map to a canonical M1-M7 token still fall on the
        // extended palette; verify assignments stay within the palette range.
        let paletteCount = HaplotypeColorToken.canonicalPalette.count
        for name in ["A001.01", "B071.01", "DR15.01/02", "01g1"] {
            let haplotype = GenotypeHaplotypeDefinition(name: name, diagnosticAlleles: ["x"])
            XCTAssertGreaterThanOrEqual(haplotype.colorTokenIndex, 0)
            XCTAssertLessThan(haplotype.colorTokenIndex, paletteCount)
        }
    }

    func testRoundTripPreservesColorTokenIndex() throws {
        let h = GenotypeHaplotypeDefinition(name: "M2A", diagnosticAlleles: ["x"], colorTokenIndex: 5)
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(GenotypeHaplotypeDefinition.self, from: data)
        XCTAssertEqual(decoded.colorTokenIndex, 5)
    }

    func testDecodeWithoutTokenAssignsFromName() throws {
        let json = """
        {"name":"M3DR","diagnosticAlleles":["x"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(GenotypeHaplotypeDefinition.self, from: json)
        XCTAssertEqual(decoded.colorTokenIndex, 3)
    }
}
