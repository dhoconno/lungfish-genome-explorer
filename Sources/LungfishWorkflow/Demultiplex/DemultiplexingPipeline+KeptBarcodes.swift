// DemultiplexingPipeline+KeptBarcodes.swift - A run that keeps barcodes trims its reads only as its input was trimmed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension DemultiplexingPipeline {
    /// The trims a barcode bundle of a run that keeps barcodes carries. For
    /// each listed read and mate it is the trim its input bundle recorded, so
    /// the bundle materializes the reads that were demultiplexed (L5 item 2).
    ///
    /// cutadapt's info file lists every barcode match whatever `--action`
    /// was, and virtual bundles used to take those matches as trims under
    /// `--no-trim` too, so they materialized reads without their barcode.
    func parentTrimEntries(
        for readIDs: [String],
        parentTrimMap: [String: (trim5p: Int, trim3p: Int)]
    ) -> [DemuxTrimEntry] {
        guard !parentTrimMap.isEmpty else { return [] }
        var seen = Set<String>()
        var entries: [DemuxTrimEntry] = []
        for readID in readIDs {
            for mate in [0, 1, 2] {
                let key = "\(readID)\t\(mate)"
                guard seen.insert(key).inserted, let trim = parentTrimMap[key] else { continue }
                entries.append(DemuxTrimEntry(
                    readID: readID,
                    mate: mate,
                    trim5p: trim.trim5p,
                    trim3p: trim.trim3p,
                    rootReadLength: nil
                ))
            }
        }
        return entries
    }
}
