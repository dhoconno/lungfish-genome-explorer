// FastqDemultiplexSubcommand+Summary.swift - Words of the `fastq demultiplex` summary
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

extension FastqDemultiplexSubcommand {
    /// The summary line that says where the run looked for each read's barcode, which the route owner chose when
    /// --engine was left out (L4 of the 3.3 tally).
    static func routeSummary(_ engine: DemultiplexEngine) -> String {
        switch engine {
        case .headerIndex:
            return "Barcodes read from: the index in each read name, at most one mismatch in each index (header-index)"
        case .cutadapt:
            return "Barcodes read from: a search of the read sequences (cutadapt)"
        case .exactBareBarcode:
            return "Barcodes read from: an exact search of the read sequences (exact-bare)"
        }
    }

    /// The summary line for barcodes at or below BIO's chance floor, or nil when there are none (DEMUXFLOOR-UX SF1).
    /// Their count is measured against the reads that carry no barcode (ruling BIO-DEMUX-FLOOR item 10), and their
    /// files are kept. `null` says what the chance count was measured on (ruling BIO-DEMUX-NULL item 9).
    static func withinChanceSummary(
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
}
