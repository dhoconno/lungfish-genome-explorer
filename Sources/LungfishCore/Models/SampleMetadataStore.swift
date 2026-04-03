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

    public init(csvData: Data, knownSampleIds: Set<String>) throws {
        guard let text = String(data: csvData, encoding: .utf8) else {
            throw MetadataParseError.invalidEncoding
        }

        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let headerLine = lines.first, lines.count > 1 else {
            throw MetadataParseError.noData
        }

        let delimiter: Character = headerLine.contains("\t") ? "\t" : ","
        let headers = headerLine.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
        guard headers.count >= 2 else {
            throw MetadataParseError.insufficientColumns
        }

        let metadataColumns = Array(headers.dropFirst())
        self.columnNames = metadataColumns

        let knownLookup: [String: String] = Dictionary(
            knownSampleIds.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var matched: [String: [String: String]] = [:]
        var unmatched: [String: [String: String]] = [:]
        var matchedIds: Set<String> = []

        for line in lines.dropFirst() {
            let fields = line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
            guard let rawId = fields.first else { continue }

            var record: [String: String] = [:]
            for (i, col) in metadataColumns.enumerated() {
                let value = (i + 1) < fields.count ? fields[i + 1] : ""
                record[col] = value
            }

            if let knownId = knownLookup[rawId.lowercased()] {
                matched[knownId] = record
                matchedIds.insert(knownId)
            } else {
                unmatched[rawId] = record
            }
        }

        self.records = matched
        self.matchedSampleIds = matchedIds
        self.unmatchedRecords = unmatched
    }

    public func applyEdit(sampleId: String, column: String, newValue: String) {
        let oldValue = records[sampleId]?[column]
        records[sampleId]?[column] = newValue
        edits.append(MetadataEdit(
            sampleId: sampleId,
            columnName: column,
            oldValue: oldValue,
            newValue: newValue,
            timestamp: Date()
        ))
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
        if !edits.isEmpty {
            let json = try editsJSON()
            try json.write(to: metadataDir.appendingPathComponent("sample_metadata_edits.json"))
        }
    }

    public static func load(from bundleURL: URL, knownSampleIds: Set<String>) -> SampleMetadataStore? {
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        let tsvURL = metadataDir.appendingPathComponent("sample_metadata.tsv")
        guard let data = try? Data(contentsOf: tsvURL) else { return nil }
        guard let store = try? SampleMetadataStore(csvData: data, knownSampleIds: knownSampleIds) else { return nil }
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

public enum MetadataParseError: Error, LocalizedError {
    case invalidEncoding
    case noData
    case insufficientColumns

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "File is not valid UTF-8 text"
        case .noData: return "File contains no data rows"
        case .insufficientColumns: return "File must have at least 2 columns (sample ID + metadata)"
        }
    }
}
