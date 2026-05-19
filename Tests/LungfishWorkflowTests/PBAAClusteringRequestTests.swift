import XCTest
@testable import LungfishWorkflow

final class PBAAClusteringRequestTests: XCTestCase {
    func testContainerPinsAreVersionedAndDigestPinned() {
        XCTAssertEqual(PBAAContainerPins.workflowSchemaVersion, "pbaa-cluster/1")
        XCTAssertEqual(PBAAContainerPins.pbaa.reference, "quay.io/biocontainers/pbaa:1.2.0--h9ee0642_0")
        XCTAssertEqual(PBAAContainerPins.pbaa.expectedDigest, "sha256:fa48bd65b2e429af09eaf06541030e812e5bb0de440059b9b34a6e49c87edd04")
        XCTAssertEqual(PBAAContainerPins.samtools.reference, "quay.io/biocontainers/samtools:1.23.1--ha83d96e_0")
        XCTAssertEqual(PBAAContainerPins.samtools.expectedDigest, "sha256:23cda33a3a42125872766df9aaf1d2db67cdb8c85314b793465188435af31ba6")
    }

    func testRequestDefaultsKeepGuiSimple() throws {
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            guideSourceURL: URL(fileURLWithPath: "/tmp/guide.fasta"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            outputName: "sample-pbaa"
        )

        XCTAssertEqual(request.prefix, "sample-pbaa")
        XCTAssertEqual(request.threads, max(1, ProcessInfo.processInfo.activeProcessorCount))
        XCTAssertEqual(request.seed, 1984)
        XCTAssertEqual(request.extraArguments, [])
        XCTAssertEqual(request.containerPins, .current)
    }

    func testRequestParsesAdvancedOptions() throws {
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            guideSourceURL: URL(fileURLWithPath: "/tmp/guide.fasta"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            outputName: "sample-pbaa",
            extraArgumentsText: #"--min-cluster-read-count 2 --off-target-groups "off targets.txt""#
        )

        XCTAssertEqual(request.extraArguments, [
            "--min-cluster-read-count", "2",
            "--off-target-groups", "off targets.txt",
        ])
        XCTAssertEqual(request.extraArgumentsText, #"--min-cluster-read-count 2 --off-target-groups "off targets.txt""#)
    }
}
