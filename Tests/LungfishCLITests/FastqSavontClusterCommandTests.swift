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

    func testSavontClusterEncodesOnlyJSONToStdoutAndWarningsAndProgressToStderr() async throws {
        let command = try FastqSavontClusterSubcommand.parse([
            "/tmp/reads.fastq",
            "--output", "/tmp/clusters.fasta",
        ])
        let result = SavontClusteringResult(
            outputFASTAURL: URL(fileURLWithPath: "/tmp/clusters.fasta"),
            provenanceURL: URL(fileURLWithPath: "/tmp/.clusters.fasta.lungfish-provenance.json"),
            summary: SavontClusterSummary(clusterCount: 2, totalSupportingReads: 83),
            usedSingleThreadFallback: true,
            usedSingleStrandFallback: true,
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
              "usedSingleStrandFallback" : true,
              "usedSingleThreadFallback" : true
            }

            """
        )
        XCTAssertEqual(
            standardError,
            """
            Savont clustering started: /tmp/reads.fastq -> /tmp/clusters.fasta
            warning: Savont used the single-thread fallback.
            warning: Savont used the single-strand fallback.
            Savont clustering complete: 2 clusters, 83 supporting reads.
            warning: Savont cleanup is pending for: /tmp/.clusters.fasta.backup, /tmp/.savont-run-retained

            """
        )
    }

    func testSavontClusterOrdinarySuccessReportsProgressWithoutWarnings() async throws {
        let command = try FastqSavontClusterSubcommand.parse([
            "/tmp/ordinary.fastq",
            "--output", "/tmp/ordinary-clusters.fasta",
        ])
        let result = SavontClusteringResult(
            outputFASTAURL: URL(fileURLWithPath: "/tmp/ordinary-clusters.fasta"),
            provenanceURL: URL(fileURLWithPath: "/tmp/.ordinary-clusters.fasta.lungfish-provenance.json"),
            summary: SavontClusterSummary(clusterCount: 1, totalSupportingReads: 9),
            usedSingleThreadFallback: false,
            usedSingleStrandFallback: false
        )
        var events: [String] = []
        var standardOutput = Data()
        let runtime = FastqSavontClusterSubcommand.Runtime { _ in
            events.append("pipeline")
            return result
        }

        try await command.executeForTesting(
            runtime: runtime,
            emitStandardOutput: {
                events.append("stdout")
                standardOutput.append($0)
            },
            emitStandardError: { events.append($0) }
        )

        XCTAssertEqual(events, [
            "Savont clustering started: /tmp/ordinary.fastq -> /tmp/ordinary-clusters.fasta\n",
            "pipeline",
            "Savont clustering complete: 1 cluster, 9 supporting reads.\n",
            "stdout",
        ])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: standardOutput) as? [String: Any]
        )
        XCTAssertEqual(object["cleanupPendingPaths"] as? [String], [])
        XCTAssertEqual(object["usedSingleThreadFallback"] as? Bool, false)
        XCTAssertEqual(object["usedSingleStrandFallback"] as? Bool, false)
    }

    func testSavontClusterWarnsWhenEmptyFASTAIsPublishedInRequestedSingleStrandMode() async throws {
        let command = try FastqSavontClusterSubcommand.parse([
            "/tmp/low-snpmer.fastq",
            "--output", "/tmp/empty-clusters.fasta",
            "--single-strand",
        ])
        let result = SavontClusteringResult(
            outputFASTAURL: URL(fileURLWithPath: "/tmp/empty-clusters.fasta"),
            provenanceURL: URL(fileURLWithPath: "/tmp/.empty-clusters.fasta.lungfish-provenance.json"),
            summary: SavontClusterSummary(clusterCount: 0, totalSupportingReads: 0),
            usedSingleThreadFallback: false,
            usedSingleStrandFallback: false
        )
        var receivedRequest: SavontClusteringRunRequest?
        var standardOutput = Data()
        var standardError = ""

        try await command.executeForTesting(
            runtime: FastqSavontClusterSubcommand.Runtime { request in
                receivedRequest = request
                return result
            },
            emitStandardOutput: { standardOutput.append($0) },
            emitStandardError: { standardError += $0 }
        )

        XCTAssertEqual(receivedRequest?.singleStrand, true)
        XCTAssertEqual(
            standardError,
            """
            Savont clustering started: /tmp/low-snpmer.fastq -> /tmp/empty-clusters.fasta
            warning: Savont produced no clusters after running in single-strand mode; an empty FASTA was published.
            Savont clustering complete: 0 clusters, 0 supporting reads.

            """
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: standardOutput) as? [String: Any]
        )
        XCTAssertEqual(object["clusterCount"] as? Int, 0)
        XCTAssertEqual(object["totalSupportingReads"] as? Int, 0)
    }
}
