import XCTest
@testable import LungfishCore

final class ThymineAlphabetTests: XCTestCase {
    func testNucleotideTextReplacesUracilPreservingCase() {
        XCTAssertEqual(ThymineAlphabet.normalized("ACGUacgu-N"), "ACGTacgt-N")
        XCTAssertEqual(ThymineAlphabet.normalized("ACGT"), "ACGT")
    }

    func testProteinTextKeepsSelenocysteine() {
        XCTAssertTrue(ThymineAlphabet.containsProteinOnlyResidues("MKULQE"))
        XCTAssertEqual(ThymineAlphabet.normalizedIfNucleotide(["MKULQE", "ACGU"]), ["MKULQE", "ACGU"])
        XCTAssertEqual(ThymineAlphabet.normalizedIfNucleotide(["ACGU", "AC-U"]), ["ACGT", "AC-T"])
    }

    func testFASTAFileNormalizationRewritesSequenceLinesOnly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thymine-\(UUID().uuidString).fa")
        defer { try? FileManager.default.removeItem(at: url) }
        try ">Human_Uganda virus\nACGU\nuuaa\n>second\nAC\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(try ThymineAlphabet.normalizeFASTAFile(at: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), ">Human_Uganda virus\nACGT\nttaa\n>second\nAC\n")
        XCTAssertFalse(try ThymineAlphabet.normalizeFASTAFile(at: url))
    }

    func testFASTAFileNormalizationLeavesProteinAndUracilFreeFilesUntouched() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thymine-\(UUID().uuidString).fa")
        defer { try? FileManager.default.removeItem(at: url) }
        let protein = ">sel U protein\nMKULQEU\n"
        try protein.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(try ThymineAlphabet.normalizeFASTAFile(at: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), protein)
    }

    func testFASTAFileNormalizationHandlesChunkBoundaries() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thymine-\(UUID().uuidString).fa")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = String(repeating: "ACGU", count: 3_000)
        try ">rna\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(try ThymineAlphabet.normalizeFASTAFile(at: url, chunkSize: 7))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       ">rna\n\(String(repeating: "ACGT", count: 3_000))\n")
    }
}
