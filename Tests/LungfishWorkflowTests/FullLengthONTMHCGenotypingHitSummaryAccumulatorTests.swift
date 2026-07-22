import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class FullLengthONTMHCGenotypingHitSummaryAccumulatorTests: XCTestCase {
    func testSummariesCollapseCanonicalLocatorDuplicatesAndCountEveryQueryPerTarget() throws {
        let samURL = try writeSAM("""
        @HD\tVN:1.6\tSO:coordinate
        exact-genomic\t0\tSample-A|cluster-1\t1\t60\t10=\t*\t0\t0\tAAAAAAAAAA\t*\tRG:Z:rg-a
        exact-genomic\t0\tSample-A|cluster-1\t1\t60\t10=\t*\t0\t0\tAAAAAAAAAA\t*\tRG:Z:rg-a
        exact-long-reference\t0\tSample-A|cluster-1\t1\t60\t8=2I\t*\t0\t0\tAAAAAAAAAA\t*\tRG:Z:rg-a
        short-reference-indel\t0\tSample-A|cluster-1\t1\t60\t8=2I\t*\t0\t0\tAAAAAAAAAA\t*\tRG:Z:rg-a
        closest-a\t0\tSample-A|cluster-2\t1\t60\t8=2X\t*\t0\t0\tAAAAAAAAAA\t*\tRG:Z:rg-a
        closest-b\t0\tSample-A|cluster-2\t1\t60\t8=2X\t*\t0\t0\tAAAAAAAAAA\t*\tRG:Z:rg-a
        worse\t0\tSample-A|cluster-2\t1\t60\t7=3X\t*\t0\t0\tAAAAAAAAAA\t*\tRG:Z:rg-a
        """)
        defer { try? FileManager.default.removeItem(at: samURL.deletingLastPathComponent()) }

        let summaries = try FullLengthONTMHCGenotypingHitSummaryAccumulator.summaries(
            samURL: samURL,
            bamPath: "artifacts/alignments/genotyping-evidence.bam",
            referenceLengths: [
                "exact-genomic": 1_000,
                "exact-long-reference": 2_500,
                "short-reference-indel": 1_000,
                "closest-a": 1_000,
                "closest-b": 1_000,
                "worse": 1_000,
            ],
            cdnaThreshold: 2_000
        )

        let first = try XCTUnwrap(summaries["Sample-A|cluster-1"])
        XCTAssertEqual(first.bamPath, "artifacts/alignments/genotyping-evidence.bam")
        XCTAssertEqual(first.targetName, "Sample-A|cluster-1")
        XCTAssertEqual(first.alignmentCount, 3)
        XCTAssertEqual(first.queryAlignmentCounts, [
            "exact-genomic": 1,
            "exact-long-reference": 1,
            "short-reference-indel": 1,
        ])
        XCTAssertEqual(first.exactMatchQueryNames, ["exact-genomic", "exact-long-reference"])
        XCTAssertEqual(first.closestMatchQueryNames, ["exact-genomic"])
        XCTAssertEqual(first.queryAlignmentCounts.values.reduce(0, +), first.alignmentCount)

        let second = try XCTUnwrap(summaries["Sample-A|cluster-2"])
        XCTAssertEqual(second.alignmentCount, 3)
        XCTAssertEqual(second.queryAlignmentCounts, ["closest-a": 1, "closest-b": 1, "worse": 1])
        XCTAssertEqual(second.exactMatchQueryNames, [])
        XCTAssertEqual(second.closestMatchQueryNames, ["closest-a", "closest-b"])
        XCTAssertEqual(second.queryAlignmentCounts.values.reduce(0, +), second.alignmentCount)
    }

    func testCanonicalIdentityKeepsDifferentReadGroupsStartsAndCIGARs() throws {
        let samURL = try writeSAM("""
        allele\t0\tSample-B|cluster-1\t1\t60\t10=\t*\t0\t0\tAAAAAAAAAA\t*\tRG:Z:rg-a
        allele\t0\tSample-B|cluster-1\t1\t60\t10=\t*\t0\t0\tAAAAAAAAAA\t*\tRG:Z:rg-b
        allele\t0\tSample-B|cluster-1\t2\t60\t10=\t*\t0\t0\tAAAAAAAAAA\t*\tRG:Z:rg-a
        allele\t0\tSample-B|cluster-1\t1\t60\t8=2S\t*\t0\t0\tAAAAAAAAAA\t*\tRG:Z:rg-a
        """)
        defer { try? FileManager.default.removeItem(at: samURL.deletingLastPathComponent()) }

        let summary = try XCTUnwrap(FullLengthONTMHCGenotypingHitSummaryAccumulator.summaries(
            samURL: samURL,
            bamPath: "evidence.bam",
            referenceLengths: ["allele": 1_000],
            cdnaThreshold: 2_000
        )["Sample-B|cluster-1"])

        XCTAssertEqual(summary.alignmentCount, 4)
        XCTAssertEqual(summary.queryAlignmentCounts, ["allele": 4])
        XCTAssertEqual(summary.exactMatchQueryNames, ["allele"])
        XCTAssertEqual(summary.closestMatchQueryNames, ["allele"])
    }

    private func writeSAM(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mhc-hit-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("genotyping.sam")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
