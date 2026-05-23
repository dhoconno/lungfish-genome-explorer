import XCTest
import LungfishCore
@testable import LungfishIO

final class BuiltInGenotypeHaplotypeColorTokenTests: XCTestCase {
    func testMCMHaplotypesHaveCanonicalTokens() {
        let mcm = GenotypeHaplotypeDefinitionRegistry.mauritianCynomolgusMacaqueMHCExon2MiSeq
        let mhcA = mcm.locusDefinitions.first { $0.locus == "MHC-A" }!
        let m3A = mhcA.haplotypes.first { $0.name == "M3A" }!
        XCTAssertEqual(m3A.colorTokenIndex, 3)
    }

    func testRhesusHaplotypesAcceptAnyToken() {
        let mamu = GenotypeHaplotypeDefinitionRegistry.rhesusMacaqueMHCExon2MiSeq
        let mhcA = mamu.locusDefinitions.first { $0.locus == "MHC-A" }!
        XCTAssertFalse(mhcA.haplotypes.isEmpty)
        // Rhesus tokens fall on the extended palette (0..15) since their
        // names don't map to canonical M1-M7 by name; verify the assignment
        // is in valid range.
        for h in mhcA.haplotypes {
            XCTAssertGreaterThanOrEqual(h.colorTokenIndex, 0)
            XCTAssertLessThanOrEqual(h.colorTokenIndex, 15)
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
