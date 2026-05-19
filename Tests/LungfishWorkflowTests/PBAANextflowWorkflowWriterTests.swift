import XCTest
@testable import LungfishWorkflow

final class PBAANextflowWorkflowWriterTests: XCTestCase {
    func testWriterCreatesMainConfigAndParams() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-writer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/data/reads.fastq"),
            guideSourceURL: URL(fileURLWithPath: "/data/guide.fasta"),
            outputDirectory: root.appendingPathComponent("result", isDirectory: true),
            outputName: "sample",
            threads: 4,
            seed: 7,
            extraArgumentsText: "--min-cluster-read-count 2"
        )

        let files = try PBAANextflowWorkflowWriter().writeWorkflow(for: request, to: root)
        let main = try String(contentsOf: files.mainNFURL, encoding: .utf8)
        let config = try String(contentsOf: files.configURL, encoding: .utf8)
        let params = try JSONDecoder().decode(PBAANextflowParameters.self, from: Data(contentsOf: files.paramsURL))

        XCTAssertTrue(main.contains("process INDEX_GUIDE"))
        XCTAssertTrue(main.contains("process INDEX_READS"))
        XCTAssertTrue(main.contains("process PBAA_CLUSTER"))
        XCTAssertTrue(main.contains("pbaa cluster"))
        XCTAssertTrue(config.contains("quay.io/biocontainers/pbaa:1.2.0--h9ee0642_0"))
        XCTAssertTrue(config.contains("@sha256:fa48bd65b2e429af09eaf06541030e812e5bb0de440059b9b34a6e49c87edd04"))
        XCTAssertTrue(config.contains("quay.io/biocontainers/samtools:1.23.1--ha83d96e_0"))
        XCTAssertTrue(config.contains("@sha256:23cda33a3a42125872766df9aaf1d2db67cdb8c85314b793465188435af31ba6"))
        XCTAssertEqual(params.outdir, request.rawPBAAOutputDirectory.path)
        XCTAssertEqual(params.prefix, "sample")
        XCTAssertEqual(params.threads, 4)
        XCTAssertEqual(params.seed, 7)
        XCTAssertEqual(params.extraArguments, ["--min-cluster-read-count", "2"])
    }
}
