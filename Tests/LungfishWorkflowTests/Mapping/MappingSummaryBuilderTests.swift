import XCTest
@testable import LungfishWorkflow

final class MappingSummaryBuilderTests: XCTestCase {

    func testBuildSummariesCombinesCoverageAndIdentityMetrics() throws {
        let coverageOutput = """
        #rname\tstartpos\tendpos\tnumreads\tcovbases\tcoverage\tmeandepth\tmeanbaseq\tmeanmapq
        chr1\t1\t1000\t3\t800\t80.0\t6.5\t30.0\t43.3
        chr2\t1\t500\t1\t100\t20.0\t0.4\t25.0\t10.0
        """

        let viewOutput = """
        read1\t0\tchr1\t1\t60\t100M\t*\t0\t0\tACGT\t*\tNM:i:0
        read2\t0\tchr1\t10\t50\t50M10I40M\t*\t0\t0\tACGT\t*\tNM:i:5
        read3\t0\tchr1\t20\t20\t90M10S\t*\t0\t0\tACGT\t*\tNM:i:2
        read4\t0\tchr2\t30\t10\t40M10I\t*\t0\t0\tACGT\t*\tNM:i:1
        """

        let summaries = try MappingSummaryBuilder.buildSummaries(
            coverageOutput: coverageOutput,
            viewOutput: viewOutput,
            totalReads: 10
        )

        XCTAssertEqual(summaries.map(\.contigName), ["chr1", "chr2"])
        XCTAssertEqual(summaries[0].contigLength, 1000)
        XCTAssertEqual(summaries[0].mappedReads, 3)
        XCTAssertEqual(summaries[0].mappedReadPercent, 30.0, accuracy: 0.001)
        XCTAssertEqual(summaries[0].coverageBreadth, 0.8, accuracy: 0.0001)
        XCTAssertEqual(summaries[0].meanDepth, 6.5, accuracy: 0.0001)
        XCTAssertEqual(summaries[0].medianMAPQ, 50.0, accuracy: 0.001)
        XCTAssertEqual(summaries[0].meanIdentity, 283.0 / 290.0, accuracy: 0.0001)
        XCTAssertEqual(summaries[1].coverageBreadth, 0.2, accuracy: 0.0001)
        XCTAssertEqual(summaries[1].meanIdentity, 49.0 / 50.0, accuracy: 0.0001)
    }

    func testBuildSummariesNormalizesLegacyCoverageFractions() throws {
        let coverageOutput = """
        #rname\tstartpos\tendpos\tnumreads\tcovbases\tcoverage\tmeandepth\tmeanbaseq\tmeanmapq
        chr1\t1\t100\t2\t50\t0.5\t4.0\t30.0\t40.0
        """

        let viewOutput = """
        read1\t0\tchr1\t1\t40\t50M\t*\t0\t0\tACGT\t*\tNM:i:0
        read2\t0\tchr1\t10\t40\t50M\t*\t0\t0\tACGT\t*\tNM:i:1
        """

        let summary = try XCTUnwrap(
            MappingSummaryBuilder.buildSummaries(
                coverageOutput: coverageOutput,
                viewOutput: viewOutput,
                totalReads: 4
            ).first
        )

        XCTAssertEqual(summary.coverageBreadth, 0.5, accuracy: 0.0001)
        XCTAssertEqual(summary.mappedReadPercent, 50.0, accuracy: 0.0001)
    }
}
