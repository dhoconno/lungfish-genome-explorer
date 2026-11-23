// DemultiplexBothEndsOverlapTests.swift - At Both Ends a two-barcode kit's second barcode counts only at its full length
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep lane DEMUX, row DUAL-BOTHENDS-PARTIAL. `DemultiplexConfig.effectiveMinimumOverlap` capped the overlap at the
// shortest barcode less 4 for every kit, though its comment names reads from another platform than the kit's. On an
// 8-base dual kit at the platform's overlap of 5 it wrote `--overlap 4`, so where the line's second barcode is not
// anchored at the read's end, a read with the i7 at its 5' end and only the first 4 bases of the second barcode at its
// 3' end counts as the pair's sample.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexBothEndsOverlapTests: XCTestCase {

    /// The smallest input, run through Cutadapt 5.2 directly (`-g file:` with the line, `-e 0.15`, `--action none`).
    /// The kit is `kit` below, one 8-base pair, i7 `TAAGGCGA` and i5 `TAGATCGC`, which the line writes as its reverse
    /// complement `GCGATCTA`. The read is `TAAGGCGA` + 40 bases + `GCGA`, the first 4 bases of that i5 at its 3' end.
    /// Reads in the pair's sample:
    ///
    /// | line                                                        | `--overlap 4` | `--overlap 8` |
    /// | `^TAAGGCGA...GCGATCTA$`, the Both Ends line of a kit         | 0             | 0             |
    /// | `^TAAGGCGA...GCGATCTA`, i5 not anchored                      | 1             | 0             |
    /// | `TAAGGCGA...GCGATCTA`, a sample sheet's `fwdSpec...revSpec`  | 1             | 0             |
    ///
    /// Cutadapt reads an anchored part at its whole length whatever `--overlap` says, so the kit's Both Ends line left
    /// the read unassigned at the base too. Only a line whose second part is not anchored, as the sample-sheet route of
    /// `createAdapterConfiguration` writes it, takes the partial match at `--overlap 4`.
    static let partialReadCounts = (
        anchored: (overlap4: 0, overlap8: 0),
        unanchored: (overlap4: 1, overlap8: 0),
        sampleSheet: (overlap4: 1, overlap8: 0)
    )

    private static let output = URL(fileURLWithPath: "/tmp/lungfish-demux-both-ends-overlap")

    /// An 8-base dual kit of one pair on the platform of its reads.
    private static let kit = BarcodeKitDefinition(
        id: "both-ends-overlap", displayName: "Both Ends Overlap", vendor: "test", platform: .illumina,
        kitType: .custom, isDualIndexed: true, pairingMode: .fixedDual,
        barcodes: [BarcodeEntry(id: "P1", i7Sequence: "TAAGGCGA", i5Sequence: "TAGATCGC")]
    )

    private func config(
        kit: BarcodeKitDefinition = DemultiplexBothEndsOverlapTests.kit, location: BarcodeLocation = .bothEnds,
        minimumOverlap: Int? = nil, sourcePlatform: SequencingPlatform? = nil
    ) -> DemultiplexConfig {
        DemultiplexConfig(
            inputURL: Self.output.appendingPathComponent("reads.fastq"), barcodeKit: kit, outputDirectory: Self.output,
            barcodeLocation: location, minimumOverlap: minimumOverlap, sourcePlatform: sourcePlatform
        )
    }

    /// At Both Ends with two barcodes the overlap is the barcode's whole length, so the 4-base partial i5 above leaves
    /// the read unassigned on either line. The base wrote 4 at the platform's overlap of 5 and 3 at the command's 3.
    func testTwoBarcodesAtBothEndsCountTheSecondOnlyAtItsFullLength() {
        XCTAssertEqual(config().effectiveMinimumOverlap, 8, "the platform's overlap of 5 is not raised to the barcode length")
        XCTAssertEqual(config(minimumOverlap: 3).effectiveMinimumOverlap, 8, "the command's overlap of 3 is not raised")
        XCTAssertEqual(config(minimumOverlap: 12).effectiveMinimumOverlap, 12, "an overlap above the length is not kept")
        XCTAssertEqual(Self.partialReadCounts.sampleSheet.overlap8, 0)
    }

    /// The same kit at Both Ends from the built-in table: TruSeq HT has 8-base i7 and i5 indexes.
    func testTheBuiltInEightBaseDualKitAtBothEndsSearchesAtEightBases() {
        XCTAssertEqual(config(kit: BarcodeKitRegistry.truseqHTDual).effectiveMinimumOverlap, 8)
    }

    /// Reads from another platform than the kit's keep the cap at the barcode length less 4, as the comment says.
    func testReadsOfAnotherPlatformKeepTheCap() {
        XCTAssertEqual(config(sourcePlatform: .oxfordNanopore).effectiveMinimumOverlap, 4)
    }

    /// One location or one barcode is not this row, and keeps the overlap the base gave.
    func testOneEndOrOneBarcodeKeepsTheBasesOverlap() {
        XCTAssertEqual(config(location: .fivePrime).effectiveMinimumOverlap, 4)
        XCTAssertEqual(config(location: .threePrime).effectiveMinimumOverlap, 4)
        XCTAssertEqual(config(kit: BarcodeKitRegistry.fluidigmAccessArray).effectiveMinimumOverlap, 6)
    }
}
