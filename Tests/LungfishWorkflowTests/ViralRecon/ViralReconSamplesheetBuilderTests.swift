import XCTest
@testable import LungfishWorkflow

final class ViralReconSamplesheetBuilderTests: XCTestCase {
    func testIlluminaSamplesheetWritesMultipleBundleRows() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let samples = [
            ViralReconSample(sampleName: "A", sourceBundleURL: temp, fastqURLs: [temp.appendingPathComponent("A_R1.fastq.gz"), temp.appendingPathComponent("A_R2.fastq.gz")], barcode: nil, sequencingSummaryURL: nil),
            ViralReconSample(sampleName: "B", sourceBundleURL: temp, fastqURLs: [temp.appendingPathComponent("B.fastq.gz")], barcode: nil, sequencingSummaryURL: nil),
        ]

        let url = try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: samples, in: temp)
        let csv = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(csv.contains("sample,fastq_1,fastq_2"))
        XCTAssertTrue(csv.contains("A,\(temp.path)/A_R1.fastq.gz,\(temp.path)/A_R2.fastq.gz"))
        XCTAssertTrue(csv.contains("B,\(temp.path)/B.fastq.gz,"))
    }

    func testIlluminaSamplesheetPreservesFourFastqsAsRepeatedRows() throws {
        let temp = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let sample = ViralReconSample(
            sampleName: "A",
            sourceBundleURL: temp,
            fastqURLs: [
                temp.appendingPathComponent("A_L001_R1.fastq.gz"),
                temp.appendingPathComponent("A_L001_R2.fastq.gz"),
                temp.appendingPathComponent("A_L002_R1.fastq.gz"),
                temp.appendingPathComponent("A_L002_R2.fastq.gz"),
            ],
            barcode: nil,
            sequencingSummaryURL: nil
        )

        let url = try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: [sample], in: temp)
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)

        XCTAssertEqual(lines, [
            "sample,fastq_1,fastq_2",
            "A,\(temp.path)/A_L001_R1.fastq.gz,\(temp.path)/A_L001_R2.fastq.gz",
            "A,\(temp.path)/A_L002_R1.fastq.gz,\(temp.path)/A_L002_R2.fastq.gz",
        ])
    }

    func testNanoporeSamplesheetStagesFastqPassAndBarcodes() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = temp.appendingPathComponent("reads.fastq")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try "@read\nACGT\n+\n!!!!\n".write(to: source, atomically: true, encoding: .utf8)
        let samples = [
            ViralReconSample(sampleName: "ONT_A", sourceBundleURL: temp, fastqURLs: [source], barcode: "01", sequencingSummaryURL: nil)
        ]

        let staged = try ViralReconSamplesheetBuilder.stageNanoporeInputs(samples: samples, in: temp)
        let csv = try String(contentsOf: staged.samplesheetURL, encoding: .utf8)

        XCTAssertTrue(csv.contains("sample,barcode"))
        XCTAssertTrue(csv.contains("ONT_A,01"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fastqPassDirectory.appendingPathComponent("barcode01/reads.fastq").path))
    }
}
