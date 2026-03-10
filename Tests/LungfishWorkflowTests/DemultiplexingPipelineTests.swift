import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexingPipelineTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemultiplexingPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFASTQ(sequences: [String], to url: URL) throws {
        var lines: [String] = []
        lines.reserveCapacity(sequences.count * 4)
        for (idx, sequence) in sequences.enumerated() {
            lines.append("@read_\(idx)")
            lines.append(sequence)
            lines.append("+")
            lines.append(String(repeating: "I", count: sequence.count))
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - NativeTool.cutadapt Registration

    func testCutadaptRegistered() {
        XCTAssertEqual(NativeTool.cutadapt.executableName, "cutadapt")
        XCTAssertEqual(NativeTool.cutadapt.relativeExecutablePath, "cutadapt")
        XCTAssertEqual(NativeTool.cutadapt.sourcePackage, "cutadapt")
        XCTAssertEqual(NativeTool.cutadapt.license, "MIT License")
        XCTAssertFalse(NativeTool.cutadapt.isBBToolsShellScript)
        XCTAssertFalse(NativeTool.cutadapt.isHtslib)
    }

    func testCutadaptInBundledVersions() {
        XCTAssertEqual(NativeToolRunner.bundledVersions["cutadapt"], "4.9")
    }

    func testCutadaptInCaseIterable() {
        XCTAssertTrue(NativeTool.allCases.contains(.cutadapt))
    }

    func testCutadaptExecutableSmokeTest() async throws {
        let runner = NativeToolRunner.shared
        let path = try await runner.findTool(.cutadapt)
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: path.path),
            "cutadapt should resolve to an executable: \(path.path)"
        )

        let result = try await runner.run(.cutadapt, arguments: ["--version"])
        XCTAssertTrue(result.isSuccess, "cutadapt --version should succeed")
        let output = result.stdout + result.stderr
        XCTAssertTrue(output.contains("4."), "Expected cutadapt version output, got: \(output)")
    }

    // MARK: - DemultiplexConfig

    func testDemultiplexConfigDefaults() {
        let config = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/test.fastq.gz"),
            barcodeKit: IlluminaBarcodeKitRegistry.truseqSingleA,
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )

        XCTAssertEqual(config.barcodeLocation, .bothEnds)
        XCTAssertEqual(config.errorRate, 0.10, accuracy: 0.001)
        XCTAssertEqual(config.minimumOverlap, 3)
        XCTAssertTrue(config.trimBarcodes)
        XCTAssertEqual(config.threads, 4)
    }

    // MARK: - DemultiplexError

    func testDemultiplexErrorDescriptions() {
        let errors: [DemultiplexError] = [
            .inputFileNotFound(URL(fileURLWithPath: "/tmp/test.fastq")),
            .cutadaptFailed(exitCode: 1, stderr: "error message"),
            .noBarcodes,
            .combinatorialRequiresSampleAssignments,
            .outputParsingFailed("bad json"),
            .bundleCreationFailed(barcode: "D701", underlying: "test error"),
            .noOutputResults,
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have description")
        }
    }

    // MARK: - Pipeline Instantiation

    func testPipelineCanBeInstantiated() {
        let pipeline = DemultiplexingPipeline()
        XCTAssertNotNil(pipeline)
    }

    // MARK: - DemultiplexConfig Custom Location

    func testDemultiplexConfigBothEndsLocation() {
        let config = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/test.fastq.gz"),
            barcodeKit: IlluminaBarcodeKitRegistry.truseqSingleA,
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            barcodeLocation: .bothEnds,
            errorRate: 0.2,
            minimumOverlap: 5,
            trimBarcodes: false,
            unassignedDisposition: .discard,
            threads: 8
        )

        XCTAssertEqual(config.barcodeLocation, .bothEnds)
        XCTAssertEqual(config.errorRate, 0.2, accuracy: 0.001)
        XCTAssertEqual(config.minimumOverlap, 5)
        XCTAssertFalse(config.trimBarcodes)
        XCTAssertEqual(config.threads, 8)
    }

    func testFixedDualLinkedAdaptersMatchBothOrientations() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let inputFASTQ = dir.appendingPathComponent("input.fastq")
        try writeFASTQ(
            sequences: [
                "ACGTACGTAAAAAATGCATGCA",   // i7 ... i5
                "TGCATGCATTTTTTACGTACGT",   // i5 ... i7 (swapped orientation)
                "GGGGGGGGCCCCCCCC",         // unassigned
            ],
            to: inputFASTQ
        )

        let outputDir = dir.appendingPathComponent("demux-out", isDirectory: true)
        let kit = IlluminaBarcodeDefinition(
            id: "fixed-dual-test",
            displayName: "Fixed Dual Test",
            vendor: "custom",
            isDualIndexed: true,
            pairingMode: .fixedDual,
            barcodes: [
                IlluminaBarcode(id: "P01", i7Sequence: "ACGTACGT", i5Sequence: "TGCATGCA"),
            ]
        )

        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: kit,
                outputDirectory: outputDir,
                barcodeLocation: .bothEnds,
                errorRate: 0.0,
                minimumOverlap: 8,
                trimBarcodes: true,
                threads: 1
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.manifest.inputReadCount, 3)
        XCTAssertEqual(result.manifest.barcodes.count, 1)
        XCTAssertEqual(result.manifest.barcodes.first?.barcodeID, "P01")
        XCTAssertEqual(result.manifest.barcodes.first?.readCount, 2)
        XCTAssertEqual(result.manifest.unassigned.readCount, 1)
    }
}
