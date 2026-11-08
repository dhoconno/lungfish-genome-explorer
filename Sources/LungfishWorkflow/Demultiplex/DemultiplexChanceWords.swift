// DemultiplexChanceWords.swift - The chance line of a demultiplex run, shared by the command line and the app
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The words of the chance floor: the barcodes within it, and the limit it cannot close, a barcode that is not in the
/// pool passing as a sample. `lungfish-cli fastq demultiplex` prints them in its summary and the app says them in the
/// Operations row and its Log (DEMUX-FLOOR-SATURATED-KIT, ruling UX-EXACT-BARE-WORDS section 7, and DEMUX-FLOOR-DECOY-MAX).
public enum DemultiplexChanceWords {
    /// The summary line for barcodes at or below BIO's chance floor, or nil when there are none (DEMUXFLOOR-UX SF1).
    /// Their count is measured against the reads that carry no barcode (ruling BIO-DEMUX-FLOOR item 10), and their
    /// files are kept. `null` says what the chance count was measured on (ruling BIO-DEMUX-NULL item 9).
    public static func withinChanceSummary(
        _ within: [(barcodeID: String, readCount: Int)], null: DemultiplexChanceFloor.Null
    ) -> String? {
        guard !within.isEmpty else { return nil }
        let named = within.map { "\($0.barcodeID) (\($0.readCount) \($0.readCount == 1 ? "read" : "reads"))" }
            .joined(separator: ", ")
        let measuredOn: String
        switch null {
        case .startComposition:
            measuredOn = "The chance is measured on the first bases of the Unassigned reads."
        case .randomBases:
            measuredOn = "The chance is worked out as if A, C, G and T were equally likely, because the Unassigned reads "
                + "could not measure it."
        }
        return "Could be chance matches: \(named). Reads that carry no barcode match a barcode by chance at this error "
            + "rate, and each of these holds no more reads than chance gives. \(measuredOn) Their files were kept, so "
            + "check them against the samples you expect."
    }

    /// The limit of the floor, for a run that published a sample file the floor passed, or nil when it published none
    /// (DEMUX-FLOOR-DECOY-MAX, rulings BIO-DECOY-MAX-STABLE and STB-R2-UX section D). The floor's margin is the largest
    /// ratio over about 1,000 decoy barcodes, so a barcode that is not in the pool passes it in about one run in 1,000,
    /// and more often in an amplicon file, which holds some read starts at high copy. The sample file of such a barcode
    /// holds a few reads, as a real small sample does, so the check is the person's own sample sheet. The summary of
    /// `lungfish-cli fastq demultiplex` prints this line and the Operations Log takes it at the information level.
    public static func notInPoolLimit(publishedBarcodes: Int) -> String? {
        guard publishedBarcodes > 0 else { return nil }
        return "A barcode that is not in your pool can still pass as a sample. For each such barcode this happens in "
            + "about one run in 1,000, and more often in amplicon files. Check samples with few reads against your "
            + "sample sheet."
    }
}
