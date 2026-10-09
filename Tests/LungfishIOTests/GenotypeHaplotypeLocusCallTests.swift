import XCTest
@testable import LungfishIO

final class GenotypeHaplotypeLocusCallTests: XCTestCase {
    /// The one predicate behind a workbook colour (Phase 2.3 finding SF6). A
    /// value names one haplotype unless it is empty, the dash, the unresolved
    /// marker, Not assayed, an error token or an ambiguity token.
    func testASingleHaplotypeNameIsNeitherAStatusNorAToken() {
        for name in ["M1A", "M4", "rec1", "A1_063", " M2DR ", "Manual-A", "D2"] {
            XCTAssertTrue(GenotypeHaplotypeLocusCall.isSingleHaplotypeName(name), name)
        }
        for value in ["", "  ", "-", "?", "Not assayed", "not assayed", "ERR: NO HAP", "ERR: TMG",
                      "ERR: TMH (M1DR, M2DR, M3DR)", "M4|M7", "M1A|M2A", "|"] {
            XCTAssertFalse(GenotypeHaplotypeLocusCall.isSingleHaplotypeName(value), value)
        }
    }
}
