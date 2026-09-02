import XCTest
@testable import LungfishWorkflow

/// Covers the pair detection that decides whether an Illumina genotyping input
/// needs merging before mapping.
///
/// Regression context: unmerged 2x251 MiSeq reads mapped individually can never
/// satisfy the retained-read filter's full-reference-span requirement against
/// the 244 bp Mamu-DRB amplicons, so every DRB locus silently genotyped as
/// zero while the shorter class I and DQ/DP loci called normally.
final class IlluminaAmpliconPairMergerTests: XCTestCase {

    private func writeFASTQ(_ records: [(String, String)], name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).fastq")
        let text = records.map { header, sequence in
            "@\(header)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Mate parsing

    func testMateNumberReadsCasavaDescription() {
        XCTAssertEqual(
            IlluminaAmpliconPairMerger.mateNumber(
                identifier: "M01472:632:000000000-MC52C:1:1114:23741:20282",
                description: "1:N:0:148"
            ),
            1
        )
        XCTAssertEqual(
            IlluminaAmpliconPairMerger.mateNumber(
                identifier: "M01472:632:000000000-MC52C:1:1114:23741:20282",
                description: "2:N:0:148"
            ),
            2
        )
    }

    func testMateNumberReadsSlashSuffix() {
        XCTAssertEqual(
            IlluminaAmpliconPairMerger.mateNumber(identifier: "READ_1/1", description: nil),
            1
        )
        XCTAssertEqual(
            IlluminaAmpliconPairMerger.mateNumber(identifier: "READ_1/2", description: nil),
            2
        )
    }

    func testMateNumberIsNilForUnpairedIdentifiers() {
        XCTAssertNil(
            IlluminaAmpliconPairMerger.mateNumber(identifier: "merged_read", description: nil)
        )
        // A description that is not a Casava mate field must not be misread.
        XCTAssertNil(
            IlluminaAmpliconPairMerger.mateNumber(identifier: "read", description: "length=251")
        )
    }

    func testFragmentKeyStripsSlashMateSuffix() {
        XCTAssertEqual(
            IlluminaAmpliconPairMerger.fragmentKey(identifier: "READ_1/1", description: nil),
            "READ_1"
        )
        XCTAssertEqual(
            IlluminaAmpliconPairMerger.fragmentKey(identifier: "READ_1/2", description: nil),
            "READ_1"
        )
    }

    // MARK: - Interleaved detection

    func testDetectsInterleavedCasavaPairs() async throws {
        // Shaped like the reported project's imports: one FASTQ holding both
        // mates, distinguished only by the Casava description field.
        let url = try writeFASTQ(
            (0..<8).flatMap { index -> [(String, String)] in
                let name = "M01472:632:000000000-MC52C:1:1114:\(index):20282"
                return [(name + " 1:N:0:148", "ACGT"), (name + " 2:N:0:148", "TGCA")]
            },
            name: "interleaved"
        )
        let isPaired = try await IlluminaAmpliconPairMerger.fastqIsInterleavedPairs(at: url)
        XCTAssertTrue(isPaired)
    }

    func testDetectsInterleavedSlashPairs() async throws {
        let url = try writeFASTQ(
            (0..<8).flatMap { index -> [(String, String)] in
                [("FRAG\(index)/1", "ACGT"), ("FRAG\(index)/2", "TGCA")]
            },
            name: "slash-interleaved"
        )
        let isPaired = try await IlluminaAmpliconPairMerger.fastqIsInterleavedPairs(at: url)
        XCTAssertTrue(isPaired)
    }

    func testAlreadyMergedReadsAreNotTreatedAsPairs() async throws {
        // Pre-merged bundles must keep their existing behaviour and skip
        // bbmerge entirely.
        let url = try writeFASTQ(
            (0..<16).map { ("merged_fragment_\($0)", "ACGTACGTACGT") },
            name: "merged"
        )
        let isPaired = try await IlluminaAmpliconPairMerger.fastqIsInterleavedPairs(at: url)
        XCTAssertFalse(isPaired)
    }

    func testSingleEndReadsWithDuplicateNamesAreNotTreatedAsPairs() async throws {
        // A repeated identifier without mate numbering is not a pair.
        let url = try writeFASTQ(
            (0..<16).map { _ in ("shared_name", "ACGT") },
            name: "duplicate-names"
        )
        let isPaired = try await IlluminaAmpliconPairMerger.fastqIsInterleavedPairs(at: url)
        XCTAssertFalse(isPaired)
    }

    func testEmptyFASTQIsNotTreatedAsPaired() async throws {
        let url = try writeFASTQ([], name: "empty")
        let isPaired = try await IlluminaAmpliconPairMerger.fastqIsInterleavedPairs(at: url)
        XCTAssertFalse(isPaired)
    }

    func testMatePairsMustBeAdjacentToCount() async throws {
        // Mate 1 records grouped ahead of mate 2 records are not interleaved,
        // so the probe must not report them as ready-to-merge pairs.
        let firstMates = (0..<8).map { ("FRAG\($0) 1:N:0:1", "ACGT") }
        let secondMates = (0..<8).map { ("FRAG\($0) 2:N:0:1", "TGCA") }
        let url = try writeFASTQ(firstMates + secondMates, name: "grouped")
        let isPaired = try await IlluminaAmpliconPairMerger.fastqIsInterleavedPairs(at: url)
        XCTAssertFalse(isPaired)
    }
}
