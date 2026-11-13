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

    /// The folders whose records can hold the run's floor: the folder each command wrote (its `-o` or `--output`), then
    /// the imported folders and the container, each once. A run of several inputs per input, or of a FASTQ and a FASTA
    /// input grouped, runs one command an input into `<run>/<input name>`, and the run folder holds no record of its own
    /// or the app's, which has no `chanceFloor` block (FLOOR-WINDOW-ROUTES-UNPROVEN, measured by
    /// `FASTQDemultiplexFloorRoutesConformanceTests`).
    static func runFolders(for result: FASTQOperationExecutionResult) -> [URL] {
        let written = result.executedInvocations.compactMap { invocation -> URL? in
            let arguments = invocation.arguments
            guard let flag = arguments.firstIndex(where: { $0 == "-o" || $0 == "--output" }),
                  arguments.indices.contains(flag + 1) else { return nil }
            return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        }
        var seen = Set<String>()
        return (written + result.importedURLs + [result.groupedContainerURL].compactMap { $0 })
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The `chanceFloor` block of each run folder's record that holds one, with its folder, in the order of
    /// `runFolders(for:)`. The record is the CLI's (`options.explicit["chanceFloor"]`).
    private static func floorBlocks(for result: FASTQOperationExecutionResult) -> [(folder: URL, floor: [String: ParameterValue])] {
        runFolders(for: result).compactMap { folder in
            guard let envelope = try? ProvenanceEnvelopeReader.loadCanonical(from: folder),
                  case .dictionary(let floor)? = envelope.options.explicit["chanceFloor"] else { return nil }
            return (folder: folder, floor: floor)
        }
    }

    /// The floor's line for the barcodes the run's records name within chance, or nil when they name none, hold no
    /// `chanceFloor` block or cannot be read. A record's barcodes come in the natural order of their IDs, since a record
    /// keeps them in a dictionary. When several commands wrote a floor, each barcode is named with its command's folder,
    /// the input's name (`S2 in poolB`), since each input has a folder of that barcode, and each null keeps its own
    /// sentence. It reads files, so a caller runs it off the main actor.
    static func floorNotice(for result: FASTQOperationExecutionResult) -> String? {
        guard case .derivative(.demultiplex, _, _) = result.resolvedRequest else { return nil }
        let blocks = floorBlocks(for: result)
        var byNull: [(null: DemultiplexChanceFloor.Null, counts: [(barcodeID: String, readCount: Int)])] = []
        for (folder, floor) in blocks {
            guard case .dictionary(let within)? = floor["barcodesWithinChance"], !within.isEmpty else { continue }
            var null = DemultiplexChanceFloor.Null.randomBases
            if case .string(let raw)? = floor["null"], let named = DemultiplexChanceFloor.Null(rawValue: raw) { null = named }
            let counts = within.compactMap { key, value -> (barcodeID: String, readCount: Int)? in
                guard case .integer(let count) = value else { return nil }
                return (barcodeID: blocks.count > 1 ? "\(key) in \(folder.lastPathComponent)" : key, readCount: count)
            }.sorted { $0.barcodeID.localizedStandardCompare($1.barcodeID) == .orderedAscending }
            if let index = byNull.firstIndex(where: { $0.null == null }) {
                byNull[index].counts += counts
            } else {
                byNull.append((null: null, counts: counts))
            }
        }
        let lines = byNull.compactMap { DemultiplexChanceWords.withinChanceSummary($0.counts, null: $0.null) }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// The warning of a finished run, the Exact Bare words or the floor's line. One run has one of them.
    static func rowNotice(for result: FASTQOperationExecutionResult) -> RowNotice? {
        if let words = notice(for: result) { return RowNotice(message: words, detailPrefix: rowPrefix) }
        if let line = floorNotice(for: result) { return RowNotice(message: line, detailPrefix: floorRowPrefix) }
        return nil
    }

    // The limit of the floor (DEMUX-FLOOR-DECOY-MAX, rulings BIO-DECOY-MAX-STABLE and STB-R2-UX section D). A barcode that
    // is not in the pool can still pass the floor, so a run that published a sample file says so. It is information about
    // the method and not a cause found in this run, so it is never the row's warning: `rowNotice(for:)` is not changed and
    // alone decides the warning, and the line goes to the Log at `.info`.

    /// The line under the row's name when the run published a sample and names no barcode within chance. That run has no
    /// cause to name, so the line is the check that the limit ends on, word for word, and the row stays Completed.
    static let floorLimitRowPrefix = "Check samples with few reads against your sample sheet. "

    /// The limit of the floor for a finished run, or nil when no record of its run folders (`runFolders(for:)`) holds a
    /// `chanceFloor` block or can be read. A record holds the block only when a barcode beat the floor (a run where none
    /// did throws before it writes one, `DemultiplexChanceFloor+Run.swift`), so the block alone says the run published a
    /// sample, and the manifest is not read. It reads files, so a caller runs it off the main actor.
    static func floorLimitLine(for result: FASTQOperationExecutionResult) -> String? {
        guard case .derivative(.demultiplex, _, _) = result.resolvedRequest else { return nil }
        return floorBlocks(for: result).isEmpty ? nil : DemultiplexChanceWords.notInPoolLimit(publishedBarcodes: 1)
    }

    /// The run's one warning and its information line, read together so that one call off the main actor serves the row and
    /// the Log. It reads files.
    static func rowWords(for result: FASTQOperationExecutionResult) -> (notice: RowNotice?, floorLimitLine: String?) {
        (rowNotice(for: result), floorLimitLine(for: result))
    }

    /// The detail of the finished row: the warning's own prefix when there is a warning, else the check when only the
    /// information line is there, else the plain completion detail. The row's warning state is the notice alone.
    static func rowDetail(_ notice: RowNotice?, _ floorLimitLine: String?, _ completionDetail: String) -> String {
        if let notice { return notice.rowDetail(completionDetail) }
        return (floorLimitLine == nil ? "" : floorLimitRowPrefix) + completionDetail
    }

    /// The run's chance lines in its Log: the warning at `.warning`, then the information line at `.info`. A `.warning`
    /// entry turns a finished row into Completed with Warnings (`OperationCenter.Item.hasWarnings`), so the information
    /// line stays at `.info`.
    @MainActor
    static func log(_ notice: RowNotice?, _ floorLimitLine: String?, id: UUID, in center: OperationCenter) {
        if let notice { center.log(id: id, level: .warning, message: notice.message) }
        if let floorLimitLine { center.log(id: id, level: .info, message: floorLimitLine) }
    }
}
