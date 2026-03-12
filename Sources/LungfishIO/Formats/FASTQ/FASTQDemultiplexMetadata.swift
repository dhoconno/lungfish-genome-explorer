// FASTQDemultiplexMetadata.swift - FASTQ demultiplex sample + kit metadata
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Per-sample barcode assignment used for asymmetric demultiplexing.
public struct FASTQSampleBarcodeAssignment: Codable, Sendable, Equatable, Identifiable {
    /// Stable sample identifier used for output naming.
    public let sampleID: String

    /// Optional human-readable sample name.
    public let sampleName: String?

    /// Barcode ID expected near the 5' end.
    public let forwardBarcodeID: String?

    /// Barcode sequence expected near the 5' end.
    public let forwardSequence: String?

    /// Barcode ID expected near the 3' end.
    public let reverseBarcodeID: String?

    /// Barcode sequence expected near the 3' end.
    public let reverseSequence: String?

    /// Additional arbitrary metadata fields for this sample.
    public let metadata: [String: String]

    public var id: String { sampleID }

    public init(
        sampleID: String,
        sampleName: String? = nil,
        forwardBarcodeID: String? = nil,
        forwardSequence: String? = nil,
        reverseBarcodeID: String? = nil,
        reverseSequence: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.sampleID = sampleID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sampleName = sampleName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.forwardBarcodeID = forwardBarcodeID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.forwardSequence = forwardSequence?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().nilIfEmpty
        self.reverseBarcodeID = reverseBarcodeID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.reverseSequence = reverseSequence?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().nilIfEmpty
        self.metadata = metadata
    }
}

/// Persisted FASTQ demultiplex metadata edited through the FASTQ drawer.
public struct FASTQDemultiplexMetadata: Codable, Sendable, Equatable {
    /// Explicit sample-level barcode assignments.
    public var sampleAssignments: [FASTQSampleBarcodeAssignment]

    /// User-defined barcode sets imported from CSV.
    public var customBarcodeSets: [BarcodeKitDefinition]

    /// User-preferred barcode set ID.
    public var preferredBarcodeSetID: String?

    /// Serialized demultiplex plan JSON (app-layer model persisted without cross-module type coupling).
    public var demuxPlanJSON: String?

    public init(
        sampleAssignments: [FASTQSampleBarcodeAssignment] = [],
        customBarcodeSets: [BarcodeKitDefinition] = [],
        preferredBarcodeSetID: String? = nil,
        demuxPlanJSON: String? = nil
    ) {
        self.sampleAssignments = sampleAssignments
        self.customBarcodeSets = customBarcodeSets
        self.preferredBarcodeSetID = preferredBarcodeSetID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.demuxPlanJSON = demuxPlanJSON?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

/// CSV import/export helpers for FASTQ sample barcode assignments.
public enum FASTQSampleBarcodeCSV {

    public enum Error: Swift.Error, LocalizedError {
        case missingRequiredColumn(String)
        case invalidRow(Int, String)

        public var errorDescription: String? {
            switch self {
            case .missingRequiredColumn(let name):
                return "Missing required CSV column '\(name)'."
            case .invalidRow(let index, let reason):
                return "Invalid sample-metadata row \(index): \(reason)"
            }
        }
    }

    public static func load(from url: URL) throws -> [FASTQSampleBarcodeAssignment] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let delimiter: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : ","
        return try parse(content: content, delimiter: delimiter)
    }

    public static func parse(content: String, delimiter: Character = ",") throws -> [FASTQSampleBarcodeAssignment] {
        let rows = parseDelimited(content: content, delimiter: delimiter)
        guard !rows.isEmpty else { return [] }

        let header = rows[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let normalizedHeader = header.map { normalizeColumnName($0) }

        func columnIndex(for aliases: Set<String>) -> Int? {
            normalizedHeader.firstIndex { aliases.contains($0) }
        }

        let sampleIDColumnAliases: Set<String> = ["sample_id", "sample", "sampleid"]
        let sampleNameColumnAliases: Set<String> = ["sample_name", "display_name", "name"]
        let forwardIDAliases: Set<String> = ["barcode_5p", "forward_barcode_id", "barcode5_id", "i7_id"]
        let reverseIDAliases: Set<String> = ["barcode_3p", "reverse_barcode_id", "barcode3_id", "i5_id"]
        let forwardSequenceAliases: Set<String> = ["forward_sequence", "sequence_5p", "barcode_5p_sequence", "i7_sequence"]
        let reverseSequenceAliases: Set<String> = ["reverse_sequence", "sequence_3p", "barcode_3p_sequence", "i5_sequence"]

        guard let sampleIDIndex = columnIndex(for: sampleIDColumnAliases) else {
            throw Error.missingRequiredColumn("sample_id")
        }

        let sampleNameIndex = columnIndex(for: sampleNameColumnAliases)
        let forwardIDIndex = columnIndex(for: forwardIDAliases)
        let reverseIDIndex = columnIndex(for: reverseIDAliases)
        let forwardSeqIndex = columnIndex(for: forwardSequenceAliases)
        let reverseSeqIndex = columnIndex(for: reverseSequenceAliases)

        var assignments: [FASTQSampleBarcodeAssignment] = []
        assignments.reserveCapacity(max(0, rows.count - 1))

        for (line, row) in rows.dropFirst().enumerated() {
            let lineNumber = line + 2
            let sampleID = value(at: sampleIDIndex, in: row).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sampleID.isEmpty else {
                throw Error.invalidRow(lineNumber, "sample_id is empty")
            }

            let forwardID = forwardIDIndex.flatMap { value(at: $0, in: row).nilIfEmpty }
            let reverseID = reverseIDIndex.flatMap { value(at: $0, in: row).nilIfEmpty }
            let forwardSequence = forwardSeqIndex.flatMap { value(at: $0, in: row).uppercased().nilIfEmpty }
            let reverseSequence = reverseSeqIndex.flatMap { value(at: $0, in: row).uppercased().nilIfEmpty }

            if forwardID == nil, reverseID == nil, forwardSequence == nil, reverseSequence == nil {
                throw Error.invalidRow(lineNumber, "at least one barcode ID or sequence must be provided")
            }

            var metadata: [String: String] = [:]
            for (idx, key) in header.enumerated() {
                guard idx != sampleIDIndex,
                      idx != sampleNameIndex,
                      idx != forwardIDIndex,
                      idx != reverseIDIndex,
                      idx != forwardSeqIndex,
                      idx != reverseSeqIndex else {
                    continue
                }
                let v = value(at: idx, in: row).trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    metadata[key] = v
                }
            }

            assignments.append(
                FASTQSampleBarcodeAssignment(
                    sampleID: sampleID,
                    sampleName: sampleNameIndex.flatMap { value(at: $0, in: row).nilIfEmpty },
                    forwardBarcodeID: forwardID,
                    forwardSequence: forwardSequence,
                    reverseBarcodeID: reverseID,
                    reverseSequence: reverseSequence,
                    metadata: metadata
                )
            )
        }

        return assignments
    }

    public static func exportCSV(_ assignments: [FASTQSampleBarcodeAssignment]) -> String {
        var metadataKeys = Set<String>()
        for assignment in assignments {
            metadataKeys.formUnion(assignment.metadata.keys)
        }
        let sortedMetadataKeys = metadataKeys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var columns = [
            "sample_id",
            "sample_name",
            "barcode_5p",
            "forward_sequence",
            "barcode_3p",
            "reverse_sequence",
        ]
        columns.append(contentsOf: sortedMetadataKeys)

        var lines: [String] = [columns.joined(separator: ",")]
        lines.reserveCapacity(assignments.count + 1)

        for assignment in assignments {
            var values: [String] = [
                assignment.sampleID,
                assignment.sampleName ?? "",
                assignment.forwardBarcodeID ?? "",
                assignment.forwardSequence ?? "",
                assignment.reverseBarcodeID ?? "",
                assignment.reverseSequence ?? "",
            ]
            for key in sortedMetadataKeys {
                values.append(assignment.metadata[key] ?? "")
            }
            lines.append(values.map(escapeCSV).joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func value(at index: Int, in row: [String]) -> String {
        guard index >= 0, index < row.count else { return "" }
        return row[index]
    }

    private static func normalizeColumnName(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func parseDelimited(content: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        rows.reserveCapacity(128)

        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        var iterator = content.makeIterator()

        while let char = iterator.next() {
            if inQuotes {
                if char == "\"" {
                    if let peek = iterator.next() {
                        if peek == "\"" {
                            currentField.append("\"")
                        } else {
                            inQuotes = false
                            processDelimiterCandidate(peek, delimiter: delimiter, row: &currentRow, field: &currentField, rows: &rows)
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(char)
                }
            } else {
                if char == "\"" {
                    inQuotes = true
                } else {
                    processDelimiterCandidate(char, delimiter: delimiter, row: &currentRow, field: &currentField, rows: &rows)
                }
            }
        }

        currentRow.append(currentField)
        if !currentRow.allSatisfy({ $0.isEmpty }) {
            rows.append(currentRow)
        }

        return rows
    }

    private static func processDelimiterCandidate(
        _ char: Character,
        delimiter: Character,
        row: inout [String],
        field: inout String,
        rows: inout [[String]]
    ) {
        if char == delimiter {
            row.append(field)
            field.removeAll(keepingCapacity: true)
            return
        }

        if char == "\n" || char == "\r" {
            if char == "\r" {
                return
            }
            row.append(field)
            field.removeAll(keepingCapacity: true)
            if !row.allSatisfy({ $0.isEmpty }) {
                rows.append(row)
            }
            row.removeAll(keepingCapacity: true)
            return
        }

        field.append(char)
    }

    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
