// TrimGaloreReport.swift - What one Trim Galore storage call says it did, from its JSON trimming report
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A JSON value of a Trim Galore report, as its `parameters` object holds it.
package indirect enum TrimGaloreReportValue: Sendable, Equatable {
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([TrimGaloreReportValue])
    case dictionary([String: TrimGaloreReportValue])
    case null

    /// The value of an object `JSONSerialization` returned. A number reads as a boolean, a floating-point number or
    /// an integer by the type the parser stored it with.
    package init(json value: Any) {
        switch value {
        case let number as NSNumber:
            switch String(cString: number.objCType) {
            case "c", "B": self = .boolean(number.boolValue)
            case "d", "f": self = .number(number.doubleValue)
            default: self = .integer(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { TrimGaloreReportValue(json: $0) })
        case let dictionary as [String: Any]:
            self = .dictionary(dictionary.mapValues { TrimGaloreReportValue(json: $0) })
        default:
            self = .null
        }
    }

    /// The integer of an integer, or of a floating-point number that holds one exactly.
    package var integerValue: Int? {
        switch self {
        case .integer(let value): return value
        case .number(let value): return Int(exactly: value)
        default: return nil
        }
    }
}

/// What one Trim Galore call says it did, read from the JSON trimming report it writes beside its output. In paired
/// mode each mate has a report, both count pairs, and the R1 report is read. The storage step checks every call's
/// output against its report, so the reads a call removed are counted and named in the record.
package struct TrimGaloreReport: Sendable, Equatable {
    /// Whether the call ran in paired mode, where the counts are pairs.
    package let paired: Bool
    /// The reads (pairs in paired mode) the call read and the ones it wrote.
    package let totalReads: Int
    package let readsWritten: Int
    /// The version the report names, such as 2.3.0.
    package let version: String?
    /// The effective parameters with the report's own names, such as `length_cutoff` and `quality_cutoff`.
    package let parameters: [String: TrimGaloreReportValue]

    package init(
        paired: Bool, totalReads: Int, readsWritten: Int, version: String?,
        parameters: [String: TrimGaloreReportValue]
    ) {
        self.paired = paired
        self.totalReads = totalReads
        self.readsWritten = readsWritten
        self.version = version
        self.parameters = parameters
    }

    package var removed: Int { totalReads - readsWritten }
    /// The records the call read and wrote, two for each pair.
    package var recordsRead: Int { totalReads * (paired ? 2 : 1) }
    package var recordsWritten: Int { readsWritten * (paired ? 2 : 1) }
    package var lengthCutoff: Int? { parameters["length_cutoff"]?.integerValue }
    package var qualityCutoff: Int? { parameters["quality_cutoff"]?.integerValue }

    package static let unreadable =
        "trim_galore wrote no readable report, so the reads it removed cannot be counted; originals were kept"

    /// Reads the trimming report of the call whose output folder is `directory`. Fails closed when no report there can
    /// be read, because the reads the call removed could not then be counted.
    package static func read(in directory: URL) throws -> TrimGaloreReport {
        let reports = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("_trimming_report.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in reports {
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (json["read_number"] as? Int ?? 1) == 1 else { continue }
            return try parse(json)
        }
        throw PortableStorageError.storageFailed(unreadable)
    }

    /// The report's mode, read counts, version and parameters.
    package static func parse(_ json: [String: Any]) throws -> TrimGaloreReport {
        guard let processing = json["read_processing"] as? [String: Any],
              let total = processing["total_reads"] as? Int,
              let written = processing["reads_written"] as? Int,
              written >= 0, total >= written else {
            throw PortableStorageError.storageFailed(unreadable)
        }
        return TrimGaloreReport(
            paired: (json["mode"] as? String) == "paired-end",
            totalReads: total,
            readsWritten: written,
            version: json["trim_galore_version"] as? String,
            parameters: (json["parameters"] as? [String: Any] ?? [:]).mapValues { TrimGaloreReportValue(json: $0) }
        )
    }

    /// Checks the report against the records the call was given and the records it left. The call must have read
    /// every record the scan or the input count found, and its output must hold exactly the records its report says
    /// it wrote. Any other shortfall is loss the report does not explain.
    package func verifyAccounting(scanned: Int, counted: Int) throws {
        guard recordsRead == scanned else {
            throw PortableStorageError.storageFailed(
                "trim_galore reports \(recordsRead) reads read but its input holds \(scanned); originals were kept"
            )
        }
        guard counted == recordsWritten else {
            throw PortableStorageError.storageFailed(
                "trim_galore reports \(recordsWritten) reads written but its output holds \(counted); originals were kept"
            )
        }
    }

    /// What a Trim Galore storage call does to the reads it stores and what this call removed, the provenance note of
    /// the call's loss. The owner keeps Trim Galore as the most laptop-safe storage tool and asked that its loss be
    /// noted in provenance (Q12, 2026-10-22). Trim Galore 2.3.0, the newest release then, has no option set that turns
    /// its adapter and quality trim or its length filter off (review of lane C2-TRIMGALORE).
    package var removalStatement: String {
        let tool = version.map { "Trim Galore \($0)" } ?? "Trim Galore"
        let quality = qualityCutoff.map { " (quality cutoff \($0))" } ?? ""
        let length = lengthCutoff.map { "the length cutoff of \($0) bases" } ?? "its length cutoff"
        return "\(tool) adapter- and quality-trims every read\(quality) and removes each read that trimming leaves "
            + "shorter than \(length), a pair as a unit in paired mode. No \(tool) option set turns this off. "
            + "This call removed \(removed) of \(totalReads) \(paired ? "pairs" : "reads")."
    }
}
