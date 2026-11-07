// FastqDemultiplexSubcommand+Summary.swift - Words of the `fastq demultiplex` summary
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

extension FastqDemultiplexSubcommand {
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
            measuredOn = "measured on the first bases of this file's own reads that carry none"
        case .randomBases:
            measuredOn = "measured on random bases because the run left too few reads without a barcode to measure its own"
        }
        return "Could be chance matches: \(named). Reads that carry no barcode match a barcode by chance at this error "
            + "rate, \(measuredOn), and each of these holds no more reads than that gives. Their files were kept, so "
            + "check them against the samples you expect."
    }
}
