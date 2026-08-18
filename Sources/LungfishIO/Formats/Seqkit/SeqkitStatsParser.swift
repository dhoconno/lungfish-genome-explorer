// SeqkitStatsParser.swift - Header-driven parser for `seqkit stats` tabular output
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reference: https://bioinf.shenwei.me/seqkit/usage/#stats

import Foundation
import LungfishCore
import os

/// Logger for seqkit stats parsing operations.
private let logger = Logger(subsystem: LogSubsystem.io, category: "SeqkitStatsParser")

/// Errors raised while parsing `seqkit stats` output.
public enum SeqkitStatsParseError: Error, LocalizedError, Sendable, Equatable {

    /// The output contained no header line.
    case emptyOutput

    /// The output had a header but no data row.
    case missingDataRow

    /// A data row had a different number of cells than the header.
    case columnCountMismatch(headers: Int, values: Int, row: Int)

    /// A column the parser depends on was absent from the header.
    case missingColumn(String)

    /// A required column was present but its value was not a number.
    case invalidValue(column: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .emptyOutput:
            return "seqkit stats produced no output"
        case .missingDataRow:
            return "seqkit stats produced no data row"
        case .columnCountMismatch(let headers, let values, let row):
            return "seqkit stats header/value mismatch on row \(row) (headers=\(headers), values=\(values))"
        case .missingColumn(let name):
            return "seqkit stats output is missing required column '\(name)'"
        case .invalidValue(let column, let value):
            return "seqkit stats column '\(column)' is not numeric: '\(value)'"
        }
    }
}

/// One data row of `seqkit stats` output.
///
/// Only ``numSeqs`` is required. Every other metric is optional because which
/// columns seqkit emits depends on the flags used (`-a` adds the quality and
/// N50 columns) and on the input format (FASTA input has no quality columns).
public struct SeqkitStatsRow: Sendable, Equatable {

    /// The `file` column, or an empty string when seqkit omitted it.
    public let file: String

    /// The `num_seqs` column. Always present -- parsing fails without it.
    public let numSeqs: Int

    /// The `sum_len` column, or 0 when absent.
    public let sumLen: Int

    /// The `min_len` column, or 0 when absent.
    public let minLen: Int

    /// The `avg_len` column, or 0 when absent.
    public let avgLen: Double

    /// The `max_len` column, or 0 when absent.
    public let maxLen: Int

    /// The `Q1` column (first quartile of sequence length), if reported.
    public let q1: Double?

    /// The `Q2` column (median sequence length), if reported.
    public let q2: Double?

    /// The `Q3` column (third quartile of sequence length), if reported.
    public let q3: Double?

    /// The `sum_gap` column, if reported.
    public let sumGap: Double?

    /// The `N50` column, if reported.
    public let n50: Double?

    /// The `Q20(%)` column, if reported.
    public let q20Percent: Double?

    /// The `Q30(%)` column, if reported.
    public let q30Percent: Double?

    /// The `AvgQual` column, if reported.
    public let avgQual: Double?

    /// The `GC(%)` column, if reported.
    public let gcPercent: Double?

    public init(
        file: String,
        numSeqs: Int,
        sumLen: Int,
        minLen: Int,
        avgLen: Double,
        maxLen: Int,
        q1: Double? = nil,
        q2: Double? = nil,
        q3: Double? = nil,
        sumGap: Double? = nil,
        n50: Double? = nil,
        q20Percent: Double? = nil,
        q30Percent: Double? = nil,
        avgQual: Double? = nil,
        gcPercent: Double? = nil
    ) {
        self.file = file
        self.numSeqs = numSeqs
        self.sumLen = sumLen
        self.minLen = minLen
        self.avgLen = avgLen
        self.maxLen = maxLen
        self.q1 = q1
        self.q2 = q2
        self.q3 = q3
        self.sumGap = sumGap
        self.n50 = n50
        self.q20Percent = q20Percent
        self.q30Percent = q30Percent
        self.avgQual = avgQual
        self.gcPercent = gcPercent
    }
}

/// A header-driven parser for `seqkit stats` tabular output.
///
/// Callers previously indexed the output by fixed column position, which meant a
/// seqkit release that added or reordered a column would silently return the
/// wrong number. This parser resolves every field by its header name instead:
/// extra and reordered columns are tolerated, an absent `num_seqs` column is a
/// hard error, and absent optional columns become `nil`.
///
/// ## Usage
///
/// ```swift
/// let row = try SeqkitStatsParser.parse(result.stdout)
/// print("\(row.numSeqs) reads, \(row.sumLen) bases")
/// ```
///
/// ## Thread Safety
///
/// All methods are static and pure. They are safe to call from any isolation
/// domain.
public enum SeqkitStatsParser {

    /// The one column the parser cannot work without.
    public static let requiredColumn = "num_seqs"

    // MARK: - Public API

    /// Parses the first data row of `seqkit stats` output.
    ///
    /// - Parameter text: Raw stdout from `seqkit stats` (with or without `-a` / `-T`).
    /// - Returns: The first data row.
    /// - Throws: ``SeqkitStatsParseError`` if the output has no data row or is
    ///   missing the `num_seqs` column.
    public static func parse(_ text: String) throws -> SeqkitStatsRow {
        let rows = try parseAll(text)
        guard let first = rows.first else {
            throw SeqkitStatsParseError.missingDataRow
        }
        return first
    }

    /// Parses every data row of `seqkit stats` output.
    ///
    /// `seqkit stats` emits one row per input file, so multi-file invocations
    /// produce several rows under a single header.
    ///
    /// - Parameter text: Raw stdout from `seqkit stats`.
    /// - Returns: One ``SeqkitStatsRow`` per data row, in output order.
    /// - Throws: ``SeqkitStatsParseError`` if the output cannot be parsed.
    public static func parseAll(_ text: String) throws -> [SeqkitStatsRow] {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard let headerLine = lines.first else {
            throw SeqkitStatsParseError.emptyOutput
        }
        guard lines.count >= 2 else {
            throw SeqkitStatsParseError.missingDataRow
        }

        let headers = splitCells(headerLine)
        guard headers.contains(requiredColumn) else {
            throw SeqkitStatsParseError.missingColumn(requiredColumn)
        }

        var rows: [SeqkitStatsRow] = []
        rows.reserveCapacity(lines.count - 1)

        for (offset, line) in lines.dropFirst().enumerated() {
            let values = splitCells(line)
            guard values.count == headers.count else {
                throw SeqkitStatsParseError.columnCountMismatch(
                    headers: headers.count,
                    values: values.count,
                    row: offset + 1
                )
            }

            var map: [String: String] = [:]
            for (header, value) in zip(headers, values) {
                map[header] = value
            }

            guard let rawNumSeqs = map[requiredColumn] else {
                throw SeqkitStatsParseError.missingColumn(requiredColumn)
            }
            guard let numSeqs = intValue(rawNumSeqs) else {
                throw SeqkitStatsParseError.invalidValue(column: requiredColumn, value: rawNumSeqs)
            }

            rows.append(SeqkitStatsRow(
                file: map["file"] ?? "",
                numSeqs: numSeqs,
                sumLen: map["sum_len"].flatMap(intValue) ?? 0,
                minLen: map["min_len"].flatMap(intValue) ?? 0,
                avgLen: map["avg_len"].flatMap(doubleValue) ?? 0,
                maxLen: map["max_len"].flatMap(intValue) ?? 0,
                q1: map["Q1"].flatMap(doubleValue),
                q2: map["Q2"].flatMap(doubleValue),
                q3: map["Q3"].flatMap(doubleValue),
                sumGap: map["sum_gap"].flatMap(doubleValue),
                n50: map["N50"].flatMap(doubleValue),
                q20Percent: map["Q20(%)"].flatMap(doubleValue),
                q30Percent: map["Q30(%)"].flatMap(doubleValue),
                avgQual: map["AvgQual"].flatMap(doubleValue),
                gcPercent: map["GC(%)"].flatMap(doubleValue)
            ))
        }

        logger.debug("Parsed seqkit stats: \(rows.count, privacy: .public) row(s)")
        return rows
    }

    // MARK: - Cell Helpers

    /// Splits a tab-separated line into trimmed cells.
    ///
    /// Without `-T`, seqkit pads columns with spaces, so cells are trimmed.
    private static func splitCells(_ line: String) -> [String] {
        line.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Parses an integer cell, tolerating the thousands separators seqkit emits
    /// when `-T` is not passed.
    ///
    /// - Returns: The value, or `nil` if the cell is not an integer.
    static func intValue(_ raw: String) -> Int? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty else { return nil }
        if let value = Int(cleaned) { return value }
        // Some seqkit builds report whole-number columns with a trailing ".0".
        if let value = Double(cleaned), value.rounded() == value, value.magnitude < 9e18 {
            return Int(value)
        }
        return nil
    }

    /// Parses a floating-point cell, mapping seqkit's `NA` / `-nan` placeholders
    /// to `nil`.
    ///
    /// - Returns: The value, or `nil` if the cell has no usable number.
    static func doubleValue(_ raw: String) -> Double? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty else { return nil }
        let lowered = cleaned.lowercased()
        if lowered == "na" || lowered == "n/a" || lowered.hasSuffix("nan") { return nil }
        return Double(cleaned)
    }
}
