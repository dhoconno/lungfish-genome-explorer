// FASTQIngestionPipeline+TrimGaloreReport.swift - What a Trim Galore storage call removed, from its trimming report
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The reads a Trim Galore storage run removed, from the trimming report of each call, checked against the records the
/// run was given and the records each call left. A pair counts once, and Trim Galore removes a pair as a unit.
public struct FASTQStorageReadRemoval: Sendable, Equatable {
    /// The pairs the run read and the pairs it removed.
    public let pairsRead: Int
    public let pairs: Int
    /// The reads without a mate (merged, unpaired or single-end reads) the run read and the ones it removed.
    public let unpairedReadsRead: Int
    public let unpairedReads: Int
    /// The Trim Galore version and the cutoffs the reports name.
    public let toolVersion: String?
    public let lengthCutoff: Int?
    public let qualityCutoff: Int?

    public init(
        pairsRead: Int, pairs: Int, unpairedReadsRead: Int, unpairedReads: Int,
        toolVersion: String? = nil, lengthCutoff: Int? = nil, qualityCutoff: Int? = nil
    ) {
        self.pairsRead = pairsRead
        self.pairs = pairs
        self.unpairedReadsRead = unpairedReadsRead
        self.unpairedReads = unpairedReads
        self.toolVersion = toolVersion
        self.lengthCutoff = lengthCutoff
        self.qualityCutoff = qualityCutoff
    }

    /// The records the run read and the records it stored.
    public var recordsRead: Int { pairsRead * 2 + unpairedReadsRead }
    public var recordsStored: Int { recordsRead - pairs * 2 - unpairedReads }

    /// What was removed, such as "1 of 12 pairs and 0 of 6 unpaired reads", or "2 of 10 reads" for single reads.
    public var removedCounts: String {
        var parts: [String] = []
        if pairsRead > 0 { parts.append("\(pairs) of \(pairsRead) pairs") }
        if unpairedReadsRead > 0 || pairsRead == 0 {
            parts.append("\(unpairedReads) of \(unpairedReadsRead) \(pairsRead > 0 ? "unpaired reads" : "reads")")
        }
        return parts.joined(separator: " and ")
    }

    /// The import's notice after storage, one plain sentence that names the version, the cutoffs, what Trim Galore
    /// does to every read it stores and what it removed (owner answer Q12).
    public var notice: String {
        let tool = toolVersion.map { "Trim Galore \($0)" } ?? "Trim Galore"
        let quality = qualityCutoff.map { "bases under quality \($0)" } ?? "low-quality bases"
        let length = lengthCutoff.map { "\($0) bases" } ?? "its length cutoff"
        let unit = pairsRead > 0 ? ", each pair as a unit" : ""
        return "\(tool) trimmed adapters and \(quality) from this sample's reads and removed the reads left shorter "
            + "than \(length) (\(removedCounts)\(unit)), and no \(tool) option turns this off."
    }
}

extension FASTQIngestionPipeline {

    static let unreadableTrimGaloreReport = TrimGaloreReport.unreadable

    /// ``TrimGaloreReport/read(in:)`` with the import's error.
    static func readTrimGaloreReport(in directory: URL) throws -> TrimGaloreReport {
        try mappingStorageErrorsNow { try TrimGaloreReport.read(in: directory) }
    }

    /// ``TrimGaloreReport/verifyAccounting(scanned:counted:)`` with the import's error.
    static func verifyTrimGaloreAccounting(reported: TrimGaloreReport, scanned: Int, counted: Int) throws {
        try mappingStorageErrorsNow { try reported.verifyAccounting(scanned: scanned, counted: counted) }
    }

    /// ``PortableStorageChecks/verifyTrimGaloreOutput(_:reported:scanned:launcher:)`` with the Mac's gzip reader and
    /// the import's error.
    static func verifyTrimGaloreOutput(_ output: URL, reported: TrimGaloreReport, scanned: Int) async throws {
        try await mappingStorageErrors {
            try await PortableStorageChecks.verifyTrimGaloreOutput(
                output, reported: reported, scanned: scanned, launcher: ToolProcessChildLauncher()
            )
        }
    }

    /// The resolved options of a Trim Galore step: the effective parameters its report names, such as `length_cutoff`
    /// and `quality_cutoff`, the reads (pairs in paired mode) the call read, wrote and removed, and the provenance note
    /// of its loss (``TrimGaloreReport/removalStatement``).
    static func trimGaloreResolvedOptions(_ report: TrimGaloreReport) -> [String: ParameterValue] {
        var options = report.parameters.mapValues(parameterValue)
        let unit = report.paired ? "pairs" : "reads"
        options["\(unit)Read"] = .integer(report.totalReads)
        options["\(unit)Written"] = .integer(report.readsWritten)
        options["\(unit)Removed"] = .integer(report.removed)
        if let version = report.version { options["trimGaloreVersion"] = .string(version) }
        options["storageReadRemoval"] = .string(report.removalStatement)
        return options
    }

    /// A value of a report as a parameter value.
    static func parameterValue(_ value: TrimGaloreReportValue) -> ParameterValue {
        switch value {
        case .boolean(let flag): return .boolean(flag)
        case .integer(let integer): return .integer(integer)
        case .number(let number): return .number(number)
        case .string(let string): return .string(string)
        case .array(let array): return .array(array.map(parameterValue))
        case .dictionary(let dictionary): return .dictionary(dictionary.mapValues(parameterValue))
        case .null: return .null
        }
    }

    /// The removal of a run, from the report of its pairs call, its unpaired or single-end call, or both.
    static func storageReadRemoval(pairs: TrimGaloreReport?, unpaired: TrimGaloreReport?) -> FASTQStorageReadRemoval {
        let named = pairs ?? unpaired
        return FASTQStorageReadRemoval(
            pairsRead: pairs?.totalReads ?? 0,
            pairs: pairs?.removed ?? 0,
            unpairedReadsRead: unpaired?.totalReads ?? 0,
            unpairedReads: unpaired?.removed ?? 0,
            toolVersion: named?.version,
            lengthCutoff: named?.lengthCutoff,
            qualityCutoff: named?.qualityCutoff
        )
    }
}

extension FASTQBatchImporter {
    /// The layout of the stored file once storage removed `removal`, which the sidecar records (review fix 2). Pairs
    /// lose the pairs removed. The reads without a mate lose the unpaired reads removed, as merged reads when the
    /// layout has merged reads and as unpaired reads otherwise: a recipe refuses a joined third file, so the two are
    /// never both above zero. The layout is unchanged when the storage tool keeps every read.
    static func storedMixedLayout(
        _ layout: RecipeMixedLayoutCounts?, removing removal: FASTQStorageReadRemoval?
    ) -> RecipeMixedLayoutCounts? {
        guard let layout, let removal else { return layout }
        let merged = layout.mergedReads > 0
        return RecipeMixedLayoutCounts(
            mergedReads: merged ? max(0, layout.mergedReads - removal.unpairedReads) : 0,
            pairs: max(0, layout.pairs - removal.pairs),
            unpairedReads: merged ? layout.unpairedReads : max(0, layout.unpairedReads - removal.unpairedReads)
        )
    }
}
