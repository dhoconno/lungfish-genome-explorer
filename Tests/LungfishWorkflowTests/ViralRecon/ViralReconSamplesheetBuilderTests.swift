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

    func testIlluminaSamplesheetRejectsUncompressedFastqPaths() throws {
        let temp = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let uncompressedFastq = temp.appendingPathComponent("A_R2.fastq")
        let sample = ViralReconSample(
            sampleName: "A",
            sourceBundleURL: temp,
            fastqURLs: [
                temp.appendingPathComponent("A_R1.fastq.gz"),
                uncompressedFastq,
            ],
            barcode: nil,
            sequencingSummaryURL: nil
        )

        XCTAssertThrowsError(
            try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: [sample], in: temp)
        ) { error in
            XCTAssertEqual(
                error as? ViralReconSamplesheetBuilder.ValidationError,
                .unsupportedIlluminaFASTQ(uncompressedFastq)
            )
        }
    }

    func testIlluminaSamplesheetRejectsUncompressedFqPaths() throws {
        let temp = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let uncompressedFq = temp.appendingPathComponent("A_R1.fq")
        let sample = ViralReconSample(
            sampleName: "A",
            sourceBundleURL: temp,
            fastqURLs: [uncompressedFq],
            barcode: nil,
            sequencingSummaryURL: nil
        )

        XCTAssertThrowsError(
            try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: [sample], in: temp)
        ) { error in
            XCTAssertEqual(
                error as? ViralReconSamplesheetBuilder.ValidationError,
                .unsupportedIlluminaFASTQ(uncompressedFq)
            )
        }
    }

    // Trust session FIX-VR (F1, S2). viralrecon's samplesheet refuses a
    // `sample` cell with a space (`^\S+$`) and a read file whose name holds
    // one, and then the whole run fails. The builder refuses first, with
    // words that name the sample and say what to do, and writes no file.
    func testIlluminaSamplesheetRefusesASampleNameWithASpaceAndWritesNoFile() throws {
        let temp = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let sheetDirectory = temp.appendingPathComponent("sheet", isDirectory: true)
        let samples = [
            ViralReconSample(sampleName: "Sample_2", sourceBundleURL: temp, fastqURLs: [temp.appendingPathComponent("S2.fastq.gz")], barcode: nil, sequencingSummaryURL: nil),
            ViralReconSample(sampleName: "Sample 1", sourceBundleURL: temp, fastqURLs: [temp.appendingPathComponent("S1.fastq.gz")], barcode: nil, sequencingSummaryURL: nil),
        ]

        XCTAssertThrowsError(
            try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: samples, in: sheetDirectory)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The sample name “Sample 1” holds a space, and viralrecon's samplesheet does not accept one. "
                    + "Rename the sample, for example to “Sample_1”, and run again."
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sheetDirectory.appendingPathComponent("samplesheet.csv").path))
    }

    func testNanoporeStagingRefusesASampleNameWithASpaceBeforeCopyingReads() throws {
        let temp = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let sample = try makeNanoporeSample(name: "ONT A", barcode: "01", in: temp)

        XCTAssertThrowsError(try ViralReconSamplesheetBuilder.stageNanoporeInputs(samples: [sample], in: temp)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The sample name “ONT A” holds a space, and viralrecon's samplesheet does not accept one. "
                    + "Rename the sample, for example to “ONT_A”, and run again."
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("fastq_pass").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("samplesheet.csv").path))
    }

    // A paired row goes to viralrecon as named, so a space in either file
    // name is refused by name. A single file is not refused here: the run
    // may split it, and the split names its halves without a space.
    func testIlluminaSamplesheetRefusesAPairedReadFileWithASpaceInItsName() throws {
        let temp = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let r1 = temp.appendingPathComponent("Sample 1_R1.fastq.gz")
        let paired = ViralReconSample(
            sampleName: "Sample_1",
            sourceBundleURL: temp,
            fastqURLs: [r1, temp.appendingPathComponent("Sample_1_R2.fastq.gz")],
            barcode: nil,
            sequencingSummaryURL: nil
        )

        XCTAssertThrowsError(
            try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: [paired], in: temp)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The read file “Sample 1_R1.fastq.gz” of sample “Sample_1” holds a space in its name, "
                    + "and viralrecon's samplesheet does not accept one. Rename the file, "
                    + "for example to “Sample_1_R1.fastq.gz”, and run again."
            )
        }

        let single = ViralReconSample(
            sampleName: "Sample_1",
            sourceBundleURL: temp,
            fastqURLs: [temp.appendingPathComponent("Sample 1.fastq.gz")],
            barcode: nil,
            sequencingSummaryURL: nil
        )
        XCTAssertNoThrow(try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: [single], in: temp))
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
        XCTAssertTrue(csv.contains("ONT_A,1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fastqPassDirectory.appendingPathComponent("barcode01/reads.fastq").path))
    }

    func testNanoporeSamplesheetNormalizesBarcodeValuesForCsvAndDirectories() throws {
        let temp = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let samples = [
            try makeNanoporeSample(name: "ONT_A", barcode: "barcode01", in: temp),
            try makeNanoporeSample(name: "ONT_B", barcode: "BC02", in: temp),
            try makeNanoporeSample(name: "ONT_C", barcode: "03", in: temp),
            try makeNanoporeSample(name: "ONT_D", barcode: "4", in: temp),
        ]

        let staged = try ViralReconSamplesheetBuilder.stageNanoporeInputs(samples: samples, in: temp)
        let lines = try String(contentsOf: staged.samplesheetURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)

        XCTAssertEqual(lines, [
            "sample,barcode",
            "ONT_A,1",
            "ONT_B,2",
            "ONT_C,3",
            "ONT_D,4",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fastqPassDirectory.appendingPathComponent("barcode01/ONT_A.fastq").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fastqPassDirectory.appendingPathComponent("barcode02/ONT_B.fastq").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fastqPassDirectory.appendingPathComponent("barcode03/ONT_C.fastq").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fastqPassDirectory.appendingPathComponent("barcode04/ONT_D.fastq").path))
    }

    private func makeNanoporeSample(name: String, barcode: String, in directory: URL) throws -> ViralReconSample {
        let source = directory.appendingPathComponent("\(name).fastq")
        try "@\(name)\nACGT\n+\n!!!!\n".write(to: source, atomically: true, encoding: .utf8)
        return ViralReconSample(
            sampleName: name,
            sourceBundleURL: directory,
            fastqURLs: [source],
            barcode: barcode,
            sequencingSummaryURL: nil
        )
    }
}
