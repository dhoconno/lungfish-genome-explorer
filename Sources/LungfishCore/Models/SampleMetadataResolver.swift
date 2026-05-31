// SampleMetadataResolver.swift - Layered sample metadata resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Splits a single line of delimited text (CSV/TSV) into fields.
///
/// Quote-aware: a field wrapped in double quotes may contain the delimiter, and a
/// doubled quote (`""`) inside a quoted field is un-escaped to a single `"`. Empty
/// fields are preserved (matching `String.split(omittingEmptySubsequences: false)`),
/// so `"a,,c"` yields `["a", "", "c"]` and a trailing delimiter keeps the trailing
/// empty field. Tab-delimited input is split on the literal delimiter without quote
/// handling, mirroring conventional TSV parsing.
public enum DelimitedLineParser {
    public static func fields(in line: String, delimiter: Character) -> [String] {
        guard delimiter == "," else {
            return line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
        }

        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let char = iterator.next() {
            if char == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        current.append("\"")
                    } else {
                        inQuotes.toggle()
                        if next == delimiter {
                            fields.append(current)
                            current = ""
                        } else {
                            current.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            } else if char == delimiter && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }
}

public enum SampleMetadataSourceKind: String, Codable, Sendable, Equatable {
    case intrinsic
    case fastqFolder
    case fastqBundle
    case analysisOverride
    case importedCSV
}

public struct SampleMetadataSourceSummary: Codable, Equatable, Sendable {
    public let kind: SampleMetadataSourceKind
    public let path: String?
    public let sampleColumnName: String?
    public let delimiter: String?
    public let totalRows: Int?
    public let matchedSampleCount: Int?
    public let unmatchedRowCount: Int?
    public let missingSampleCount: Int?

    public init(
        kind: SampleMetadataSourceKind,
        path: String? = nil,
        sampleColumnName: String? = nil,
        delimiter: String? = nil,
        totalRows: Int? = nil,
        matchedSampleCount: Int? = nil,
        unmatchedRowCount: Int? = nil,
        missingSampleCount: Int? = nil
    ) {
        self.kind = kind
        self.path = path
        self.sampleColumnName = sampleColumnName
        self.delimiter = delimiter
        self.totalRows = totalRows
        self.matchedSampleCount = matchedSampleCount
        self.unmatchedRowCount = unmatchedRowCount
        self.missingSampleCount = missingSampleCount
    }

    public func replacingCounts(
        sampleColumnName: String? = nil,
        delimiter: String? = nil,
        totalRows: Int? = nil,
        matchedSampleCount: Int? = nil,
        unmatchedRowCount: Int? = nil,
        missingSampleCount: Int? = nil
    ) -> SampleMetadataSourceSummary {
        SampleMetadataSourceSummary(
            kind: kind,
            path: path,
            sampleColumnName: sampleColumnName ?? self.sampleColumnName,
            delimiter: delimiter ?? self.delimiter,
            totalRows: totalRows ?? self.totalRows,
            matchedSampleCount: matchedSampleCount ?? self.matchedSampleCount,
            unmatchedRowCount: unmatchedRowCount ?? self.unmatchedRowCount,
            missingSampleCount: missingSampleCount ?? self.missingSampleCount
        )
    }
}

public enum SampleMetadataResolverError: Error, LocalizedError, Equatable {
    case invalidEncoding
    case noData
    case insufficientColumns
    case inconsistentColumnCount(row: Int, expected: Int, actual: Int)
    case emptySampleID(row: Int)
    case duplicateSampleID(String)
    case noSampleColumn
    case noMatchingSamples

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "Sample metadata is not valid UTF-8 text."
        case .noData:
            return "Sample metadata contains no data rows."
        case .insufficientColumns:
            return "Sample metadata must include a sample ID column and at least one metadata column."
        case let .inconsistentColumnCount(row, expected, actual):
            return "Sample metadata row \(row) has \(actual) columns; expected \(expected)."
        case let .emptySampleID(row):
            return "Sample metadata row \(row) has an empty sample ID."
        case let .duplicateSampleID(sampleID):
            return "Sample metadata contains duplicate sample ID '\(sampleID)'."
        case .noSampleColumn:
            return "No sample ID column could be identified in the metadata file."
        case .noMatchingSamples:
            return "Sample metadata did not match any known sample IDs."
        }
    }
}

public struct SampleMetadataTable: Codable, Equatable, Sendable {
    public let columns: [String]
    public let records: [String: [String: String]]
    public let unmatchedRecords: [String: [String: String]]
    public let source: SampleMetadataSourceSummary

    public init(
        columns: [String],
        records: [String: [String: String]],
        unmatchedRecords: [String: [String: String]] = [:],
        source: SampleMetadataSourceSummary
    ) {
        self.columns = Self.uniquedColumns(columns.filter { Self.normalizedColumn($0) != "sample_id" })
        self.records = records
        self.unmatchedRecords = unmatchedRecords
        self.source = source
    }

    public static func parseDelimited(
        data: Data,
        knownSampleIDs: [String],
        source: SampleMetadataSourceSummary
    ) throws -> SampleMetadataTable {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SampleMetadataResolverError.invalidEncoding
        }
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let headerLine = lines.first, lines.count > 1 else {
            throw SampleMetadataResolverError.noData
        }

        let delimiter = headerLine.contains("\t") ? "\t" : ","
        let headers = split(line: headerLine, delimiter: delimiter)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard headers.count >= 2 else {
            throw SampleMetadataResolverError.insufficientColumns
        }

        let rows = try lines.dropFirst().enumerated().map { index, line -> [String] in
            let row = split(line: line, delimiter: delimiter)
            guard row.count == headers.count else {
                throw SampleMetadataResolverError.inconsistentColumnCount(
                    row: index + 2,
                    expected: headers.count,
                    actual: row.count
                )
            }
            return row
        }
        guard !rows.isEmpty else {
            throw SampleMetadataResolverError.noData
        }

        let knownLookup = Dictionary(
            knownSampleIDs.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let sampleColumnIndex = try chooseSampleColumn(headers: headers, rows: rows, knownLookup: knownLookup)
        let metadataColumns = headers.enumerated()
            .filter { $0.offset != sampleColumnIndex }
            .map(\.element)

        var seenRawIDs = Set<String>()
        var records: [String: [String: String]] = [:]
        var unmatchedRecords: [String: [String: String]] = [:]
        for (rowIndex, row) in rows.enumerated() {
            let rawID = row[sampleColumnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawID.isEmpty else {
                throw SampleMetadataResolverError.emptySampleID(row: rowIndex + 2)
            }
            let duplicateKey = rawID.lowercased()
            guard seenRawIDs.insert(duplicateKey).inserted else {
                throw SampleMetadataResolverError.duplicateSampleID(rawID)
            }

            var record: [String: String] = [:]
            var metadataIndex = 0
            for (columnIndex, value) in row.enumerated() where columnIndex != sampleColumnIndex {
                guard metadataIndex < metadataColumns.count else { continue }
                record[metadataColumns[metadataIndex]] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                metadataIndex += 1
            }

            if let knownID = knownLookup[rawID.lowercased()] {
                records[knownID] = record
            } else {
                unmatchedRecords[rawID] = record
            }
        }

        guard !records.isEmpty else {
            throw SampleMetadataResolverError.noMatchingSamples
        }

        let enrichedSource = source.replacingCounts(
            sampleColumnName: headers[sampleColumnIndex],
            delimiter: delimiter == "\t" ? "tab" : "comma",
            totalRows: rows.count,
            matchedSampleCount: records.count,
            unmatchedRowCount: unmatchedRecords.count,
            missingSampleCount: max(0, knownSampleIDs.count - records.count)
        )
        return SampleMetadataTable(
            columns: metadataColumns,
            records: records,
            unmatchedRecords: unmatchedRecords,
            source: enrichedSource
        )
    }

    private static func chooseSampleColumn(
        headers: [String],
        rows: [[String]],
        knownLookup: [String: String]
    ) throws -> Int {
        let preferredNames: Set<String> = ["sample_id", "sample", "sample_name", "id"]
        let candidates = headers.indices.map { index -> (index: Int, preferred: Bool, matches: Int) in
            let normalizedHeader = normalizedColumn(headers[index])
            let matches = rows.reduce(0) { count, row in
                guard index < row.count else { return count }
                return knownLookup[row[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] == nil
                    ? count
                    : count + 1
            }
            return (index: index, preferred: preferredNames.contains(normalizedHeader), matches: matches)
        }
        let preferredMatches = candidates
            .filter { $0.preferred && $0.matches > 0 }
            .sorted { lhs, rhs in
                if lhs.matches != rhs.matches { return lhs.matches > rhs.matches }
                return lhs.index < rhs.index
            }
        if let best = preferredMatches.first {
            return best.index
        }

        let anyMatches = candidates
            .filter { $0.matches > 0 }
            .sorted { lhs, rhs in
                if lhs.matches != rhs.matches { return lhs.matches > rhs.matches }
                return lhs.index < rhs.index
            }
        if let best = anyMatches.first {
            return best.index
        }

        if let preferred = candidates.first(where: { $0.preferred }) {
            return preferred.index
        }
        throw SampleMetadataResolverError.noSampleColumn
    }

    private static func split(line: String, delimiter: String) -> [String] {
        let separator: Character = delimiter == "," ? "," : "\t"
        return DelimitedLineParser.fields(in: line, delimiter: separator)
    }

    private static func uniquedColumns(_ columns: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for column in columns {
            let trimmed = column.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = normalizedColumn(trimmed)
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func normalizedColumn(_ column: String) -> String {
        column.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }
}

public struct ResolvedSampleMetadata: Codable, Equatable, Sendable {
    public let columns: [String]
    public let sampleIDs: [String]
    public let records: [String: [String: String]]
    public let cellSources: [String: [String: SampleMetadataSourceSummary]]
    public let sources: [SampleMetadataSourceSummary]
    public let warnings: [String]

    public init(
        columns: [String],
        sampleIDs: [String],
        records: [String: [String: String]],
        cellSources: [String: [String: SampleMetadataSourceSummary]] = [:],
        sources: [SampleMetadataSourceSummary] = [],
        warnings: [String] = []
    ) {
        var normalizedColumns = ["sample_id"]
        for column in columns where SampleMetadataTable.normalizedColumn(column) != "sample_id" {
            let key = SampleMetadataTable.normalizedColumn(column)
            if !normalizedColumns.map(SampleMetadataTable.normalizedColumn).contains(key) {
                normalizedColumns.append(column)
            }
        }
        self.columns = normalizedColumns
        self.sampleIDs = sampleIDs
        self.records = records
        self.cellSources = cellSources
        self.sources = sources
        self.warnings = warnings
    }

    public func tsvString() -> String {
        var lines = [columns.map(Self.tsvEscape).joined(separator: "\t")]
        for sampleID in sampleIDs {
            let record = records[sampleID, default: [:]]
            let values = columns.map { column -> String in
                if SampleMetadataTable.normalizedColumn(column) == "sample_id" {
                    return sampleID
                }
                return record[column, default: ""]
            }
            lines.append(values.map(Self.tsvEscape).joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func writeTSV(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try tsvString().write(to: url, atomically: true, encoding: .utf8)
    }

    public static func loadTSV(from url: URL) throws -> ResolvedSampleMetadata {
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw SampleMetadataResolverError.invalidEncoding
        }
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let headerLine = lines.first, lines.count > 1 else {
            throw SampleMetadataResolverError.noData
        }
        let headers = headerLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let sampleColumnIndex = headers.firstIndex(where: { SampleMetadataTable.normalizedColumn($0) == "sample_id" }) else {
            throw SampleMetadataResolverError.noSampleColumn
        }
        var sampleIDs: [String] = []
        var records: [String: [String: String]] = [:]
        for (rowIndex, line) in lines.dropFirst().enumerated() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == headers.count else {
                throw SampleMetadataResolverError.inconsistentColumnCount(
                    row: rowIndex + 2,
                    expected: headers.count,
                    actual: fields.count
                )
            }
            let sampleID = fields[sampleColumnIndex]
            guard !sampleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SampleMetadataResolverError.emptySampleID(row: rowIndex + 2)
            }
            sampleIDs.append(sampleID)
            var record: [String: String] = [:]
            for (index, header) in headers.enumerated() where index != sampleColumnIndex {
                record[header] = fields[index]
            }
            records[sampleID] = record
        }
        return ResolvedSampleMetadata(
            columns: headers,
            sampleIDs: sampleIDs,
            records: records
        )
    }

    private static func tsvEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

public enum SampleMetadataResolver {
    public static func resolve(
        sampleIDs: [String],
        sourceTables: [SampleMetadataTable]
    ) -> ResolvedSampleMetadata {
        var columns = ["sample_id"]
        var outputColumnByNormalizedName = ["sample_id": "sample_id"]
        for table in sourceTables {
            for column in table.columns {
                let key = SampleMetadataTable.normalizedColumn(column)
                guard outputColumnByNormalizedName[key] == nil else { continue }
                columns.append(column)
                outputColumnByNormalizedName[key] = column
            }
        }

        var records: [String: [String: String]] = Dictionary(
            uniqueKeysWithValues: sampleIDs.map { ($0, [:]) }
        )
        var cellSources: [String: [String: SampleMetadataSourceSummary]] = [:]
        var warnings: [String] = []

        for table in sourceTables {
            if let missing = table.source.missingSampleCount, missing > 0 {
                warnings.append("\(missing) sample(s) were missing from \(table.source.kind.rawValue) metadata.")
            }
            if let unmatched = table.source.unmatchedRowCount, unmatched > 0 {
                warnings.append("\(unmatched) metadata row(s) did not match known samples.")
            }
            for sampleID in sampleIDs {
                guard let incoming = table.records[sampleID] else { continue }
                for column in table.columns {
                    let outputColumn = outputColumnByNormalizedName[
                        SampleMetadataTable.normalizedColumn(column),
                        default: column
                    ]
                    guard let value = incoming[column]?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !value.isEmpty else {
                        continue
                    }
                    records[sampleID, default: [:]][outputColumn] = value
                    cellSources[sampleID, default: [:]][outputColumn] = table.source
                }
            }
        }

        return ResolvedSampleMetadata(
            columns: columns,
            sampleIDs: sampleIDs,
            records: records,
            cellSources: cellSources,
            sources: sourceTables.map(\.source),
            warnings: warnings
        )
    }
}
