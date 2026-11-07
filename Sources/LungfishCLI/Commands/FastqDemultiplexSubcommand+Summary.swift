// FastqDemultiplexSubcommand+Summary.swift - Words of the `fastq demultiplex` summary
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FastqDemultiplexSubcommand {
    /// The summary line for barcodes at or below BIO's chance floor, or nil when there are none (DEMUXFLOOR-UX SF1).
    /// Their count is measured against the reads that carry no barcode (ruling BIO-DEMUX-FLOOR item 10), and their
    /// files are kept.
    static func withinChanceSummary(_ within: [(barcodeID: String, readCount: Int)]) -> String? {
        guard !within.isEmpty else { return nil }
        let named = within.map { "\($0.barcodeID) (\($0.readCount) \($0.readCount == 1 ? "read" : "reads"))" }
            .joined(separator: ", ")
        return "Could be chance matches: \(named). Reads that carry no barcode match a barcode by chance at this error "
            + "rate, and each of these holds no more reads than that gives. Their files were kept, so check them "
            + "against the samples you expect."
    }
}
