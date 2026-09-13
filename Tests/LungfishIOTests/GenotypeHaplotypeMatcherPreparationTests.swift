import XCTest
@testable import LungfishIO

final class GenotypeHaplotypeMatcherPreparationTests: XCTestCase {
    func testPreparedTokensPreserveMatchingAndFallbackSemantics() throws {
        let cases: [(String, String, Bool)] = [
            ("marker", "marker", true),
            ("01_Mafa-A1_001g2|other,Mafa-B_001", "A1_001", true),
            ("MCM_MHC_MiSeq_0025|source_loci=MHC-DQA1", "MCM_MHC_MiSeq_0025", true),
            ("Mafa-DQB1_06:01:01:01", "DQB1_06:01:01:01", true),
            ("Mafa-DQB1_06:01:01:01", "DQB1_06:08:01:01", false),
            ("marker_two", "marker", true),
            ("markerTwo", "marker", false),
            ("ABC", "AB", false),
            ("", "marker", false),
        ]
        let uncached = cases.map { GenotypeHaplotypeDiagnosticMatcher.matches(genotype: $0.0, diagnosticAllele: $0.1) }
        XCTAssertEqual(uncached, cases.map(\.2))
        // Deliberately omit some strings to exercise the exact fallback too.
        let prepared = GenotypeHaplotypeDiagnosticMatcher.withPreparedTokens(for: cases.prefix(4).flatMap { [$0.0, $0.1] }) {
            cases.map { GenotypeHaplotypeDiagnosticMatcher.matches(genotype: $0.0, diagnosticAllele: $0.1) }
        }
        XCTAssertEqual(prepared, uncached)
    }

    func testNestedAndThrowingPreparedContextsRestoreOuterMatching() throws {
        enum Expected: Error { case stop }
        try GenotypeHaplotypeDiagnosticMatcher.withPreparedTokens(for: ["01_Mafa-A1_001g", "A1_001"]) {
            XCTAssertTrue(GenotypeHaplotypeDiagnosticMatcher.matches(genotype: "01_Mafa-A1_001g", diagnosticAllele: "A1_001"))
            XCTAssertThrowsError(try GenotypeHaplotypeDiagnosticMatcher.withPreparedTokens(for: ["unrelated"]) {
                XCTAssertFalse(GenotypeHaplotypeDiagnosticMatcher.matches(genotype: "unrelated", diagnosticAllele: "A1_001"))
                throw Expected.stop
            })
            XCTAssertTrue(GenotypeHaplotypeDiagnosticMatcher.matches(genotype: "01_Mafa-A1_001g", diagnosticAllele: "A1_001"))
        }
        XCTAssertFalse(GenotypeHaplotypeDiagnosticMatcher.matches(genotype: "unrelated", diagnosticAllele: "A1_001"))
    }

    func testConcurrentPreparedContextsAgreeWithIndependentMatching() async {
        let results = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let genotype = "Mafa-A1_\(index)g"
                    let diagnostic = "A1_\(index)"
                    return GenotypeHaplotypeDiagnosticMatcher.withPreparedTokens(for: [genotype, diagnostic]) {
                        GenotypeHaplotypeDiagnosticMatcher.matches(genotype: genotype, diagnosticAllele: diagnostic)
                            && !GenotypeHaplotypeDiagnosticMatcher.matches(genotype: genotype, diagnosticAllele: "B1_\(index)")
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0 })
    }
}
