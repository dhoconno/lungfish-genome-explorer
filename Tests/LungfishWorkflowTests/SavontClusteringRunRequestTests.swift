import Foundation
import XCTest
@testable import LungfishWorkflow

final class SavontClusteringRunRequestTests: XCTestCase {
    func testDefaultsHaveNoImplicitReadLengthBounds() throws {
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/barcode12.fastq.gz"),
            outputFASTAURL: URL(fileURLWithPath: "/tmp/barcode12-savont-clusters.fasta")
        )

        XCTAssertEqual(SavontClusteringRunRequest.workflowVersion, "1")
        XCTAssertEqual(SavontClusteringRunRequest.toolVersion, "0.5.0")
        XCTAssertEqual(SavontClusteringRunRequest.condaEnvironment, "savont")
        XCTAssertEqual(request.threads, max(1, ProcessInfo.processInfo.activeProcessorCount))
        XCTAssertEqual(request.qualityValueCutoff, 90)
        XCTAssertEqual(request.minimumClusterSize, 3)
        XCTAssertNil(request.minimumReadLength)
        XCTAssertNil(request.maximumReadLength)
        XCTAssertFalse(request.singleStrand)
    }

    func testDefaultOutputBaseNameStripsCompoundFASTQExtensions() {
        XCTAssertEqual(
            SavontClusteringRunRequest.defaultOutputBaseName(
                for: URL(fileURLWithPath: "/tmp/sample.one.fastq.gz")
            ),
            "sample.one-savont-clusters"
        )
        XCTAssertEqual(
            SavontClusteringRunRequest.defaultOutputBaseName(
                for: URL(fileURLWithPath: "/tmp/sample.two.fq")
            ),
            "sample.two-savont-clusters"
        )
        XCTAssertEqual(
            SavontClusteringRunRequest.defaultOutputBaseName(
                for: URL(fileURLWithPath: "/tmp/sample.three.FQ.GZ")
            ),
            "sample.three-savont-clusters"
        )
        XCTAssertEqual(
            SavontClusteringRunRequest.defaultOutputBaseName(
                for: URL(fileURLWithPath: "/tmp/sample.data.gz")
            ),
            "sample.data.gz-savont-clusters"
        )
    }

    func testArgumentsOmitUnsetBoundsAndUseRequestDefaults() throws {
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/barcode12.fastq.gz"),
            outputFASTAURL: URL(fileURLWithPath: "/tmp/clusters.fasta"),
            threads: 6
        )

        XCTAssertEqual(try request.arguments(outputDirectory: URL(fileURLWithPath: "/tmp/run")), [
            "asv", "/tmp/barcode12.fastq.gz",
            "-o", "/tmp/run",
            "-t", "6",
            "--quality-value-cutoff", "90",
            "--min-cluster-size", "3",
        ])
    }

    func testArgumentsIncludeExplicitBoundsAndAttemptOverrides() throws {
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            outputFASTAURL: URL(fileURLWithPath: "/tmp/clusters.fa"),
            threads: 8,
            qualityValueCutoff: 75,
            minimumClusterSize: 4,
            minimumReadLength: 500,
            maximumReadLength: 5_000,
            singleStrand: false
        )

        XCTAssertEqual(
            try request.arguments(
                outputDirectory: URL(fileURLWithPath: "/tmp/attempt"),
                threads: 1,
                singleStrand: true
            ),
            [
                "asv", "/tmp/reads.fastq",
                "-o", "/tmp/attempt",
                "-t", "1",
                "--quality-value-cutoff", "75",
                "--min-cluster-size", "4",
                "--min-read-length", "500",
                "--max-read-length", "5000",
                "--single-strand",
            ]
        )
    }

    func testArgumentsRejectNonpositiveAttemptThreadOverrides() throws {
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            outputFASTAURL: URL(fileURLWithPath: "/tmp/clusters.fasta"),
            threads: 8
        )

        for threads in [0, -1] {
            XCTAssertThrowsError(try request.arguments(
                outputDirectory: URL(fileURLWithPath: "/tmp/attempt"),
                threads: threads
            ))
        }
    }

    func testRejectsInvalidNumericValuesAndLengthRanges() {
        let input = URL(fileURLWithPath: "/tmp/reads.fastq")
        let output = URL(fileURLWithPath: "/tmp/clusters.fasta")

        for threads in [0, -1] {
            XCTAssertThrowsError(try SavontClusteringRunRequest(
                inputFASTQURL: input,
                outputFASTAURL: output,
                threads: threads
            ))
        }
        for qualityValueCutoff in [-1, 101] {
            XCTAssertThrowsError(try SavontClusteringRunRequest(
                inputFASTQURL: input,
                outputFASTAURL: output,
                qualityValueCutoff: qualityValueCutoff
            ))
        }
        for minimumClusterSize in [0, -1] {
            XCTAssertThrowsError(try SavontClusteringRunRequest(
                inputFASTQURL: input,
                outputFASTAURL: output,
                minimumClusterSize: minimumClusterSize
            ))
        }
        for minimumReadLength in [0, -1] {
            XCTAssertThrowsError(try SavontClusteringRunRequest(
                inputFASTQURL: input,
                outputFASTAURL: output,
                minimumReadLength: minimumReadLength
            ))
        }
        for maximumReadLength in [0, -1] {
            XCTAssertThrowsError(try SavontClusteringRunRequest(
                inputFASTQURL: input,
                outputFASTAURL: output,
                maximumReadLength: maximumReadLength
            ))
        }
        XCTAssertThrowsError(try SavontClusteringRunRequest(
            inputFASTQURL: input,
            outputFASTAURL: output,
            minimumReadLength: 2_000,
            maximumReadLength: 1_000
        ))
    }

    func testAcceptsQualityCutoffEndpointsAndEqualLengthBounds() throws {
        let input = URL(fileURLWithPath: "/tmp/reads.fastq")
        let output = URL(fileURLWithPath: "/tmp/clusters.fasta")

        XCTAssertEqual(
            try SavontClusteringRunRequest(
                inputFASTQURL: input,
                outputFASTAURL: output,
                qualityValueCutoff: 0,
                minimumReadLength: 1_000,
                maximumReadLength: 1_000
            ).qualityValueCutoff,
            0
        )
        XCTAssertEqual(
            try SavontClusteringRunRequest(
                inputFASTQURL: input,
                outputFASTAURL: output,
                qualityValueCutoff: 100
            ).qualityValueCutoff,
            100
        )
    }

    func testRejectsNonFASTAOutput() {
        XCTAssertThrowsError(try SavontClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            outputFASTAURL: URL(fileURLWithPath: "/tmp/clusters.txt")
        ))
    }

    func testCodableRoundTripPreservesValidRequestAndRejectsInvalidPayloads() throws {
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            outputFASTAURL: URL(fileURLWithPath: "/tmp/clusters.fasta"),
            threads: 4,
            qualityValueCutoff: 80,
            minimumClusterSize: 5,
            minimumReadLength: 500,
            maximumReadLength: 5_000,
            singleStrand: true
        )
        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(SavontClusteringRunRequest.self, from: encoded), request)

        let validObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        func assertRejected(
            modifying mutation: (inout [String: Any]) -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            var object = validObject
            mutation(&object)
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(
                try JSONDecoder().decode(SavontClusteringRunRequest.self, from: data),
                file: file,
                line: line
            )
        }

        try assertRejected { $0["threads"] = 0 }
        try assertRejected { $0["qualityValueCutoff"] = 101 }
        try assertRejected { $0["minimumClusterSize"] = 0 }
        try assertRejected { $0["minimumReadLength"] = 0 }
        try assertRejected { $0["maximumReadLength"] = -1 }
        try assertRejected {
            $0["minimumReadLength"] = 5_000
            $0["maximumReadLength"] = 500
        }
        try assertRejected {
            $0["outputFASTAURL"] = URL(fileURLWithPath: "/tmp/clusters.txt").absoluteString
        }
    }
}
