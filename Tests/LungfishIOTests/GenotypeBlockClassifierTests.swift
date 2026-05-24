import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeBlockClassifierTests: XCTestCase {
    func testBlockCoherentHeterozygote() {
        let result = GenotypeBlockClassifier.classify(calls: [
            (locus: "MHC-A", h1: "M2A", h2: "M3A"),
            (locus: "MHC-B", h1: "M2B", h2: "M3B"),
            (locus: "MHC-DRB", h1: "M2DR", h2: "M3DR"),
        ])
        XCTAssertEqual(result, .blockCoherent)
    }

    func testHomozygousBlock() {
        let result = GenotypeBlockClassifier.classify(calls: [
            (locus: "MHC-A", h1: "M1A", h2: "M1A"),
            (locus: "MHC-B", h1: "M1B", h2: "M1B"),
        ])
        XCTAssertEqual(result, .blockCoherent)
    }

    func testRegionalRecombinant() {
        let result = GenotypeBlockClassifier.classify(calls: [
            (locus: "MHC-A", h1: "M1A", h2: "M2A"),
            (locus: "MHC-B", h1: "M1B", h2: "M2B"),
            (locus: "MHC-DRB", h1: "M1DR", h2: "recM2M3DR"),
        ])
        XCTAssertEqual(result, .regionalRecombinant)
    }

    func testAtypicalMultipleBreaks() {
        let result = GenotypeBlockClassifier.classify(calls: [
            (locus: "MHC-A", h1: "M1A", h2: "M2A"),
            (locus: "MHC-B", h1: "M1B", h2: "M5B"),
            (locus: "MHC-DRB", h1: "M1DR", h2: "M7DR"),
            (locus: "MHC-DQA", h1: "M1DQ", h2: "M3DQ"),
        ])
        XCTAssertEqual(result, .atypical)
    }

    func testEmptyReturnsUnknown() {
        let result = GenotypeBlockClassifier.classify(calls: [])
        XCTAssertEqual(result, .unknown)
    }
}
