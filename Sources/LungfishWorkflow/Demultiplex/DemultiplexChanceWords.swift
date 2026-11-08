// DemultiplexChanceWords.swift - The chance line of a demultiplex run, shared by the command line and the app
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The words that name the barcodes within the chance floor. `lungfish-cli fastq demultiplex` prints them in its summary
/// and the app says them in the Operations row (DEMUX-FLOOR-SATURATED-KIT, ruling UX-EXACT-BARE-WORDS section 7).
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

    /// STUB of the red commit of lane DECOYWORDS. The fix replaces it.
    public static func notInPoolLimit(publishedBarcodes: Int) -> String? { "" }
}
