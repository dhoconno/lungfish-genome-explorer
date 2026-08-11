import XCTest
@testable import LungfishWorkflow

final class FASTQClumpingToolTests: XCTestCase {
    func testDefaultIsAuto() {
        XCTAssertEqual(ClumpingTool.default, .auto)
    }

    func testRawValuesAreStableForCLIAndProvenance() {
        XCTAssertEqual(ClumpingTool.auto.rawValue, "auto")
        XCTAssertEqual(ClumpingTool.bbtools.rawValue, "bbtools")
        XCTAssertEqual(ClumpingTool.trimGalore.rawValue, "trim-galore")
        XCTAssertEqual(ClumpingTool.none.rawValue, "none")
    }

    func testTrimGaloreDisclosureWordingIsSharedAndOtherToolsHaveNone() {
        XCTAssertEqual(
            ClumpingTool.trimGalore.importSheetDisclosure,
            "Trim Galore also performs adapter detection/removal, quality trimming, and short-read filtering."
        )
        XCTAssertEqual(
            ClumpingTool.trimGalore.operationNotice,
            "Trim Galore --clumpify also performs adapter/quality filtering and may remove short reads."
        )
        XCTAssertNil(ClumpingTool.auto.importSheetDisclosure)
        XCTAssertNil(ClumpingTool.bbtools.importSheetDisclosure)
        XCTAssertNil(ClumpingTool.none.importSheetDisclosure)
        XCTAssertNil(ClumpingTool.auto.operationNotice)
        XCTAssertNil(ClumpingTool.bbtools.operationNotice)
        XCTAssertNil(ClumpingTool.none.operationNotice)
    }

    func testAutoChoosesBBToolsWhenEstimatedInputIsSafelyBelowHeapThreshold() {
        let resolution = ClumpingTool.auto.resolve(
            estimatedInputBytes: 10 * Self.gib,
            physicalMemoryBytes: 64 * Self.gib
        )

        XCTAssertEqual(resolution.requested, .auto)
        XCTAssertEqual(resolution.resolved, .bbtools)
        XCTAssertEqual(resolution.clumpifyHeapBytes, 31 * Self.gib)
        XCTAssertEqual(resolution.thresholdBytes, (31 * Self.gib) / 2)
    }

    func testAutoChoosesTrimGaloreWhenEstimatedInputMayPressureBBToolsHeap() {
        let resolution = ClumpingTool.auto.resolve(
            estimatedInputBytes: 20 * Self.gib,
            physicalMemoryBytes: 64 * Self.gib
        )

        XCTAssertEqual(resolution.resolved, .trimGalore)
        XCTAssertTrue(resolution.reason.contains("memory pressure"))
    }

    func testExplicitChoicesBypassAutoHeuristic() {
        XCTAssertEqual(ClumpingTool.bbtools.resolve(estimatedInputBytes: 100 * Self.gib, physicalMemoryBytes: 8 * Self.gib).resolved, .bbtools)
        XCTAssertEqual(ClumpingTool.trimGalore.resolve(estimatedInputBytes: 1, physicalMemoryBytes: 64 * Self.gib).resolved, .trimGalore)
        XCTAssertEqual(ClumpingTool.none.resolve(estimatedInputBytes: 1, physicalMemoryBytes: 64 * Self.gib).resolved, .none)
    }

    func testTrimGaloreArgumentsUseClumpifyAndMinimumTwoCores() {
        let input = URL(fileURLWithPath: "/data/sample.fastq.gz")
        let output = URL(fileURLWithPath: "/tmp/out")

        let args = FASTQIngestionPipeline.trimGaloreClumpifyArguments(
            inputFiles: [input],
            outputDirectory: output,
            pairingMode: .singleEnd,
            threads: 1,
            compressionLevel: .balanced,
            memoryBytes: 8 * Self.gib
        )

        XCTAssertTrue(args.contains("--clumpify"))
        XCTAssertFalse(args.contains("--gzip"))
        XCTAssertEqual(args[args.firstIndex(of: "--cores")! + 1], "2")
        XCTAssertEqual(args[args.firstIndex(of: "--compression")! + 1], "4")
        XCTAssertEqual(args[args.firstIndex(of: "--memory")! + 1], "8G")
        XCTAssertFalse(args.contains("--paired"))
    }

    func testTrimGaloreArgumentsMarkPairedEndInputs() {
        let args = FASTQIngestionPipeline.trimGaloreClumpifyArguments(
            inputFiles: [
                URL(fileURLWithPath: "/data/sample_R1.fastq.gz"),
                URL(fileURLWithPath: "/data/sample_R2.fastq.gz"),
            ],
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            pairingMode: .pairedEnd,
            threads: 8,
            compressionLevel: .maximum,
            memoryBytes: 4 * Self.gib
        )

        XCTAssertTrue(args.contains("--paired"))
        XCTAssertEqual(args[args.firstIndex(of: "--cores")! + 1], "8")
        XCTAssertEqual(args[args.firstIndex(of: "--compression")! + 1], "9")
    }

    private static let gib: Int64 = 1_073_741_824
}
