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

    func testWriterIndexesAndClustersFASTQReadsForPBAA() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-writer-fastq-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/data/reads.fastq"),
            guideSourceURL: URL(fileURLWithPath: "/data/guide.fasta"),
            outputDirectory: root.appendingPathComponent("result", isDirectory: true),
            outputName: "sample",
            threads: 4,
            seed: 7,
            extraArgumentsText: "--min-cluster-read-count 3"
        )

        let files = try PBAANextflowWorkflowWriter().writeWorkflow(for: request, to: root)
        let main = try String(contentsOf: files.mainNFURL, encoding: .utf8)
        let params = try JSONDecoder().decode(PBAANextflowParameters.self, from: Data(contentsOf: files.paramsURL))

        XCTAssertTrue(main.contains("samtools fqidx reads.fastq"))
        XCTAssertFalse(main.contains("samtools faidx reads.fasta"))
        XCTAssertTrue(main.contains("pbaa cluster -j ${params.threads} --seed ${params.seed} ${extra} guide.fasta reads.fastq ${params.prefix}"))
        XCTAssertEqual(params.reads, "/data/reads.fastq")
        XCTAssertEqual(params.readsFormat, "fastq")
    }

    func testWriterDecompressesGzippedGuideBeforeIndexing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-writer-gz-guide-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/data/reads.fastq"),
            guideSourceURL: URL(fileURLWithPath: "/project/Reference Sequences/guide.lungfishref/genome/sequence.fa.gz"),
            outputDirectory: root.appendingPathComponent("result", isDirectory: true),
            outputName: "sample"
        )

        let files = try PBAANextflowWorkflowWriter().writeWorkflow(for: request, to: root)
        let main = try String(contentsOf: files.mainNFURL, encoding: .utf8)

        XCTAssertTrue(main.contains("gzip -dc \"${guide}\" > guide.fasta"))
        XCTAssertTrue(main.contains("samtools faidx guide.fasta"))
    }

    func testNextflowArgumentsUseAbsoluteWorkflowFilesForLocalLaunchDirectory() {
        let workflowDirectory = URL(fileURLWithPath: "/Volumes/project/Analyses/pbaa-run/nextflow", isDirectory: true)

        let arguments = ProcessPBAANextflowRunner.nextflowArguments(workflowDirectory: workflowDirectory)

        XCTAssertEqual(arguments.prefix(3), ["nextflow", "run", "/Volumes/project/Analyses/pbaa-run/nextflow/main.nf"])
        let configIndex = try? XCTUnwrap(arguments.firstIndex(of: "-c"))
        let paramsIndex = try? XCTUnwrap(arguments.firstIndex(of: "-params-file"))
        XCTAssertEqual(configIndex.map { arguments[$0 + 1] }, "/Volumes/project/Analyses/pbaa-run/nextflow/nextflow.config")
        XCTAssertEqual(paramsIndex.map { arguments[$0 + 1] }, "/Volumes/project/Analyses/pbaa-run/nextflow/params.json")
    }
}
