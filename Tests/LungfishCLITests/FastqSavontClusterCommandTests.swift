import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FastqSavontClusterCommandTests: XCTestCase {
    func testFastqCommandRegistersSavontCluster() {
        let names = FastqCommand.configuration.subcommands.map { $0.configuration.commandName }

        XCTAssertTrue(names.contains("savont-cluster"))
    }

    func testSavontClusterParsesMinimalOptionsWithoutLengthBounds() throws {
        let command = try FastqSavontClusterSubcommand.parse([
            "/tmp/reads.fastq",
            "--output", "/tmp/clusters.fasta",
        ])

        XCTAssertEqual(command.input, "/tmp/reads.fastq")
        XCTAssertEqual(command.output, "/tmp/clusters.fasta")
        XCTAssertEqual(command.threads, max(1, ProcessInfo.processInfo.activeProcessorCount))
        XCTAssertEqual(command.qualityValueCutoff, 90)
        XCTAssertEqual(command.minimumClusterSize, 3)
        XCTAssertNil(command.minimumReadLength)
        XCTAssertNil(command.maximumReadLength)
        XCTAssertFalse(command.singleStrand)
    }

    func testSavontClusterParsesAllTypedOptions() throws {
        let command = try FastqSavontClusterSubcommand.parse([
            "/tmp/reads.fastq.gz",
            "--output", "/tmp/clusters.fa",
            "--threads", "4",
            "--quality-value-cutoff", "85",
            "--min-cluster-size", "7",
            "--min-read-length", "500",
            "--max-read-length", "5000",
            "--single-strand",
        ])

        XCTAssertEqual(command.input, "/tmp/reads.fastq.gz")
        XCTAssertEqual(command.output, "/tmp/clusters.fa")
        XCTAssertEqual(command.threads, 4)
        XCTAssertEqual(command.qualityValueCutoff, 85)
        XCTAssertEqual(command.minimumClusterSize, 7)
        XCTAssertEqual(command.minimumReadLength, 500)
        XCTAssertEqual(command.maximumReadLength, 5000)
        XCTAssertTrue(command.singleStrand)
    }

    func testSavontClusterRejectsRawArguments() {
        XCTAssertThrowsError(try FastqSavontClusterSubcommand.parse([
            "/tmp/reads.fastq",
            "--output", "/tmp/clusters.fasta",
            "--extra-args", "--some-savont-option",
        ]))
    }

    func testSavontClusterBuildsValidatedRequest() throws {
        let command = try FastqSavontClusterSubcommand.parse([
            "/tmp/reads.fastq",
            "--output", "/tmp/clusters.fasta",
            "--threads", "0",
        ])

        XCTAssertThrowsError(try command.makeRequestForTesting()) { error in
            XCTAssertEqual(
                error as? SavontClusteringRunRequestError,
                .invalidThreads(0)
            )
            XCTAssertTrue(error.localizedDescription.contains("thread count must be positive"))
        }
    }

    func testSavontClusterRejectsInvertedLengthBoundsClearly() throws {
        let command = try FastqSavontClusterSubcommand.parse([
            "/tmp/reads.fastq",
            "--output", "/tmp/clusters.fasta",
            "--min-read-length", "5000",
            "--max-read-length", "500",
        ])

        XCTAssertThrowsError(try command.makeRequestForTesting()) { error in
            XCTAssertEqual(
                error as? SavontClusteringRunRequestError,
                .invalidReadLengthRange(minimum: 5000, maximum: 500)
            )
            XCTAssertTrue(error.localizedDescription.contains("cannot exceed maximum read length"))
        }
    }

    func testSavontClusterEncodesOnlyJSONToStdoutAndCleanupWarningToStderr() async throws {
        let command = try FastqSavontClusterSubcommand.parse([
            "/tmp/reads.fastq",
            "--output", "/tmp/clusters.fasta",
        ])
        let result = SavontClusteringResult(
            outputFASTAURL: URL(fileURLWithPath: "/tmp/clusters.fasta"),
            provenanceURL: URL(fileURLWithPath: "/tmp/.clusters.fasta.lungfish-provenance.json"),
            summary: SavontClusterSummary(clusterCount: 2, totalSupportingReads: 83),
            usedSingleThreadFallback: true,
            usedSingleStrandFallback: false,
            cleanupPendingURLs: [
                URL(fileURLWithPath: "/tmp/.clusters.fasta.backup"),
                URL(fileURLWithPath: "/tmp/.savont-run-retained"),
            ]
        )
        var receivedRequest: SavontClusteringRunRequest?
        var standardOutput = Data()
        var standardError = ""
        let runtime = FastqSavontClusterSubcommand.Runtime { request in
            receivedRequest = request
            return result
        }

        try await command.executeForTesting(
            runtime: runtime,
            emitStandardOutput: { standardOutput.append($0) },
            emitStandardError: { standardError += $0 }
        )

        XCTAssertEqual(receivedRequest, try command.makeRequestForTesting())
        XCTAssertEqual(
            String(decoding: standardOutput, as: UTF8.self),
            """
            {
              "cleanupPendingPaths" : [
                "/tmp/.clusters.fasta.backup",
                "/tmp/.savont-run-retained"
              ],
              "clusterCount" : 2,
              "outputFASTAPath" : "/tmp/clusters.fasta",
              "provenancePath" : "/tmp/.clusters.fasta.lungfish-provenance.json",
              "totalSupportingReads" : 83,
              "usedSingleStrandFallback" : false,
              "usedSingleThreadFallback" : true
            }

            """
        )
        XCTAssertEqual(
            standardError,
            "warning: Savont cleanup is pending for: /tmp/.clusters.fasta.backup, /tmp/.savont-run-retained\n"
        )
    }
}
