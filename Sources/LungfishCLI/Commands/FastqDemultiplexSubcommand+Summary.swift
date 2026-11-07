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

    /// The summary line that says Exact Bare Barcode checks no chance matches, or nil for another engine or a run that
    /// made no sample file (DEMUX-EXACT-BARE-NO-FLOOR, ruling UX-EXACT-BARE-WORDS).
    static func exactBareChanceSummary(_ engine: DemultiplexEngine, barcodesWithReads: Int) -> String? {
        engine == .exactBareBarcode && barcodesWithReads > 0 ? DemultiplexEngine.exactBareChanceWords : nil
    }

    /// The chance lines of the summary, in the order they print: the barcodes within the floor of the Cutadapt search, then
    /// the words of Exact Bare Barcode, which has no floor. One run prints one of them. It sits here so that
    /// `FastqCommand.swift`, which is at the file-size limit, does not grow.
    static func chanceSummaryLines(
        engine: DemultiplexEngine, readCounts: [Int], chanceFloor: DemultiplexChanceFloor.Outcome?
    ) -> [String] {
        let within = (chanceFloor?.barcodesWithinChance ?? []).map { (barcodeID: $0.barcodeID, readCount: $0.readCount) }
        return [
            withinChanceSummary(within, null: chanceFloor?.null ?? .randomBases),
            exactBareChanceSummary(engine, barcodesWithReads: readCounts.filter { $0 > 0 }.count),
        ].compactMap { $0 }
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
