// DemultiplexingPipeline+HeaderIndexScout.swift - Detect Barcodes counts the index in the read names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DETECTHDR (L9 and L5 of the 3.3 tally). Detect built its search from the kit's context, whose 5' side
// is empty for TruSeq, Nextera and MGI, so it refused every Illumina, Element, Ultima and MGI kit
// (ILLUMINA-KIT-DETECT-NO-SEARCH), and it accepted a barcode at an absolute 10 hits (DETECT-ABSOLUTE-ACCEPT).

import Foundation
import LungfishIO

extension DemultiplexingPipeline {
    /// The count of `kit` from the index in the first `readLimit` read names of `inputFASTQ`, or nil when Detect
    /// searches the read bases instead. It runs no tool and writes no file.
    ///
    /// Illumina and Element kits are always counted from the names, and names that carry no index refuse in words. A
    /// custom definition is counted from the names when two or more of its barcodes are present in them, as the run's
    /// route owner reads a definition's names, so a GBS key whose names carry one library index keeps its search of
    /// the bases. Ultima and MGI kits, and a context the caller names, keep the search of the bases and its refusal.
    ///
    /// Each name is called with ``DemultiplexHeaderIndexCaller``, the run's own caller, i5 in one orientation for the
    /// file, so the counts are the ones the run writes. A barcode is accepted only when it is present by the route
    /// owner's rule, the chance bound of L5 at a tail of one in a million split over the kit's barcodes, never at an
    /// absolute count, and not when 99% or more of the names carry it, since such a file holds one sample.
    func scoutReadNameIndex(
        inputFASTQ: URL,
        kit: BarcodeKitDefinition,
        adapterContext: (any PlatformAdapterContext)?,
        readLimit: Int,
        runClock: ProvenanceRunClock,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> BarcodeScoutResult? {
        let namesPlatform = kit.platform == .illumina || kit.platform == .element
        guard adapterContext == nil, namesPlatform || kit.vendor == "custom" else { return nil }
        progress(0.0, "Reading the index in the first \(readLimit) read names...")
        var names: [FASTQReadNameIndex] = []
        for try await record in FASTQReader(validateSequence: false).records(from: inputFASTQ) {
            names.append(FASTQReadNameIndex(rawName: record.description.map { "\(record.identifier) \($0)" } ?? record.identifier))
            if names.count >= readLimit { break }
        }
        let present = Set(DemultiplexSearchRouteOwner.presentBarcodeOffsets(of: kit, in: names))
        guard namesPlatform || present.count >= 2 else { return nil }
        let indexed = names.filter(\.hasIndex).count
        guard indexed > 0 else {
            throw DemultiplexError.readNamesCarryNoIndex(kitName: kit.displayName, namesRead: names.count)
        }

        progress(0.5, "Counting the barcodes of \(kit.displayName) in the read names...")
        let caller = try await DemultiplexHeaderIndexCaller.reading(inputFASTQ, kit: kit)
        var tally = Array(repeating: 0, count: kit.barcodes.count)
        for name in names {
            let found = caller.candidates(name)
            if found.count == 1 { tally[found[0]] += 1 }
        }
        var detections: [BarcodeDetection] = []
        for (offset, barcode) in kit.barcodes.enumerated() where tally[offset] > 0 {
            detections.append(BarcodeDetection(
                barcodeID: barcode.id,
                kitID: kit.id,
                hitCount: tally[offset],
                hitPercentage: Double(tally[offset]) / Double(names.count) * 100,
                disposition: present.contains(offset) ? .accepted : .rejected
            ))
        }
        detections.sort { $0.hitCount > $1.hitCount }
        var result = BarcodeScoutResult(
            readsScanned: names.count,
            detections: detections,
            unassignedCount: names.count - tally.reduce(0, +),
            scoutedKitIDs: [kit.id],
            elapsedSeconds: runClock.elapsed,
            countSource: .readNameIndex,
            indexedReadCount: indexed
        )
        if let single = result.oneSampleDetection, let row = result.detections.firstIndex(where: { $0.id == single.id }) {
            result.detections[row].disposition = .undecided
        }
        progress(1.0, "Scout complete: \(detections.count) barcodes counted from the read names")
        return result
    }
}

extension FASTQSampleBarcodeAssignment {
    /// The metadata key that names where a plan row's barcode came from (L9, SWIFT condition 1 of `S2-R2-SWIFT.md:23`).
    public static let barcodeSourceKey = "barcodeSource"
    /// The metadata key that names the engine the run of a plan row takes (ARCH pin 6, ruling ARCH-DEMUX-PLAN-CONTROL C5).
    public static let demultiplexRouteKey = "demultiplexRoute"
    /// The metadata Detect's Proceed writes for a barcode it counted from the index in the read names, so no later
    /// wiring turns it into a search of the read bases.
    public static let readNameIndexMetadata: [String: String] = [
        barcodeSourceKey: BarcodeCountSource.readNameIndex.rawValue,
        demultiplexRouteKey: DemultiplexEngine.headerIndex.rawValue,
    ]

    /// The engine this row's run takes, as Proceed recorded it, or nil for a row typed by hand.
    public var recordedDemultiplexRoute: DemultiplexEngine? {
        metadata[Self.demultiplexRouteKey].flatMap(DemultiplexEngine.init(rawValue:))
    }
}
