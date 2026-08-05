import Foundation
import XCTest
@testable import LungfishWorkflow

final class SavontClusterFASTATests: XCTestCase {
    func testNormalizesDepthCountsAndPreservesExistingReadCounts() throws {
        try withTemporaryFiles { sourceURL, destinationURL, _ in
            try """
            >final_consensus_0_depth_71 description ignored
            ACGT
            >existing_depth_999_ReadCount-12
            TGCA

            """.write(to: sourceURL, atomically: true, encoding: .utf8)

            let summary = try SavontClusterFASTA.normalize(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )

            XCTAssertEqual(summary, SavontClusterSummary(clusterCount: 2, totalSupportingReads: 83))
            XCTAssertEqual(
                try String(contentsOf: destinationURL, encoding: .utf8),
                ">final_consensus_0_depth_71_ReadCount-71\nACGT\n>existing_depth_999_ReadCount-12\nTGCA\n"
            )
        }
    }

    func testPreservesRecordOrderAndJoinsWrappedSequenceWithoutChangingCharacters() throws {
        try withTemporaryFiles { sourceURL, destinationURL, _ in
            try """
            >second_depth_2
            AC GT
            TG-C
            >first_depth_1
            nnNN

            """.write(to: sourceURL, atomically: true, encoding: .utf8)

            _ = try SavontClusterFASTA.normalize(sourceURL: sourceURL, destinationURL: destinationURL)

            XCTAssertEqual(
                try String(contentsOf: destinationURL, encoding: .utf8),
                ">second_depth_2_ReadCount-2\nAC GTTG-C\n>first_depth_1_ReadCount-1\nnnNN\n"
            )
        }
    }

    func testNormalizationIsIdempotent() throws {
        try withTemporaryFiles { sourceURL, destinationURL, secondDestinationURL in
            try ">cluster_depth_9\nACGT\n".write(to: sourceURL, atomically: true, encoding: .utf8)

            let firstSummary = try SavontClusterFASTA.normalize(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
            let secondSummary = try SavontClusterFASTA.normalize(
                sourceURL: destinationURL,
                destinationURL: secondDestinationURL
            )

            XCTAssertEqual(firstSummary, secondSummary)
            XCTAssertEqual(
                try Data(contentsOf: destinationURL),
                try Data(contentsOf: secondDestinationURL)
            )
        }
    }

    func testCanNormalizeInPlace() throws {
        try withTemporaryFiles { sourceURL, _, _ in
            try ">cluster_depth_4\nAC\nGT\n".write(to: sourceURL, atomically: true, encoding: .utf8)

            let summary = try SavontClusterFASTA.normalize(
                sourceURL: sourceURL,
                destinationURL: sourceURL
            )

            XCTAssertEqual(summary, SavontClusterSummary(clusterCount: 1, totalSupportingReads: 4))
            XCTAssertEqual(
                try String(contentsOf: sourceURL, encoding: .utf8),
                ">cluster_depth_4_ReadCount-4\nACGT\n"
            )
        }
    }

    func testRejectedSourceDoesNotReplaceExistingDestination() throws {
        try withTemporaryFiles { sourceURL, destinationURL, _ in
            try ">missing_count\nACGT\n".write(to: sourceURL, atomically: true, encoding: .utf8)
            try "existing destination\n".write(to: destinationURL, atomically: true, encoding: .utf8)

            XCTAssertThrowsError(try SavontClusterFASTA.normalize(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            ))
            XCTAssertEqual(
                try String(contentsOf: destinationURL, encoding: .utf8),
                "existing destination\n"
            )
        }
    }

    func testEmptySourceProducesEmptyOutputAndZeroSummary() throws {
        try withTemporaryFiles { sourceURL, destinationURL, _ in
            try Data().write(to: sourceURL)

            let summary = try SavontClusterFASTA.normalize(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )

            XCTAssertEqual(summary, SavontClusterSummary(clusterCount: 0, totalSupportingReads: 0))
            XCTAssertEqual(try Data(contentsOf: destinationURL), Data())
        }
    }

    func testRejectsMissingMalformedNegativeAndMultipleCountFields() throws {
        let invalidSources = [
            ">missing_count\nACGT\n",
            ">malformed_depth_nope\nACGT\n",
            ">negative_depth_-1\nACGT\n",
            ">cluster_depth_2_depth_3\nACGT\n",
            ">cluster_ReadCount-nope_depth_2\nACGT\n",
            ">cluster_ReadCount--1\nACGT\n",
            ">cluster_ReadCount-2_ReadCount-3\nACGT\n",
            ">notAFieldReadCount-2\nACGT\n",
            ">cluster_depth_2suffix\nACGT\n",
        ]

        for source in invalidSources {
            try withTemporaryFiles { sourceURL, destinationURL, _ in
                try source.write(to: sourceURL, atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try SavontClusterFASTA.normalize(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL
                ), source)
            }
        }
    }

    func testRejectsMalformedRecords() throws {
        let invalidSources = [
            "ACGT\n>cluster_depth_1\nTGCA\n",
            ">\nACGT\n",
            ">empty_depth_1\n>populated_depth_2\nACGT\n",
            ">empty_depth_1\n\n",
        ]

        for source in invalidSources {
            try withTemporaryFiles { sourceURL, destinationURL, _ in
                try source.write(to: sourceURL, atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try SavontClusterFASTA.normalize(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL
                ), source)
            }
        }
    }

    func testRejectsDuplicateIdentifiers() throws {
        try withTemporaryFiles { sourceURL, destinationURL, _ in
            try """
            >duplicate_depth_2 first
            ACGT
            >duplicate_depth_2 second
            TGCA

            """.write(to: sourceURL, atomically: true, encoding: .utf8)

            XCTAssertThrowsError(try SavontClusterFASTA.normalize(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            ))
        }
    }

    func testRejectsIndividualCountAndTotalOverflow() throws {
        let overflow = String(UInt64(Int.max) + 1)
        try withTemporaryFiles { sourceURL, destinationURL, _ in
            try ">overflow_depth_\(overflow)\nACGT\n".write(
                to: sourceURL,
                atomically: true,
                encoding: .utf8
            )
            XCTAssertThrowsError(try SavontClusterFASTA.normalize(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            ))
        }

        try withTemporaryFiles { sourceURL, destinationURL, _ in
            try """
            >largest_ReadCount-\(Int.max)
            ACGT
            >one_ReadCount-1
            TGCA

            """.write(to: sourceURL, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try SavontClusterFASTA.normalize(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            ))
        }
    }

    private func withTemporaryFiles(
        _ body: (URL, URL, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SavontClusterFASTANormalizerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(
            root.appendingPathComponent("source.fasta"),
            root.appendingPathComponent("destination.fasta"),
            root.appendingPathComponent("second-destination.fasta")
        )
    }
}
