// DemultiplexDualFormTests+Words.swift - The chance refusal on the route that reads the secondary sequence either way
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane DEMUX-DUAL-FORM item 2 (ruling BIO-DUAL-FORM item 4 (b), words UX-WORDS-2 section 3 (b)). A run of a Custom
// Definition of dual indexes at Both Ends with no sample sheet looks for each secondary sequence both ways, so when no
// barcode beats the chance check its words say the way the column is written is not the cause. Every other route keeps
// the words of `DemultiplexError.swift:70` byte for byte. The test runs Cutadapt.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

extension DemultiplexDualFormTests {
    func testTheChanceRefusalSaysTheFormIsNotTheCauseOnThisRouteOnly() async throws {
        let causes = "No barcode of K matched more reads than chance alone gives, so Demultiplex Barcodes made no sample "
            + "files. The index in the read names may match no barcode of this kit, the index may sit in index reads that are "
            + "not in this file, the reads may already be split into one file per sample, or a barcode may be on too few "
            + "reads to stand above chance."
        let steps = " Choose the kit the library was made with, check the barcode sequences and the end of the read you chose "
            + "for a Custom Definition, or import this file as one sample."
        var bases = Bases()
        let reads: [Read] = (0..<40).map { ("none|\($0)", bases.next(76)) }
        let (words, published) = try await refusal(Self.threePairs, reads)
        XCTAssertEqual(words, causes + " The run looked for the secondary sequence of each row both as written and reverse "
                       + "complemented, so the way the secondary sequences are written is not the cause." + steps)
        XCTAssertFalse(published)
        assertProse(words, "noBarcodeAboveChance on this route")
        XCTAssertEqual(DemultiplexError.noBarcodeAboveChance(kitName: "K").errorDescription, causes + steps,
                       "every other route keeps the words of DemultiplexError.swift:70")
    }
}
