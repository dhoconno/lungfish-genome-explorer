import Foundation
@testable import LungfishWorkflow

enum ViralReconAppTestFixtures {
    static func illuminaRequest(root: URL) throws -> ViralReconRunRequest {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let outputs = root.appendingPathComponent("outputs", isDirectory: true)
        let primerBundle = root.appendingPathComponent("QIASeqDIRECT-SARS2.lungfishprimers", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: primerBundle, withIntermediateDirectories: true)

        let samplesheet = inputs.appendingPathComponent("samplesheet.csv")
        let read1 = inputs.appendingPathComponent("sample_R1.fastq.gz")
        let read2 = inputs.appendingPathComponent("sample_R2.fastq.gz")
        let primerBED = primerBundle.appendingPathComponent("primers.bed")
        let primerFASTA = primerBundle.appendingPathComponent("primers.fasta")

        try "sample,fastq_1,fastq_2\nSARS2_A,\(read1.path),\(read2.path)\n"
            .write(to: samplesheet, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: read1.path, contents: Data())
        FileManager.default.createFile(atPath: read2.path, contents: Data())
        try "MN908947.3\t1\t20\tSARS2_1_LEFT\nMN908947.3\t20\t40\tSARS2_1_RIGHT\n"
            .write(to: primerBED, atomically: true, encoding: .utf8)
        try ">SARS2_1_LEFT\nACGT\n>SARS2_1_RIGHT\nTGCA\n"
            .write(to: primerFASTA, atomically: true, encoding: .utf8)

        return try ViralReconRunRequest(
            samples: [
                ViralReconSample(
                    sampleName: "SARS2_A",
                    sourceBundleURL: root.appendingPathComponent("SARS2_A.lungfishfastq", isDirectory: true),
                    fastqURLs: [read1, read2],
                    barcode: nil,
                    sequencingSummaryURL: nil
                ),
            ],
            platform: .illumina,
            protocol: .amplicon,
            samplesheetURL: samplesheet,
            outputDirectory: outputs,
            executor: .docker,
            version: "3.0.0",
            reference: .genome("MN908947.3"),
            primer: ViralReconPrimerSelection(
                bundleURL: primerBundle,
                displayName: "QIASeq DIRECT SARS-CoV-2",
                bedURL: primerBED,
                fastaURL: primerFASTA,
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
    }

    static func nanoporeRequest(root: URL) throws -> ViralReconRunRequest {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputs = root.appendingPathComponent("nanopore-inputs", isDirectory: true)
        let outputs = root.appendingPathComponent("nanopore-outputs", isDirectory: true)
        let fastqPass = inputs.appendingPathComponent("fastq_pass", isDirectory: true)
        let barcodeDir = fastqPass.appendingPathComponent("barcode01", isDirectory: true)
        let primerBundle = root.appendingPathComponent("ONT-SARS2.lungfishprimers", isDirectory: true)
        try FileManager.default.createDirectory(at: barcodeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: primerBundle, withIntermediateDirectories: true)

        let samplesheet = inputs.appendingPathComponent("samplesheet.csv")
        let read = barcodeDir.appendingPathComponent("reads.fastq")
        let sequencingSummary = inputs.appendingPathComponent("sequencing_summary.txt")
        let primerBED = primerBundle.appendingPathComponent("primers.bed")
        let primerFASTA = primerBundle.appendingPathComponent("primers.fasta")

        try "sample,barcode\nONT_A,01\n".write(to: samplesheet, atomically: true, encoding: .utf8)
        try "@read\nACGT\n+\n!!!!\n".write(to: read, atomically: true, encoding: .utf8)
        try "filename\tread_id\nreads.fastq\tread\n".write(to: sequencingSummary, atomically: true, encoding: .utf8)
        try "MN908947.3\t1\t20\tONT_1_LEFT\nMN908947.3\t20\t40\tONT_1_RIGHT\n"
            .write(to: primerBED, atomically: true, encoding: .utf8)
        try ">ONT_1_LEFT\nACGT\n>ONT_1_RIGHT\nTGCA\n"
            .write(to: primerFASTA, atomically: true, encoding: .utf8)

        return try ViralReconRunRequest(
            samples: [
                ViralReconSample(
                    sampleName: "ONT_A",
                    sourceBundleURL: root.appendingPathComponent("ONT_A.lungfishfastq", isDirectory: true),
                    fastqURLs: [read],
                    barcode: "01",
                    sequencingSummaryURL: sequencingSummary
                ),
            ],
            platform: .nanopore,
            protocol: .amplicon,
            samplesheetURL: samplesheet,
            outputDirectory: outputs,
            executor: .docker,
            version: "3.0.0",
            reference: .genome("MN908947.3"),
            primer: ViralReconPrimerSelection(
                bundleURL: primerBundle,
                displayName: "ONT SARS-CoV-2",
                bedURL: primerBED,
                fastaURL: primerFASTA,
                leftSuffix: "_LEFT",
                rightSuffix: "_RIGHT",
                derivedFasta: false
            ),
            minimumMappedReads: 1000,
            variantCaller: .ivar,
            consensusCaller: .bcftools,
            skipOptions: [.kraken2],
            fastqPassDirectoryURL: fastqPass,
            sequencingSummaryURL: sequencingSummary
        )
    }
}
