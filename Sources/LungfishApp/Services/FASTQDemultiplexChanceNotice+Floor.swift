// FASTQDemultiplexChanceNotice+Floor.swift - The floor's chance line in the window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow

extension FASTQDemultiplexChanceNotice {
    /// The line under the row's name when barcodes sit within the floor's chance, which starts with the cause.
    static let floorRowPrefix = "Some barcodes could be chance matches. "

    /// The one warning a finished run's Operations row carries, with the line that starts its detail.
    struct RowNotice: Equatable {
        let message: String
        let detailPrefix: String

        func rowDetail(_ completionDetail: String) -> String {
            detailPrefix + completionDetail
        }
    }

    /// The floor's line for the barcodes the run's record names within chance, or nil when it names none, holds no
    /// `chanceFloor` block or cannot be read. The record is the CLI's (`options.explicit["chanceFloor"]`), found in the
    /// run's folder, and its barcodes come in the natural order of their IDs, since a record keeps them in a dictionary.
    /// It reads files, so a caller runs it off the main actor.
    static func floorNotice(for result: FASTQOperationExecutionResult) -> String? {
        guard case .derivative(.demultiplex, _, _) = result.resolvedRequest else { return nil }
        for folder in result.importedURLs + [result.groupedContainerURL].compactMap({ $0 }) {
            guard let envelope = try? ProvenanceEnvelopeReader.loadCanonical(from: folder),
                  case .dictionary(let floor)? = envelope.options.explicit["chanceFloor"],
                  case .dictionary(let within)? = floor["barcodesWithinChance"], !within.isEmpty else { continue }
            var null = DemultiplexChanceFloor.Null.randomBases
            if case .string(let raw)? = floor["null"], let named = DemultiplexChanceFloor.Null(rawValue: raw) { null = named }
            let counts = within.compactMap { key, value -> (barcodeID: String, readCount: Int)? in
                guard case .integer(let count) = value else { return nil }
                return (barcodeID: key, readCount: count)
            }.sorted { $0.barcodeID.localizedStandardCompare($1.barcodeID) == .orderedAscending }
            return DemultiplexChanceWords.withinChanceSummary(counts, null: null)
        }
        return nil
    }

    /// The warning of a finished run, the Exact Bare words or the floor's line. One run has one of them.
    static func rowNotice(for result: FASTQOperationExecutionResult) -> RowNotice? {
        if let words = notice(for: result) { return RowNotice(message: words, detailPrefix: rowPrefix) }
        if let line = floorNotice(for: result) { return RowNotice(message: line, detailPrefix: floorRowPrefix) }
        return nil
    }

    // STUBS of the red commit of lane DECOYWORDS (DEMUX-FLOOR-DECOY-MAX). The fix replaces them. Each one does what the
    // base does, so the tests below the stubs fail on the missing line and nothing else.

    static let floorLimitRowPrefix = ""

    static func floorLimitLine(for result: FASTQOperationExecutionResult) -> String? { nil }

    static func rowWords(for result: FASTQOperationExecutionResult) -> (notice: RowNotice?, floorLimitLine: String?) {
        (rowNotice(for: result), nil)
    }

    static func rowDetail(_ notice: RowNotice?, _ floorLimitLine: String?, _ completionDetail: String) -> String {
        notice?.rowDetail(completionDetail) ?? completionDetail
    }

    @MainActor
    static func log(_ notice: RowNotice?, _ floorLimitLine: String?, id: UUID, in center: OperationCenter) {
        if let notice { center.log(id: id, level: .warning, message: notice.message) }
    }
}
