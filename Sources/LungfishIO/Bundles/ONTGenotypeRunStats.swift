import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeRunStats: Codable, Equatable, Sendable {
    public let totalInputReads: Int?
    /// The unit of `totalInputReads` and of every retention percentage's
    /// denominator: "fragments" when the run merged pairs (one count per
    /// physical molecule), "reads" otherwise, `nil` for stats written before
    /// the unit was recorded.
    public let totalInputReadsUnit: String?
    public let totalAlignments: Int?
    public let passedAlignments: Int?
    public let retainedUniqueReads: Int?
    public let retainedUniquePercentOfTotalReads: Double?
    public let assignedUniqueRetainedReads: Int?
    public let unassignedUniqueRetainedReads: Int?
    public let rawMetrics: [String: String]

    public init(
        totalInputReads: Int? = nil,
        totalInputReadsUnit: String? = nil,
        totalAlignments: Int? = nil,
        passedAlignments: Int? = nil,
        retainedUniqueReads: Int? = nil,
        retainedUniquePercentOfTotalReads: Double? = nil,
        assignedUniqueRetainedReads: Int? = nil,
        unassignedUniqueRetainedReads: Int? = nil,
        rawMetrics: [String: String] = [:]
    ) {
        self.totalInputReads = totalInputReads
        self.totalInputReadsUnit = totalInputReadsUnit
        self.totalAlignments = totalAlignments
        self.passedAlignments = passedAlignments
        self.retainedUniqueReads = retainedUniqueReads
        self.retainedUniquePercentOfTotalReads = retainedUniquePercentOfTotalReads
        self.assignedUniqueRetainedReads = assignedUniqueRetainedReads
        self.unassignedUniqueRetainedReads = unassignedUniqueRetainedReads
        self.rawMetrics = rawMetrics
    }

    static func load(from url: URL) throws -> ONTGenotypeRunStats {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ONTGenotypeRunStats()
        }

        var rawMetrics: [String: String] = [:]
        for (key, value) in object {
            if let dictionary = value as? [String: Any] {
                if let data = try? JSONSerialization.data(withJSONObject: dictionary),
                   let json = String(data: data, encoding: .utf8) {
                    rawMetrics[key] = json
                }
            } else if let array = value as? [Any] {
                if let data = try? JSONSerialization.data(withJSONObject: array),
                   let json = String(data: data, encoding: .utf8) {
                    rawMetrics[key] = json
                }
            } else if value is NSNull {
                rawMetrics[key] = "null"
            } else {
                rawMetrics[key] = String(describing: value)
            }
        }

        return ONTGenotypeRunStats(
            totalInputReads: intValue(object["totalInputReads"]),
            totalInputReadsUnit: object["totalInputReadsUnit"] as? String,
            totalAlignments: intValue(object["totalAlignments"]),
            passedAlignments: intValue(object["passedAlignments"]),
            retainedUniqueReads: intValue(object["retainedUniqueReads"]),
            retainedUniquePercentOfTotalReads: doubleValue(object["retainedUniquePercentOfTotalReads"]),
            assignedUniqueRetainedReads: intValue(object["assignedUniqueRetainedReads"]),
            unassignedUniqueRetainedReads: intValue(object["unassignedUniqueRetainedReads"]),
            rawMetrics: rawMetrics
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return ONTGenotypeResultBundle.parseInt(string) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return ONTGenotypeResultBundle.parseDouble(string) }
        return nil
    }
}
