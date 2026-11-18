// FastqDemultiplexSubcommand+Summary.swift - Words of the `fastq demultiplex` summary
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
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

    /// The chance lines of the summary, in the order they print: the barcodes within the floor of the Cutadapt search, the
    /// words of Exact Bare Barcode, which has no floor, and the limit of the floor, which a run that published a sample
    /// file the floor passed carries (DEMUX-FLOOR-DECOY-MAX). A floor run prints the first and the last, and an Exact
    /// Bare run only its words. It sits here so that `FastqCommand.swift`, which is at the file-size limit, does not grow.
    static func chanceSummaryLines(
        engine: DemultiplexEngine, readCounts: [Int], chanceFloor: DemultiplexChanceFloor.Outcome?
    ) -> [String] {
        let within = (chanceFloor?.barcodesWithinChance ?? []).map { (barcodeID: $0.barcodeID, readCount: $0.readCount) }
        return [
            withinChanceSummary(within, null: chanceFloor?.null ?? .randomBases),
            exactBareChanceSummary(engine, barcodesWithReads: readCounts.filter { $0 > 0 }.count),
            // A kit the floor could not judge says so in place of the limit (DEMUX-FLOOR-SATURATED-KIT).
            chanceFloor.flatMap {
                DemultiplexChanceWords.floorLimit(publishedBarcodes: $0.barcodes.filter(\.beatsTheFloor).count, null: $0.null)
            },
        ].compactMap { $0 }
    }

    /// The help of `--keep-unchecked-samples` (DEMUX-FLOOR-SATURATED-KIT, BIO-DEMUX-THREE item 3). It gives its three causes
    /// and names the routes made for the Fluidigm kit (BIO-SATKIT-FLUIDIGM item 4). The Exact Bare case of read names that
    /// carry the kit's barcodes takes the same flag (DEMUX-EXACT-BARE-NO-FLOOR, BIO-DEMUX-THREE item 7).
    static let keepUncheckedSamplesHelp = "Make sample files even when the check for chance matches cannot judge the "
        + "kit, because many reads that carry no barcode would match its barcodes by chance. This happens when the "
        + "barcodes are only a few bases long, or when cutadapt searches them anywhere in the read, as it does for the "
        + "Fluidigm Access Array kit. With --engine "
        + "exact-bare, make sample files even when the read names carry the kit's barcodes, which that engine finds in "
        + "the read sequences only by chance. Without this flag such a run is refused. Check each sample against your "
        + "sample sheet. For Fluidigm barcodes in ONT reads, use fastq ont-fluidigm-samples, and for reads whose index "
        + "is in their names, use --engine header-index"

    /// The record's `chanceFloor` block: what the chance count was measured on, the margin over it and the windows it was
    /// tallied from (BIO-DEMUX-NULL item 9), the barcodes within chance, and whether the person chose to keep the samples
    /// of a kit the floor cannot judge (`optIn`, BIO-DEMUX-THREE item 4). It sits here so that `FastqCommand.swift` does not grow.
    static func chanceFloorParameter(_ floor: DemultiplexChanceFloor.Outcome, optIn: Bool) -> ParameterValue {
        .dictionary([
            "kitTail": .number(DemultiplexChanceFloor.kitTail),
            "chanceTrials": .integer(floor.chanceTrials),
            "null": .string(floor.null.rawValue),
            "margin": .number((floor.margin * 100).rounded() / 100),
            "compositionReads": .integer(floor.compositionReads),
            "barcodesWithinChance": .dictionary(Dictionary(
                floor.barcodesWithinChance.map { ($0.barcodeID, ParameterValue.integer($0.readCount)) },
                uniquingKeysWith: { first, _ in first }
            )),
            "optIn": .boolean(optIn),
        ])
    }

    /// The summary line for barcodes at or below BIO's chance floor, or nil when there are none (DEMUXFLOOR-UX SF1).
    /// Their count is measured against the reads that carry no barcode (ruling BIO-DEMUX-FLOOR item 10), and their
    /// files are kept. `null` says what the chance count was measured on (ruling BIO-DEMUX-NULL item 9).
    static func withinChanceSummary(
        _ within: [(barcodeID: String, readCount: Int)], null: DemultiplexChanceFloor.Null
    ) -> String? {
        DemultiplexChanceWords.withinChanceSummary(within, null: null)
    }
}
