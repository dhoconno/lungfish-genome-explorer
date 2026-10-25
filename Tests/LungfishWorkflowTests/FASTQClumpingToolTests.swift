import XCTest
import LungfishCore
import LungfishIO
import LungfishPortable
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

    /// C5 O49, D5: `auto` is one rule. It names BBTools clumpify at the clumpify heap, reads no estimate and compares no
    /// threshold, and its source is `default`.
    func testAutoChoosesBBToolsAtTheClumpifyHeapWithNoEstimate() {
        let resolution = ClumpingTool.auto.resolve(
            estimatedInputBytes: 10 * Self.gib,
            physicalMemoryBytes: 64 * Self.gib
        )

        XCTAssertEqual(resolution.requested, .auto)
        XCTAssertEqual(resolution.resolved, .bbtools)
        // ManagedJavaHeapPolicy: 35 % of 64 GB = 22 GB, so a second managed
        // tool (e.g. a 16 GB Kraken2 database) can be resident at the same time.
        XCTAssertEqual(resolution.clumpifyHeapBytes, 22 * Self.gib)
        XCTAssertNil(resolution.estimatedInputBytes, "auto reads no estimate, as the plan has none")
        XCTAssertNil(resolution.thresholdBytes, "auto compares nothing with half the heap")
        XCTAssertEqual(resolution.reason, ClumpingTool.automaticClumpifyReason)
        XCTAssertEqual(resolution.resolvedSource, .default)
    }

    /// C5 O49 (replaces the C4-4 D-6 skip): at a pinned 1 GB heap `auto` clumps at every size, below, at and above half the
    /// heap, since clumpify's groups=auto splits a large input to fit the heap. The pinned heap, not the host's memory,
    /// sets the heap.
    func testAutoAtAPinnedOneGBHeapClumpsAtEverySize() {
        let half: Int64 = 536_870_912
        for size in [349_495_473, half, half + 1, 20 * Self.gib] {
            let resolution = ClumpingTool.auto.resolve(estimatedInputBytes: size, physicalMemoryBytes: 64 * Self.gib, pinnedHeapGB: 1)
            XCTAssertEqual(resolution.resolved, .bbtools, "\(size)")
            XCTAssertEqual(resolution.clumpifyHeapBytes, Self.gib, "\(size)")
            XCTAssertEqual(resolution.reason, ClumpingTool.automaticClumpifyReason, "\(size)")
            XCTAssertNil(resolution.thresholdBytes, "\(size)")
        }
    }

    /// D8 B: platform first. Short reads and a caller that names no platform clump, ONT and PacBio clump nothing with a
    /// reason that cites the error rate, Unknown clumps nothing, and a named tool wins with source `option`.
    func testAutoIsDecidedPlatformFirstAndANamedToolWins() {
        for platform in [LungfishIO.SequencingPlatform?.none, .illumina, .element, .mgi, .ultima] {
            let resolution = ClumpingTool.auto.resolve(estimatedInputBytes: 1, physicalMemoryBytes: 64 * Self.gib, platform: platform)
            XCTAssertEqual(resolution.resolved, .bbtools, platform?.rawValue ?? "no platform")
            XCTAssertEqual(resolution.reason, ClumpingTool.automaticClumpifyReason)
        }
        for platform in [LungfishIO.SequencingPlatform.oxfordNanopore, .pacbio] {
            let resolution = ClumpingTool.auto.resolve(estimatedInputBytes: 1, physicalMemoryBytes: 64 * Self.gib, platform: platform)
            XCTAssertEqual(resolution.resolved, ClumpingTool.none, platform.rawValue)
            XCTAssertEqual(resolution.resolvedSource, .default, platform.rawValue)
            XCTAssertTrue(resolution.reason.contains("high error rate"), resolution.reason)
            XCTAssertFalse(resolution.reason.contains("costs time and memory"), resolution.reason)
        }
        let unknown = ClumpingTool.auto.resolve(estimatedInputBytes: 1, physicalMemoryBytes: 64 * Self.gib, platform: .unknown)
        XCTAssertEqual(unknown.resolved, ClumpingTool.none)
        XCTAssertEqual(unknown.reason, ClumpingTool.automaticUnknownPlatformReason)
        let named = ClumpingTool.bbtools.resolve(estimatedInputBytes: 1, physicalMemoryBytes: 64 * Self.gib, platform: .oxfordNanopore)
        XCTAssertEqual(named.resolved, .bbtools)
        XCTAssertEqual(named.resolvedSource, .option)
    }

    func testExplicitChoicesBypassAutoHeuristic() {
        XCTAssertEqual(ClumpingTool.bbtools.resolve(estimatedInputBytes: 100 * Self.gib, physicalMemoryBytes: 8 * Self.gib).resolved, .bbtools)
        XCTAssertEqual(ClumpingTool.trimGalore.resolve(estimatedInputBytes: 1, physicalMemoryBytes: 64 * Self.gib).resolved, .trimGalore)
        XCTAssertEqual(ClumpingTool.none.resolve(estimatedInputBytes: 1, physicalMemoryBytes: 64 * Self.gib).resolved, .none)
        let named = ClumpingTool.bbtools.resolve(estimatedInputBytes: 5, physicalMemoryBytes: 64 * Self.gib)
        XCTAssertEqual(named.estimatedInputBytes, 5, "a named tool keeps the size the caller measured")
        XCTAssertEqual(named.thresholdBytes, 11 * Self.gib)
        XCTAssertEqual(named.reason, "explicit clumping tool selection")
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
