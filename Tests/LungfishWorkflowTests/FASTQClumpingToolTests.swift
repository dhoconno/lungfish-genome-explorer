import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class FASTQClumpingToolTests: XCTestCase {
    func testDefaultIsAuto() {
        XCTAssertEqual(ClumpingTool.default, .auto)
    }

    #if DEBUG
    /// `clumpifyHeapBytes` models a host of the size it is given. The debug heap pin (Phase 2.10 FX47 (i)) sizes the
    /// heap a run hands a tool and must not move that model.
    func testTheHeapPinDoesNotMoveTheBudgetOfAHypotheticalHost() {
        let name = ManagedJavaHeapPolicy.pinnedHeapVariable
        let previous = getenv(name).map { String(cString: $0) }
        setenv(name, "3", 1)
        defer { if let previous { setenv(name, previous, 1) } else { unsetenv(name) } }
        XCTAssertEqual(ClumpingTool.clumpifyHeapBytes(physicalMemoryBytes: 64 * Self.gib), 22 * Self.gib)
    }
    #endif

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
        // ManagedJavaHeapPolicy: 35 % of 64 GB = 22 GB, so a second managed
        // tool (e.g. a 16 GB Kraken2 database) can be resident at the same time.
        XCTAssertEqual(resolution.clumpifyHeapBytes, 22 * Self.gib)
        XCTAssertEqual(resolution.thresholdBytes, (22 * Self.gib) / 2)
    }

    func testAutoSkipsClumpingWhenEstimatedInputMayPressureBBToolsHeap() {
        // Auto never silently substitutes Trim
        // Galore, which also filters/trims reads, for a memory reason alone.
        // Above the BBTools clumpify budget, auto now skips clumping entirely
        // rather than picking a tool with side effects the user did not request.
        let resolution = ClumpingTool.auto.resolve(
            estimatedInputBytes: 20 * Self.gib,
            physicalMemoryBytes: 64 * Self.gib
        )

        XCTAssertEqual(resolution.resolved, .none)
        XCTAssertTrue(resolution.reason.contains("exceeds the BBTools clumpify memory budget"))
    }

    /// Vote C4-4 D-6 (option 1; QA Q4-14, BIO B-D6-3, SWIFT SW4-13, UX U4-9): at a pinned 1 GB heap the automatic choice keeps
    /// BBTools for an estimated input of at most half the heap, the `<=` at `ClumpingTool.swift:64`, and skips clumping one
    /// byte above it, with the reason the Mac's import states. The pinned heap, not the host's memory, sets the threshold.
    func testAutoAtAPinnedOneGBHeapSkipsClumpingJustAboveHalfTheHeap() {
        let half: Int64 = 536_870_912
        let atHalf = ClumpingTool.auto.resolve(estimatedInputBytes: half, physicalMemoryBytes: 64 * Self.gib, pinnedHeapGB: 1)
        XCTAssertEqual(atHalf.resolved, .bbtools)
        XCTAssertEqual(atHalf.thresholdBytes, half)

        let above = ClumpingTool.auto.resolve(estimatedInputBytes: half + 1, physicalMemoryBytes: 64 * Self.gib, pinnedHeapGB: 1)
        XCTAssertEqual(above.resolved, ClumpingTool.none)
        XCTAssertEqual(above.thresholdBytes, half)
        XCTAssertEqual(above.reason, "skipped clumping: estimated input exceeds the BBTools clumpify memory budget")

        let below = ClumpingTool.auto.resolve(estimatedInputBytes: 349_495_473, physicalMemoryBytes: 64 * Self.gib, pinnedHeapGB: 1)
        XCTAssertEqual(below.resolved, .bbtools)
        XCTAssertEqual(below.thresholdBytes, half)
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
