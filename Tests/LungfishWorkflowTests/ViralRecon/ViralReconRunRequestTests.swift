import XCTest
@testable import LungfishWorkflow

final class ViralReconRunRequestTests: XCTestCase {
    func testIlluminaRequestBuildsViralReconCLIArgumentsWithGeneratedParameters() throws {
        let input = URL(fileURLWithPath: "/tmp/run/inputs/samplesheet.csv")
        let output = URL(fileURLWithPath: "/tmp/run/outputs")
        let request = try ViralReconRunRequest(
            samples: [
                ViralReconSample(
                    sampleName: "SARS2_A",
                    sourceBundleURL: URL(fileURLWithPath: "/tmp/A.lungfishfastq"),
                    fastqURLs: [
                        URL(fileURLWithPath: "/tmp/A_R1.fastq.gz"),
                        URL(fileURLWithPath: "/tmp/A_R2.fastq.gz"),
                    ],
                    barcode: nil,
                    sequencingSummaryURL: nil
                )
            ],
            platform: .illumina,
            protocol: .amplicon,
            samplesheetURL: input,
            outputDirectory: output,
            executor: .docker,
            version: "3.0.0",
            reference: .genome("MN908947.3"),
            primer: ViralReconPrimerSelection(
                bundleURL: URL(fileURLWithPath: "/tmp/QIASeqDIRECT-SARS2.lungfishprimers"),
                displayName: "QIASeq DIRECT SARS-CoV-2",
                bedURL: URL(fileURLWithPath: "/tmp/primers.bed"),
                fastaURL: URL(fileURLWithPath: "/tmp/primers.fasta"),
                leftSuffix: "_LEFT",
                rightSuffix: "_RIGHT",
                derivedFasta: true
            ),
            minimumMappedReads: 1000,
            variantCaller: .ivar,
            consensusCaller: .bcftools,
            skipOptions: [.assembly, .kraken2],
            advancedParams: ["max_cpus": "4", "max_memory": "8.GB"]
        )

        let args = request.cliArguments(bundlePath: URL(fileURLWithPath: "/tmp/run/viralrecon.lungfishrun"))

        XCTAssertEqual(args.prefix(3), ["workflow", "run", "nf-core/viralrecon"])
        XCTAssertTrue(args.contains("--version"))
        XCTAssertTrue(args.contains("3.0.0"))
        XCTAssertTrue(args.contains("--param"))
        XCTAssertTrue(args.contains("platform=illumina"))
        XCTAssertTrue(args.contains("protocol=amplicon"))
        XCTAssertTrue(args.contains("genome=MN908947.3"))
        XCTAssertTrue(args.contains("primer_bed=/tmp/primers.bed"))
        XCTAssertTrue(args.contains("primer_fasta=/tmp/primers.fasta"))
        XCTAssertTrue(args.contains("skip_assembly=true"))
        XCTAssertTrue(args.contains("skip_kraken2=true"))
    }

    func testAdvancedParamsRejectGeneratedKeys() {
        XCTAssertThrowsError(
            try ViralReconRunRequest.validateAdvancedParams(["input": "manual.csv"])
        ) { error in
            XCTAssertEqual(error as? ViralReconRunRequest.ValidationError, .conflictingAdvancedParam("input"))
        }
    }

    func testNanoporeRequestEmitsFastqDirAndDiscoveredSequencingSummary() throws {
        let temp = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let samplesheet = temp.appendingPathComponent("samplesheet.csv")
        let output = temp.appendingPathComponent("outputs", isDirectory: true)
        let fastqPass = temp.appendingPathComponent("fastq_pass", isDirectory: true)
        let summary = temp.appendingPathComponent("sequencing_summary.txt")
        try FileManager.default.createDirectory(at: fastqPass, withIntermediateDirectories: true)
        try "filename\tread_id\n".write(to: summary, atomically: true, encoding: .utf8)

        let request = try ViralReconRunRequest(
            samples: [
                ViralReconSample(
                    sampleName: "ONT_A",
                    sourceBundleURL: temp.appendingPathComponent("ONT_A.lungfishfastq"),
                    fastqURLs: [temp.appendingPathComponent("ONT_A.fastq")],
                    barcode: "01",
                    sequencingSummaryURL: summary
                )
            ],
            platform: .nanopore,
            protocol: .amplicon,
            samplesheetURL: samplesheet,
            outputDirectory: output,
            executor: .docker,
            version: "3.0.0",
            reference: .genome("MN908947.3"),
            primer: ViralReconPrimerSelection(
                bundleURL: temp.appendingPathComponent("QIASeqDIRECT-SARS2.lungfishprimers"),
                displayName: "QIASeq DIRECT SARS-CoV-2",
                bedURL: temp.appendingPathComponent("primers.bed"),
                fastaURL: temp.appendingPathComponent("primers.fasta"),
                leftSuffix: "_LEFT",
                rightSuffix: "_RIGHT",
                derivedFasta: true
            ),
            minimumMappedReads: 1000,
            variantCaller: .ivar,
            consensusCaller: .bcftools,
            skipOptions: [],
            advancedParams: [:],
            fastqPassDirectoryURL: fastqPass
        )

        let args = request.cliArguments(bundlePath: temp.appendingPathComponent("viralrecon.lungfishrun"))

        XCTAssertTrue(args.contains("fastq_dir=\(fastqPass.path)"))
        XCTAssertTrue(args.contains("sequencing_summary=\(summary.path)"))
    }

    func testAdvancedParamsRejectGeneratedNanoporeKeys() {
        XCTAssertThrowsError(
            try ViralReconRunRequest.validateAdvancedParams(["fastq_dir": "/tmp/fastq_pass"])
        ) { error in
            XCTAssertEqual(error as? ViralReconRunRequest.ValidationError, .conflictingAdvancedParam("fastq_dir"))
        }
        XCTAssertThrowsError(
            try ViralReconRunRequest.validateAdvancedParams(["sequencing_summary": "/tmp/sequencing_summary.txt"])
        ) { error in
            XCTAssertEqual(error as? ViralReconRunRequest.ValidationError, .conflictingAdvancedParam("sequencing_summary"))
        }
    }
}
