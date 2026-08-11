// SampleMetadataStore.swift — CSV/TSV sample metadata import and editing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Tracks a single in-app edit for reproducibility.
public struct MetadataEdit: Codable, Sendable {
    public let sampleId: String
    public let columnName: String
    public let oldValue: String?
    public let newValue: String
    public let timestamp: Date
}

/// Result of scanning a CSV/TSV for the column containing sample IDs.
public struct MetadataColumnScanResult: Sendable {
    /// A candidate column that matched at least one known sample ID.
    public struct Candidate: Sendable {
        public let index: Int
        public let name: String
        public let matchCount: Int
    }

    /// The candidate with the most matches (leftmost wins ties). Nil if no column matched.
    public let bestColumn: Candidate?

    /// All columns with at least one match, sorted by match count descending then index ascending.
    public let candidates: [Candidate]

    /// Total number of data rows in the file.
    public let totalRows: Int

    /// Parsed file contents retained for creating the store without re-parsing.
    internal let headers: [String]
    internal let dataRows: [[String]]
    /// Delimiter detected from the source payload.  Persisted metadata keeps
    /// the original bytes even though its stable bundle name is `.tsv`.
    public let delimiter: Character
}

/// Imports, stores, and manages free-form sample metadata from CSV/TSV files.
///
/// Metadata is matched to known sample IDs (case-insensitive). Edits are tracked
/// as a journal for reproducibility and persisted alongside the original file.
@Observable
public final class SampleMetadataStore: @unchecked Sendable {
    public var columnNames: [String]
    public var records: [String: [String: String]]
    public var matchedSampleIds: Set<String>
    public var unmatchedRecords: [String: [String: String]]
    public private(set) var edits: [MetadataEdit] = []

    /// Called after every edit to persist changes. Set by the controller that owns the store.
    @ObservationIgnored public var onEditsChanged: (() -> Void)?

    /// Decodes CSV/TSV data into headers, data rows, and the detected delimiter.
    private static func parseCSV(_ data: Data) throws -> (headers: [String], dataRows: [[String]], delimiter: Character) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MetadataParseError.invalidEncoding
        }

        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let headerLine = lines.first, lines.count > 1 else {
            throw MetadataParseError.noData
        }

        let delimiter: Character = headerLine.contains("\t") ? "\t" : ","
        let headers = try validateHeaders(
            DelimitedLineParser.fields(in: headerLine, delimiter: delimiter)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        guard headers.count >= 2 else {
            throw MetadataParseError.insufficientColumns
        }

        var dataRows: [[String]] = []
        for (offset, line) in lines.dropFirst().enumerated() {
            let fields = DelimitedLineParser.fields(in: line, delimiter: delimiter)
            guard fields.count == headers.count else {
                throw MetadataParseError.rowWidthMismatch(
                    row: offset + 2,
                    expected: headers.count,
                    actual: fields.count
                )
            }
            dataRows.append(fields)
        }

        return (headers: headers, dataRows: dataRows, delimiter: delimiter)
    }

    private static func validateHeaders(_ headers: [String]) throws -> [String] {
        var normalizedHeaders = Set<String>()
        for (index, header) in headers.enumerated() {
            guard !header.isEmpty else {
                throw MetadataParseError.blankHeader(column: index + 1)
            }
            let normalized = normalize(header)
            guard normalizedHeaders.insert(normalized).inserted else {
                throw MetadataParseError.duplicateHeader(normalized)
            }
        }
        return headers
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    public init(csvData: Data, knownSampleIds: Set<String>) throws {
        let (headers, dataRows, _) = try Self.parseCSV(csvData)

        let metadataColumns = Array(headers.dropFirst())
        self.columnNames = metadataColumns

        let knownLookup: [String: String] = Dictionary(
            knownSampleIds.map { (Self.normalize($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var matched: [String: [String: String]] = [:]
        var unmatched: [String: [String: String]] = [:]
        var matchedIds: Set<String> = []

        var seenIDs = Set<String>()
        for fields in dataRows {
            guard let rawId = fields.first else { continue }
            let trimmedID = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedID = Self.normalize(trimmedID)
            guard seenIDs.insert(normalizedID).inserted else {
                throw MetadataParseError.duplicateSampleID(normalizedID)
            }

            var record: [String: String] = [:]
            for (i, col) in metadataColumns.enumerated() {
                let value = (i + 1) < fields.count ? fields[i + 1] : ""
                record[col] = value
            }

            if let knownId = knownLookup[normalizedID] {
                matched[knownId] = record
                matchedIds.insert(knownId)
            } else {
                unmatched[trimmedID] = record
            }
        }

        self.records = matched
        self.matchedSampleIds = matchedIds
        self.unmatchedRecords = unmatched
    }

    /// Internal memberwise initializer for scan-based construction.
    internal init(
        columnNames: [String],
        records: [String: [String: String]],
        matchedSampleIds: Set<String>,
        unmatchedRecords: [String: [String: String]]
    ) {
        self.columnNames = columnNames
        self.records = records
        self.matchedSampleIds = matchedSampleIds
        self.unmatchedRecords = unmatchedRecords
    }

    public convenience init(resolved: ResolvedSampleMetadata) {
        let metadataColumns = resolved.columns.filter {
            SampleMetadataTable.normalizedColumn($0) != "sample_id"
        }
        self.init(
            columnNames: metadataColumns,
            records: resolved.records,
            matchedSampleIds: Set(resolved.sampleIDs),
            unmatchedRecords: [:]
        )
    }

    /// Creates a store using a specific column as the sample ID column.
    public convenience init(
        scanResult: MetadataColumnScanResult,
        sampleColumnIndex: Int,
        knownSampleIds: Set<String>
    ) throws {
        guard scanResult.headers.indices.contains(sampleColumnIndex) else {
            throw MetadataParseError.invalidSampleColumn(sampleColumnIndex)
        }
        let metadataColumns = scanResult.headers.enumerated()
            .filter { $0.offset != sampleColumnIndex }
            .map(\.element)

        let knownLookup: [String: String] = Dictionary(
            knownSampleIds.map { (Self.normalize($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var matched: [String: [String: String]] = [:]
        var unmatched: [String: [String: String]] = [:]
        var matchedIds: Set<String> = []

        var seenIDs = Set<String>()
        for row in scanResult.dataRows {
            guard sampleColumnIndex < row.count else { continue }
            let rawId = row[sampleColumnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedID = Self.normalize(rawId)
            guard seenIDs.insert(normalizedID).inserted else {
                throw MetadataParseError.duplicateSampleID(normalizedID)
            }

            var record: [String: String] = [:]
            var metaIdx = 0
            for (colIdx, value) in row.enumerated() where colIdx != sampleColumnIndex {
                if metaIdx < metadataColumns.count {
                    record[metadataColumns[metaIdx]] = value
                }
                metaIdx += 1
            }

            if let knownId = knownLookup[normalizedID] {
                matched[knownId] = record
                matchedIds.insert(knownId)
            } else {
                unmatched[rawId] = record
            }
        }

        self.init(
            columnNames: metadataColumns,
            records: matched,
            matchedSampleIds: matchedIds,
            unmatchedRecords: unmatched
        )
    }

    /// Scans a CSV/TSV to find which column contains sample IDs.
    public static func scanForSampleColumn(
        csvData: Data,
        knownSampleIds: Set<String>
    ) throws -> MetadataColumnScanResult {
        let (headers, dataRows, delimiter) = try parseCSV(csvData)

        let knownLookup = Set(knownSampleIds.map(Self.normalize))

        var candidates: [MetadataColumnScanResult.Candidate] = []
        for (colIdx, colName) in headers.enumerated() {
            var matchCount = 0
            for row in dataRows {
                guard colIdx < row.count else { continue }
                if knownLookup.contains(Self.normalize(row[colIdx])) {
                    matchCount += 1
                }
            }
            if matchCount > 0 {
                candidates.append(.init(index: colIdx, name: colName, matchCount: matchCount))
            }
        }

        candidates.sort { a, b in
            if a.matchCount != b.matchCount { return a.matchCount > b.matchCount }
            return a.index < b.index
        }

        return MetadataColumnScanResult(
            bestColumn: candidates.first,
            candidates: candidates,
            totalRows: dataRows.count,
            headers: headers,
            dataRows: dataRows,
            delimiter: delimiter
        )
    }

    /// Applies an edit to a sample's metadata value and journals it.
    ///
    /// No-ops (without journaling) if `sampleId` has no records entry -- previously
    /// the optional-chained assignment `records[sampleId]?[column] = newValue` would
    /// silently no-op for an unknown sampleId while the edit was still unconditionally
    /// appended to the journal, diverging in-memory state from the persisted edit log
    /// (a replayed edit on next load would also silently no-op, so the journal kept
    /// claiming an edit that never actually applied). The current UI call site
    /// (LungfishKit/SampleMetadataSection.swift) only iterates matchedSampleIds, which
    /// always have a records entry, so this guard is currently a no-op there; it closes
    /// the footgun for any future/CLI caller that edits an unmatched or newly-added
    /// sample id (R3-R3ML-19).
    public func applyEdit(sampleId: String, column: String, newValue: String) {
        guard records[sampleId] != nil else { return }
        let oldValue = records[sampleId]?[column]
        records[sampleId]?[column] = newValue
        edits.append(MetadataEdit(
            sampleId: sampleId,
            columnName: column,
            oldValue: oldValue,
            newValue: newValue,
            timestamp: Date()
        ))
        onEditsChanged?()
    }

    public func editsJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(edits)
    }

    public func persist(originalData: Data, to bundleURL: URL) throws {
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try originalData.write(to: metadataDir.appendingPathComponent("sample_metadata.tsv"))
        // The journal is a scientific output even when the import has not yet
        // been edited.  Writing an explicit empty journal makes provenance
        // complete and gives subsequent edit replay a stable final path.
        let json = try editsJSON()
        try json.write(to: metadataDir.appendingPathComponent("sample_metadata_edits.json"))
    }

    /// Wires the `onEditsChanged` callback to autosave the edit journal to the bundle.
    public func wireAutosave(bundleURL: URL) {
        onEditsChanged = { [weak self] in
            guard let self else { return }
            let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
            try? FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
            let editsURL = metadataDir.appendingPathComponent("sample_metadata_edits.json")
            try? self.editsJSON().write(to: editsURL)
        }
    }

    public static func load(from bundleURL: URL, knownSampleIds: Set<String>) -> SampleMetadataStore? {
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        let tsvURL = metadataDir.appendingPathComponent("sample_metadata.tsv")
        guard let data = try? Data(contentsOf: tsvURL) else { return nil }
        let store: SampleMetadataStore?
        if let scanResult = try? SampleMetadataStore.scanForSampleColumn(
            csvData: data,
            knownSampleIds: knownSampleIds
        ),
           let bestColumn = scanResult.bestColumn {
            store = try? SampleMetadataStore(
                scanResult: scanResult,
                sampleColumnIndex: bestColumn.index,
                knownSampleIds: knownSampleIds
            )
        } else {
            store = try? SampleMetadataStore(csvData: data, knownSampleIds: knownSampleIds)
        }
        guard let store else { return nil }
        let editsURL = metadataDir.appendingPathComponent("sample_metadata_edits.json")
        if let editsData = try? Data(contentsOf: editsURL),
           let savedEdits = try? JSONDecoder().decode([MetadataEdit].self, from: editsData) {
            for edit in savedEdits {
                store.records[edit.sampleId]?[edit.columnName] = edit.newValue
            }
            store.edits = savedEdits
        }
        return store
    }
}

public enum MetadataParseError: Error, LocalizedError, Equatable {
    case invalidEncoding
    case noData
    case insufficientColumns
    case rowWidthMismatch(row: Int, expected: Int, actual: Int)
    case blankHeader(column: Int)
    case duplicateHeader(String)
    case duplicateSampleID(String)
    case invalidSampleColumn(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "File is not valid UTF-8 text"
        case .noData: return "File contains no data rows"
        case .insufficientColumns: return "File must have at least 2 columns (sample ID + metadata)"
        case .rowWidthMismatch(let row, let expected, let actual):
            return "Metadata row \(row) has \(actual) columns; expected \(expected)"
        case .blankHeader(let column):
            return "Metadata header column \(column) is blank"
        case .duplicateHeader(let header):
            return "Metadata contains duplicate normalized header '\(header)'"
        case .duplicateSampleID(let sampleID):
            return "Metadata contains duplicate normalized sample ID '\(sampleID)'"
        case .invalidSampleColumn(let column):
            return "Metadata sample column \(column + 1) is outside the header range"
        }
    }
}
