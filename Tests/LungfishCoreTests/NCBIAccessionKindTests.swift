import XCTest
@testable import LungfishCore

final class NCBIAccessionKindTests: XCTestCase {
    func testRefSeqAndGenBankAssemblyPrefixesAreAssemblies() {
        XCTAssertEqual(NCBIAccessionKind.classify("GCF_009858895.2"), .assembly)
        XCTAssertEqual(NCBIAccessionKind.classify("GCA_000001405.29"), .assembly)
    }

    // The accession that exposed the substitution: a GenBank nucleotide record
    // with no assembly of its own.
    func testGenBankNucleotideAccessionIsNucleotide() {
        XCTAssertEqual(NCBIAccessionKind.classify("MN908947.3"), .nucleotide)
    }

    // NC_ is RefSeq but still a nucleotide record, not an assembly.
    func testRefSeqNucleotidePrefixIsNucleotide() {
        XCTAssertEqual(NCBIAccessionKind.classify("NC_045512.2"), .nucleotide)
    }

    func testClassificationIgnoresCaseAndSurroundingWhitespace() {
        XCTAssertEqual(NCBIAccessionKind.classify("  gcf_009858895.2 "), .assembly)
        XCTAssertEqual(NCBIAccessionKind.classify(" mn908947.3 "), .nucleotide)
    }
}
