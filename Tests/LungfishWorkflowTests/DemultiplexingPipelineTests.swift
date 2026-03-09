import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexingPipelineTests: XCTestCase {

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

        XCTAssertEqual(config.barcodeLocation, .anywhere)
        XCTAssertEqual(config.errorRate, 0.15, accuracy: 0.001)
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
            .outputParsingFailed("bad json"),
            .bundleCreationFailed(barcode: "D701", underlying: NSError(domain: "test", code: 1)),
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

    func testDemultiplexConfigAnywhereLocation() {
        let config = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/test.fastq.gz"),
            barcodeKit: IlluminaBarcodeKitRegistry.truseqSingleA,
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            barcodeLocation: .anywhere,
            errorRate: 0.2,
            minimumOverlap: 5,
            trimBarcodes: false,
            unassignedDisposition: .discard,
            threads: 8
        )

        XCTAssertEqual(config.barcodeLocation, .anywhere)
        XCTAssertEqual(config.errorRate, 0.2, accuracy: 0.001)
        XCTAssertEqual(config.minimumOverlap, 5)
        XCTAssertFalse(config.trimBarcodes)
        XCTAssertEqual(config.threads, 8)
    }
}
