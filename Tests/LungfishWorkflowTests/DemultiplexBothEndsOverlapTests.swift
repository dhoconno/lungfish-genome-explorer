// DemultiplexBothEndsOverlapTests.swift - The overlap cap at the barcode length less 4 holds for every kit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep lane DEMUX, row DUAL-BOTHENDS-PARTIAL, closed as not reproduced by ruling BIO-DEMUX (Question 1). Every
// route a person can start writes a kit's Both Ends line anchored at both ends, `^i7...rc(i5)$`, which Cutadapt reads
// at full length whatever `--overlap` says, so `DemultiplexConfig.effectiveMinimumOverlap` keeps its cap at the
// shortest barcode less 4 for every kit and every command keeps its recorded overlap (BIO-DEMUX binding items 1 and 2).

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
    /// Cutadapt reads an anchored part at its whole length whatever `--overlap` says, so the kit's Both Ends line leaves
    /// the read unassigned at `--overlap 4`. The table is the record of that count; no test reads it.
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
