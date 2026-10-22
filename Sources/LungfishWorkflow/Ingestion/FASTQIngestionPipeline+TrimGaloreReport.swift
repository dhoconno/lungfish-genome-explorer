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

/// What one Trim Galore call says it did, read from the JSON trimming report it writes beside its output. In paired
/// mode each mate has a report, both count pairs, and the R1 report is read.
struct TrimGaloreReport: Sendable, Equatable {
    /// Whether the call ran in paired mode, where the counts are pairs.
    let paired: Bool
    /// The reads (pairs in paired mode) the call read and the ones it wrote.
    let totalReads: Int
    let readsWritten: Int
    /// The version the report names, such as 2.3.0.
    let version: String?
    /// The effective parameters with the report's own names, such as `length_cutoff` and `quality_cutoff`.
    let parameters: [String: ParameterValue]

    var removed: Int { totalReads - readsWritten }
    /// The records the call read and wrote, two for each pair.
    var recordsRead: Int { totalReads * (paired ? 2 : 1) }
    var recordsWritten: Int { readsWritten * (paired ? 2 : 1) }
    var lengthCutoff: Int? { parameters["length_cutoff"]?.integerValue }
    var qualityCutoff: Int? { parameters["quality_cutoff"]?.integerValue }
}

extension FASTQIngestionPipeline {

    static let unreadableTrimGaloreReport =
        "trim_galore wrote no readable report, so the reads it removed cannot be counted; originals were kept"

    /// Reads the trimming report of the call whose output folder is `directory`. Fails closed when no report there can
    /// be read, because the reads the call removed could not then be counted.
    static func readTrimGaloreReport(in directory: URL) throws -> TrimGaloreReport {
        let reports = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("_trimming_report.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in reports {
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (json["read_number"] as? Int ?? 1) == 1 else { continue }
            return try parseTrimGaloreReport(json)
        }
        throw FASTQIngestionError.clumpifyFailed(unreadableTrimGaloreReport)
    }

    /// The report's mode, read counts, version and parameters.
    static func parseTrimGaloreReport(_ json: [String: Any]) throws -> TrimGaloreReport {
        guard let processing = json["read_processing"] as? [String: Any],
              let total = processing["total_reads"] as? Int,
              let written = processing["reads_written"] as? Int,
              written >= 0, total >= written else {
            throw FASTQIngestionError.clumpifyFailed(unreadableTrimGaloreReport)
        }
        return TrimGaloreReport(
            paired: (json["mode"] as? String) == "paired-end",
            totalReads: total,
            readsWritten: written,
            version: json["trim_galore_version"] as? String,
            parameters: (json["parameters"] as? [String: Any] ?? [:]).mapValues { reportValue($0) }
        )
    }

    /// A JSON value of a report as a parameter value.
    static func reportValue(_ value: Any) -> ParameterValue {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            if CFNumberIsFloatType(number) { return .number(number.doubleValue) }
            return .integer(number.intValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map { reportValue($0) })
        case let dictionary as [String: Any]:
            return .dictionary(dictionary.mapValues { reportValue($0) })
        default:
            return .null
        }
    }

    /// Checks one call's report against the records the call was given and the records it left. The call must have
    /// read every record the scan or the input count found, and its output must hold exactly the records its report
    /// says it wrote. Any other shortfall is loss the report does not explain.
    static func verifyTrimGaloreAccounting(reported: TrimGaloreReport, scanned: Int, counted: Int) throws {
        guard reported.recordsRead == scanned else {
            throw FASTQIngestionError.clumpifyFailed(
                "trim_galore reports \(reported.recordsRead) reads read but its input holds \(scanned); originals were kept"
            )
        }
        guard counted == reported.recordsWritten else {
            throw FASTQIngestionError.clumpifyFailed(
                "trim_galore reports \(reported.recordsWritten) reads written but its output holds \(counted); originals were kept"
            )
        }
    }

    /// Counts `output` and checks it with ``verifyTrimGaloreAccounting(reported:scanned:counted:)``, removing `output`
    /// when the check fails so the originals stay the only copy.
    static func verifyTrimGaloreOutput(_ output: URL, reported: TrimGaloreReport, scanned: Int) async throws {
        let counted = try await detachedWork { try FASTQPairInterleaver.countRecords(in: output) }
        do {
            try verifyTrimGaloreAccounting(reported: reported, scanned: scanned, counted: counted)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// The resolved options of a Trim Galore step: the effective parameters its report names, such as `length_cutoff`
    /// and `quality_cutoff`, and the reads (pairs in paired mode) the call read, wrote and removed.
    static func trimGaloreResolvedOptions(_ report: TrimGaloreReport) -> [String: ParameterValue] {
        var options = report.parameters
        let unit = report.paired ? "pairs" : "reads"
        options["\(unit)Read"] = .integer(report.totalReads)
        options["\(unit)Written"] = .integer(report.readsWritten)
        options["\(unit)Removed"] = .integer(report.removed)
        if let version = report.version { options["trimGaloreVersion"] = .string(version) }
        options["storageReadRemoval"] = .string(trimGaloreRemovalStatement(report))
        return options
    }

    /// What a Trim Galore storage call does to the reads it stores and what this call removed, for the step's record.
    /// The owner keeps Trim Galore as the most laptop-safe storage tool and asked that its loss be noted in provenance
    /// (Q12, 2026-10-22). Trim Galore 2.3.0, the newest release then, has no option set that turns its adapter and
    /// quality trim or its length filter off (review of lane C2-TRIMGALORE).
    static func trimGaloreRemovalStatement(_ report: TrimGaloreReport) -> String {
        let tool = report.version.map { "Trim Galore \($0)" } ?? "Trim Galore"
        let quality = report.qualityCutoff.map { " (quality cutoff \($0))" } ?? ""
        let length = report.lengthCutoff.map { "the length cutoff of \($0) bases" } ?? "its length cutoff"
        return "\(tool) adapter- and quality-trims every read\(quality) and removes each read that trimming leaves "
            + "shorter than \(length), a pair as a unit in paired mode. No \(tool) option set turns this off. "
            + "This call removed \(report.removed) of \(report.totalReads) \(report.paired ? "pairs" : "reads")."
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
