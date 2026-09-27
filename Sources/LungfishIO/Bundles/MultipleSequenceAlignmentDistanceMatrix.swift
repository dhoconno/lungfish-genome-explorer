// MultipleSequenceAlignmentDistanceMatrix.swift - Pairwise identity / p-distance for MSA rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One implementation shared by `lungfish-cli msa distance` and the MSA Inspector's
// "Pairwise Identity" table, so the GUI shows exactly the numbers the CLI writes.

import Foundation

/// Distance model for `MSADistanceMatrix`. Raw values are the CLI `--model` spellings.
public enum MSADistanceModel: String, CaseIterable, Sendable, Codable, Identifiable {
    case identity = "identity"
    case pDistance = "p-distance"

    public var id: String { rawValue }

    /// Short label for pickers and column headers.
    public var displayName: String {
        switch self {
        case .identity: return "Identity"
        case .pDistance: return "p-distance"
        }
    }
}

/// One aligned FASTA record: the header text after `>` and the gapped sequence.
public struct MSAAlignedRecord: Sendable, Equatable {
    public let name: String
    public let sequence: String

    public init(name: String, sequence: String) {
        self.name = name
        self.sequence = sequence
    }

    /// Parses aligned FASTA text. Whitespace inside sequence lines is dropped; a record with
    /// an empty header keeps the empty name. Returns an empty array for text without records.
    public static func parseAlignedFASTA(_ text: String) -> [MSAAlignedRecord] {
        var records: [MSAAlignedRecord] = []
        var currentName: String?
        var currentSequence = ""

        func flush() {
            guard let currentName else { return }
            records.append(MSAAlignedRecord(name: currentName, sequence: currentSequence))
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false else { continue }
            if line.hasPrefix(">") {
                flush()
                currentName = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                currentSequence = ""
            } else {
                currentSequence += line.filter { !$0.isWhitespace }
            }
        }
        flush()
        return records
    }

    /// Loads the primary aligned FASTA of a `.lungfishmsa` bundle.
    public static func loadPrimaryAlignment(of bundleURL: URL) throws -> [MSAAlignedRecord] {
        let fastaURL = bundleURL.appendingPathComponent("alignment/primary.aligned.fasta")
        let text = try String(contentsOf: fastaURL, encoding: .utf8)
        return parseAlignedFASTA(text)
    }
}

public enum MSADistanceMatrixError: Error, LocalizedError, Equatable, Sendable {
    case unequalAlignedLengths

    public var errorDescription: String? {
        switch self {
        case .unequalAlignedLengths:
            return "Selected MSA rows do not have equal aligned lengths."
        }
    }
}

/// A full symmetric pairwise matrix over a set of aligned rows.
///
/// Sites where either row has a gap (`-` or `.`) are skipped (pairwise deletion). Identity is
/// matches over comparable sites, compared case-insensitively; p-distance is `1 - identity`.
/// A pair with no comparable site has the value `Double.nan`, written as `nan`.
public struct MSADistanceMatrix: Sendable, Equatable {
    /// One off-diagonal pair, listed once (`rowIndex < columnIndex`).
    public struct Pair: Sendable, Equatable, Identifiable {
        public let rowIndex: Int
        public let columnIndex: Int
        public let rowName: String
        public let columnName: String
        public let value: Double
        public let comparableSites: Int
        public let matchingSites: Int

        public var id: String { "\(rowIndex):\(columnIndex)" }

        /// `value` with NaN sorted below every number, for table sorting.
        public var sortableValue: Double { value.isNaN ? -Double.infinity : value }

        public var formattedValue: String { MSADistanceMatrix.formatValue(value) }
    }

    public let model: MSADistanceModel
    public let names: [String]
    public let values: [[Double]]
    public let comparableSites: [[Int]]
    public let matchingSites: [[Int]]

    public var rowCount: Int { names.count }

    /// Computes the matrix for `records`, which must all have the same aligned length.
    public init(records: [MSAAlignedRecord], model: MSADistanceModel) throws {
        let characters = records.map { Array($0.sequence.uppercased()) }
        if let expected = characters.first?.count, characters.contains(where: { $0.count != expected }) {
            throw MSADistanceMatrixError.unequalAlignedLengths
        }

        let count = records.count
        var values = Array(repeating: Array(repeating: Double.nan, count: count), count: count)
        var comparable = Array(repeating: Array(repeating: 0, count: count), count: count)
        var matches = Array(repeating: Array(repeating: 0, count: count), count: count)

        for row in 0..<count {
            for column in row..<count {
                let (sites, matched) = Self.compare(characters[row], characters[column])
                let value = Self.value(matches: matched, comparable: sites, model: model)
                values[row][column] = value
                values[column][row] = value
                comparable[row][column] = sites
                comparable[column][row] = sites
                matches[row][column] = matched
                matches[column][row] = matched
            }
        }

        self.model = model
        self.names = records.map(\.name)
        self.values = values
        self.comparableSites = comparable
        self.matchingSites = matches
    }

    /// Every unordered off-diagonal pair, in row-major order.
    public var uniquePairs: [Pair] {
        var pairs: [Pair] = []
        pairs.reserveCapacity(max(0, rowCount * (rowCount - 1) / 2))
        for row in 0..<rowCount {
            for column in (row + 1)..<rowCount {
                pairs.append(Pair(
                    rowIndex: row,
                    columnIndex: column,
                    rowName: names[row],
                    columnName: names[column],
                    value: values[row][column],
                    comparableSites: comparableSites[row][column],
                    matchingSites: matchingSites[row][column]
                ))
            }
        }
        return pairs
    }

    /// The square matrix as TSV, in the exact layout `lungfish msa distance` writes:
    /// a `row` header column followed by one column per row, values to six decimals.
    public var tsv: String {
        let header = "row\t" + names.joined(separator: "\t")
        let rows = names.indices.map { row in
            ([names[row]] + values[row].map(Self.formatValue)).joined(separator: "\t")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    public static func formatValue(_ value: Double) -> String {
        value.isNaN ? "nan" : String(format: "%.6f", value)
    }

    public static func isAlignmentGap(_ residue: Character) -> Bool {
        residue == "-" || residue == "."
    }

    private static func compare(_ lhs: [Character], _ rhs: [Character]) -> (comparable: Int, matches: Int) {
        var comparable = 0
        var matches = 0
        for index in lhs.indices {
            let left = lhs[index]
            let right = rhs[index]
            if isAlignmentGap(left) || isAlignmentGap(right) {
                continue
            }
            comparable += 1
            if left == right {
                matches += 1
            }
        }
        return (comparable, matches)
    }

    private static func value(matches: Int, comparable: Int, model: MSADistanceModel) -> Double {
        guard comparable > 0 else { return Double.nan }
        let identity = Double(matches) / Double(comparable)
        switch model {
        case .identity: return identity
        case .pDistance: return 1 - identity
        }
    }
}
