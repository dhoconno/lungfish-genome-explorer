// FASTQSampleSheet.swift - CSV sample sheet parser for paired FASTQ imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct FASTQSampleSheet: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let sampleName: String
        public let r1: URL
        public let r2: URL
        public let metadata: [String: String]

        public init(sampleName: String, r1: URL, r2: URL, metadata: [String: String] = [:]) {
            self.sampleName = sampleName
            self.r1 = r1
            self.r2 = r2
            self.metadata = metadata
        }
    }

    public let sourceURL: URL
    public let entries: [Entry]

    public init(sourceURL: URL, entries: [Entry]) throws {
        guard !entries.isEmpty else { throw FASTQSampleSheetError.emptyFile }
        self.sourceURL = sourceURL
        self.entries = entries
    }

    public static func parse(url: URL) throws -> FASTQSampleSheet {
        let csv = try String(contentsOf: url, encoding: .utf8)
        return try parse(csv: csv, sourceURL: url)
    }

    public static func parse(csv: String, sourceURL: URL) throws -> FASTQSampleSheet {
        let records = parseCSVRecords(csv)
            .filter { row in row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        guard let header = records.first else { throw FASTQSampleSheetError.emptyFile }

        let normalized = header.map(normalizeHeader)
        guard let sampleIndex = normalized.firstIndex(of: "sample"),
              let r1Index = normalized.firstIndex(of: "r1"),
              let r2Index = normalized.firstIndex(of: "r2") else {
            throw FASTQSampleSheetError.missingRequiredColumns
        }

        var entries: [Entry] = []
        let baseDirectory = sourceURL.deletingLastPathComponent()
        for (offset, row) in records.dropFirst().enumerated() {
            let line = offset + 2
            let sample = value(in: row, at: sampleIndex).trimmingCharacters(in: .whitespacesAndNewlines)
            let r1Text = value(in: row, at: r1Index).trimmingCharacters(in: .whitespacesAndNewlines)
            let r2Text = value(in: row, at: r2Index).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !sample.isEmpty else { throw FASTQSampleSheetError.emptyValue(column: "sample", line: line) }
            guard !r1Text.isEmpty else { throw FASTQSampleSheetError.emptyValue(column: "r1", line: line) }
            guard !r2Text.isEmpty else { throw FASTQSampleSheetError.emptyValue(column: "r2", line: line) }

            var metadata: [String: String] = [:]
            for (index, rawHeader) in header.enumerated() {
                guard index != sampleIndex, index != r1Index, index != r2Index else { continue }
                let key = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
                let field = value(in: row, at: index).trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty, !field.isEmpty {
                    metadata[key] = field
                }
            }

            entries.append(Entry(
                sampleName: sample,
                r1: resolvePath(r1Text, relativeTo: baseDirectory),
                r2: resolvePath(r2Text, relativeTo: baseDirectory),
                metadata: metadata
            ))
        }

        return try FASTQSampleSheet(sourceURL: sourceURL, entries: entries)
    }

    public func samplePairs() -> [SamplePair] {
        entries.map {
            SamplePair(
                sampleName: $0.sampleName,
                r1: $0.r1,
                r2: $0.r2,
                metadata: $0.metadata,
                sampleSheetURL: sourceURL
            )
        }
    }

    private static func normalizeHeader(_ header: String) -> String {
        header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func value(in row: [String], at index: Int) -> String {
        index < row.count ? row[index] : ""
    }

    private static func resolvePath(_ path: String, relativeTo directory: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return directory.appendingPathComponent(expanded)
    }

    private static func parseCSVRecords(_ csv: String) -> [[String]] {
        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = csv.makeIterator()

        while let char = iterator.next() {
            switch char {
            case "\"":
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        if next == "," {
                            row.append(field)
                            field = ""
                        } else if next == "\n" {
                            row.append(field)
                            records.append(row)
                            row = []
                            field = ""
                        } else if next != "\r" {
                            field.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            case "," where !inQuotes:
                row.append(field)
                field = ""
            case "\n" where !inQuotes:
                row.append(field)
                records.append(row)
                row = []
                field = ""
            case "\r" where !inQuotes:
                continue
            default:
                field.append(char)
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            records.append(row)
        }
        return records
    }
}

public enum FASTQSampleSheetError: Error, LocalizedError, Sendable, Equatable {
    case emptyFile
    case missingRequiredColumns
    case emptyValue(column: String, line: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "Sample sheet is empty."
        case .missingRequiredColumns:
            return "Sample sheet must contain sample, r1, and r2 columns."
        case .emptyValue(let column, let line):
            return "Sample sheet line \(line) has an empty \(column) value."
        }
    }
}
