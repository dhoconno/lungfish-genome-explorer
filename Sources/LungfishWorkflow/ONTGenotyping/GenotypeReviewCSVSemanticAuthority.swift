import Darwin
import CryptoKit
import Foundation
import LungfishIO

struct GenotypeReviewCSVSemanticAuthority: Sendable {
    let roster: [String]
    let calls: [ONTGenotypeCall]
    let sampleSnapshot: GenotypeReviewAuthorityFileSnapshot
    let reportSnapshot: GenotypeReviewAuthorityFileSnapshot

    static func capture(
        sampleSummaryURL: URL,
        reportURL: URL
    ) throws -> Self {
        let sampleSnapshot = try GenotypeReviewAuthorityFileSnapshot.capture(
            sampleSummaryURL
        )
        let reportSnapshot = try GenotypeReviewAuthorityFileSnapshot.capture(
            reportURL
        )
        let sampleRows = try rows(from: sampleSnapshot)
        let reportRows = try rows(from: reportSnapshot)
        let calls = try parseCalls(reportRows, path: reportURL.path)
        let roster = try parseRoster(sampleRows, path: sampleSummaryURL.path)
        let rosterSamples = Set(roster)
        if let outsideRoster = calls.first(where: {
            !rosterSamples.contains($0.sample)
        }) {
            throw GenotypeReviewableRowCatalogPublisherError
                .sampleOutsideRoster(outsideRoster.sample)
        }
        return Self(
            roster: roster,
            calls: calls,
            sampleSnapshot: sampleSnapshot,
            reportSnapshot: reportSnapshot
        )
    }

    func requireMatches(
        expectedRoster: [String],
        expectedCalls: [ONTGenotypeCall]
    ) throws {
        guard Set(roster) == Set(expectedRoster),
              roster.count == expectedRoster.count else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(
                    "\(sampleSnapshot.url.path) (captured roster \(roster), expected \(expectedRoster))"
                )
        }
        guard try Self.supportProjection(calls)
            == Self.supportProjection(expectedCalls) else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(reportSnapshot.url.path)
        }
    }

    func requireUnchanged() throws {
        try sampleSnapshot.requireUnchanged()
        try reportSnapshot.requireUnchanged()
    }

    private struct SupportKey: Hashable {
        let sample: String
        let genotype: String
    }

    private struct SupportValue: Equatable {
        var alignments: Int
        var uniqueReads: Int
    }

    private static func supportProjection(
        _ calls: [ONTGenotypeCall]
    ) throws -> [SupportKey: SupportValue] {
        var result: [SupportKey: SupportValue] = [:]
        for call in calls {
            let key = SupportKey(sample: call.sample, genotype: call.genotype)
            var value = result[key] ?? SupportValue(
                alignments: 0,
                uniqueReads: 0
            )
            let alignments = value.alignments.addingReportingOverflow(
                call.passedAlignments
            )
            let uniqueReads = value.uniqueReads.addingReportingOverflow(
                call.passedUniqueReads
            )
            guard !alignments.overflow, !uniqueReads.overflow else {
                throw GenotypeReviewableRowCatalogPublisherError.invalidSupport(
                    sample: call.sample,
                    value: Int.max
                )
            }
            value.alignments = alignments.partialValue
            value.uniqueReads = uniqueReads.partialValue
            result[key] = value
        }
        return result
    }

    private static func rows(
        from snapshot: GenotypeReviewAuthorityFileSnapshot
    ) throws -> [[String: String]] {
        guard let content = String(data: snapshot.data, encoding: .utf8) else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(snapshot.url.path)
        }
        let normalizedContent = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let parsed = parseCSV(normalizedContent)
        guard let header = parsed.first else { return [] }
        let normalizedHeader = header.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var seenHeaders = Set<String>()
        guard normalizedHeader.allSatisfy({
            !$0.isEmpty && seenHeaders.insert($0).inserted
        }) else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(snapshot.url.path)
        }
        return parsed.dropFirst().map { row in
            Dictionary(uniqueKeysWithValues: normalizedHeader.enumerated().map {
                let value = $0.offset < row.count ? row[$0.offset] : ""
                return (
                    $0.element,
                    value.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            })
        }
    }

    private static func parseRoster(
        _ rows: [[String: String]],
        path: String
    ) throws -> [String] {
        var seen = Set<String>()
        return try rows.compactMap { row in
            let sample = row["sample", default: ""]
            guard isAssignedSample(sample) else { return nil }
            guard seen.insert(sample).inserted else {
                throw GenotypeReviewableRowCatalogPublisherError
                    .authorityChanged(path)
            }
            return sample
        }
    }

    private static func parseCalls(
        _ rows: [[String: String]],
        path: String
    ) throws -> [ONTGenotypeCall] {
        try rows.compactMap { row in
            let sample = row["sample", default: ""]
            let genotype = row["genotype", default: ""]
            guard isAssignedSample(sample), !genotype.isEmpty else { return nil }
            guard let alignments = Int(row["passed_alignments", default: ""]),
                  let uniqueReads = Int(
                    row["passed_unique_reads", default: ""]
                  ),
                  alignments >= 0,
                  uniqueReads >= 0 else {
                throw GenotypeReviewableRowCatalogPublisherError
                    .authorityChanged(path)
            }
            func optionalInt(_ key: String) -> Int? {
                let value = row[key, default: ""]
                return value.isEmpty ? nil : Int(value)
            }
            func optionalDouble(_ key: String) -> Double? {
                let value = row[key, default: ""]
                return value.isEmpty ? nil : Double(value)
            }
            return ONTGenotypeCall(
                sample: sample,
                genotype: genotype,
                passedAlignments: alignments,
                passedUniqueReads: uniqueReads,
                sampleTotalReads: optionalInt("sample_total_reads"),
                sampleUniqueRetainedReads: optionalInt(
                    "sample_unique_retained_reads"
                ),
                sampleUniqueRetainedPercent: optionalDouble(
                    "sample_unique_retained_percent"
                ),
                overallInputReads: optionalInt("overall_input_reads"),
                overallUniqueRetainedReads: optionalInt(
                    "overall_unique_retained_reads"
                ),
                overallUniqueRetainedPercent: optionalDouble(
                    "overall_unique_retained_percent"
                )
            )
        }
    }

    private static func isAssignedSample(_ sample: String) -> Bool {
        let normalized = sample
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !normalized.isEmpty && normalized != "unassigned"
    }

    private static func parseCSV(_ content: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = content.makeIterator()
        while let character = iterator.next() {
            switch character {
            case "\"":
                if inQuotes {
                    var peek = iterator
                    if peek.next() == "\"" {
                        field.append("\"")
                        iterator = peek
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            case "," where !inQuotes:
                row.append(field)
                field = ""
            case "\n" where !inQuotes:
                row.append(field)
                if row.contains(where: {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty
                }) {
                    rows.append(row)
                }
                row = []
                field = ""
            case "\r" where !inQuotes:
                continue
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
