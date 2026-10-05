// MSADistanceMatrix.swift - Pairwise identity and distance matrices for MSA rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One implementation shared by `lungfish-cli msa distance` and the MSA distance matrix pane,
// so the GUI shows exactly the numbers the CLI writes.

import Foundation

public enum MSADistanceMatrixError: Error, LocalizedError, Equatable, Sendable {
    case unequalAlignedLengths
    case modelNotValidForAlphabet(MSADistanceModel, MSASequenceAlphabet)
    case noComparableSitesAfterCompleteDeletion

    public var errorDescription: String? {
        switch self {
        case .unequalAlignedLengths:
            return "Selected MSA rows do not have equal aligned lengths."
        case .modelNotValidForAlphabet(let model, let alphabet):
            let valid = MSADistanceModel.models(for: alphabet).map(\.rawValue).joined(separator: ", ")
            return "The \(model.rawValue) model is not valid for a \(alphabet.rawValue) alignment. Valid models: \(valid)."
        case .noComparableSitesAfterCompleteDeletion:
            return "Complete deletion left no comparable sites. Every column has a gap or an ambiguous character in at least one selected row. Use pairwise deletion or select fewer rows."
        }
    }
}

/// A full symmetric pairwise matrix over a set of aligned rows.
///
/// Gaps (`-` and `.`) and ambiguous characters are missing data. For nucleotides a site
/// compares only when both characters are A, C, G, T or U (case-insensitive, U equals T).
/// For protein X, B, Z, J, `?`, `*` and any non-letter are skipped, and every other letter
/// compares literally. With `MSAGapPolicy.pairwise` each pair skips its own missing sites.
/// With `MSAGapPolicy.complete` every pair skips each column that has a gap or ambiguity in
/// any selected row, and those columns count as gap skips when any row has a gap there.
/// A site with a gap in one row and ambiguity in the other counts as a gap skip.
///
/// A pair with no comparable site has the value `nan`. A saturated corrected distance has
/// the value `+inf`, written as `inf`.
public struct MSADistanceMatrix: Sendable, Equatable {
    /// One off-diagonal pair, listed once (`rowIndex < columnIndex`, display positions).
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

    public let options: MSADistanceOptions
    /// Row names in display order (after `options.order`).
    public let names: [String]
    /// Display position to index in the input records.
    public let recordIndices: [Int]
    /// Values in display order.
    public let values: [[Double]]
    /// Off-diagonal unordered pairs with no comparable site.
    public let undefinedPairCount: Int
    /// Off-diagonal unordered pairs whose corrected distance saturated.
    public let saturatedPairCount: Int

    // Per-pair counts in input order, upper triangle including the diagonal.
    private let comparableCounts: [Int32]
    private let differenceCounts: [Int32]
    private let transitionCounts: [Int32]
    private let transversionCounts: [Int32]
    private let gapSkippedCounts: [Int32]
    private let ambiguitySkippedCounts: [Int32]

    public var model: MSADistanceModel { options.model }
    public var rowCount: Int { names.count }

    /// Convenience for a nucleotide alignment, pairwise deletion and alignment order.
    public init(records: [MSAAlignedRecord], model: MSADistanceModel) throws {
        try self.init(records: records, options: MSADistanceOptions(model: model))
    }

    /// Computes the matrix for `records`, which must all have the same aligned length.
    public init(records: [MSAAlignedRecord], options: MSADistanceOptions) throws {
        guard options.model.isValid(for: options.alphabet) else {
            throw MSADistanceMatrixError.modelNotValidForAlphabet(options.model, options.alphabet)
        }
        var codes = records.map { Self.siteCodes($0.sequence, alphabet: options.alphabet) }
        let alignedLength = codes.first?.count ?? 0
        if codes.contains(where: { $0.count != alignedLength }) {
            throw MSADistanceMatrixError.unequalAlignedLengths
        }

        // Complete deletion keeps only the columns where every row has a comparable residue.
        var columnGapSkips = 0
        var columnAmbiguitySkips = 0
        if options.gaps == .complete, codes.isEmpty == false {
            var keep = [Bool](repeating: true, count: alignedLength)
            for column in 0..<alignedLength {
                var hasGap = false
                var hasAmbiguity = false
                for row in codes.indices {
                    let code = codes[row][column]
                    if code == Self.gapCode {
                        hasGap = true
                    } else if code == Self.ambiguousCode {
                        hasAmbiguity = true
                    }
                }
                if hasGap {
                    columnGapSkips += 1
                    keep[column] = false
                } else if hasAmbiguity {
                    columnAmbiguitySkips += 1
                    keep[column] = false
                }
            }
            if columnGapSkips + columnAmbiguitySkips == alignedLength {
                throw MSADistanceMatrixError.noComparableSitesAfterCompleteDeletion
            }
            codes = codes.map { row in row.indices.compactMap { keep[$0] ? row[$0] : nil } }
        }

        let count = records.count
        let triangleSize = count * (count + 1) / 2
        var comparable = [Int32](repeating: 0, count: triangleSize)
        var differences = [Int32](repeating: 0, count: triangleSize)
        var transitions = [Int32](repeating: 0, count: triangleSize)
        var transversions = [Int32](repeating: 0, count: triangleSize)
        var gapSkipped = [Int32](repeating: Int32(columnGapSkips), count: triangleSize)
        var ambiguitySkipped = [Int32](repeating: Int32(columnAmbiguitySkips), count: triangleSize)
        var inputValues = [Double](repeating: .nan, count: count * count)
        let isNucleotide = options.alphabet == .nucleotide

        for row in 0..<count {
            for column in row..<count {
                let counts = Self.compare(codes[row], codes[column], nucleotide: isNucleotide)
                let t = Self.triangleIndex(row, column, count: count)
                comparable[t] = Int32(counts.comparable)
                differences[t] = Int32(counts.differences)
                transitions[t] = Int32(counts.transitions)
                transversions[t] = Int32(counts.transversions)
                gapSkipped[t] += Int32(counts.gapSkipped)
                ambiguitySkipped[t] += Int32(counts.ambiguitySkipped)
                let value = Self.value(
                    model: options.model,
                    comparable: counts.comparable,
                    differences: counts.differences,
                    transitions: counts.transitions,
                    transversions: counts.transversions
                )
                inputValues[row * count + column] = value
                inputValues[column * count + row] = value
            }
        }

        let order: [Int]
        switch options.order {
        case .alignment:
            order = Array(0..<count)
        case .averageLinkage:
            // p-distance under the same gap and ambiguity policy, with no comparable site as 1.0.
            order = MSADistanceClustering.averageLinkageOrder(count: count) { i, j in
                let t = Self.triangleIndex(min(i, j), max(i, j), count: count)
                let sites = comparable[t]
                return sites > 0 ? Double(differences[t]) / Double(sites) : 1.0
            }
        }

        var undefined = 0
        var saturated = 0
        for row in 0..<count {
            for column in (row + 1)..<count {
                let value = inputValues[row * count + column]
                if value.isNaN {
                    undefined += 1
                } else if value == .infinity {
                    saturated += 1
                }
            }
        }

        self.options = options
        self.recordIndices = order
        self.names = order.map { records[$0].name }
        self.values = order.map { row in order.map { column in inputValues[row * count + column] } }
        self.undefinedPairCount = undefined
        self.saturatedPairCount = saturated
        self.comparableCounts = comparable
        self.differenceCounts = differences
        self.transitionCounts = transitions
        self.transversionCounts = transversions
        self.gapSkippedCounts = gapSkipped
        self.ambiguitySkippedCounts = ambiguitySkipped
    }

    /// The counts behind the cell at display position (`row`, `column`).
    public func detail(row: Int, column: Int) -> MSAPairDetail {
        let lhs = recordIndices[row]
        let rhs = recordIndices[column]
        let t = Self.triangleIndex(min(lhs, rhs), max(lhs, rhs), count: recordIndices.count)
        let sites = Int(comparableCounts[t])
        let differences = Int(differenceCounts[t])
        return MSAPairDetail(
            value: values[row][column],
            comparableSites: sites,
            differences: differences,
            identicalSites: sites - differences,
            transitions: Int(transitionCounts[t]),
            transversions: Int(transversionCounts[t]),
            gapSkipped: Int(gapSkippedCounts[t]),
            ambiguitySkipped: Int(ambiguitySkippedCounts[t])
        )
    }

    /// Every unordered off-diagonal pair, in display row-major order.
    public var uniquePairs: [Pair] {
        var pairs: [Pair] = []
        pairs.reserveCapacity(max(0, rowCount * (rowCount - 1) / 2))
        for row in 0..<rowCount {
            for column in (row + 1)..<rowCount {
                let detail = detail(row: row, column: column)
                pairs.append(Pair(
                    rowIndex: row,
                    columnIndex: column,
                    rowName: names[row],
                    columnName: names[column],
                    value: detail.value,
                    comparableSites: detail.comparableSites,
                    matchingSites: detail.identicalSites
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

    /// `nan` for no comparable sites, `inf` for a saturated distance, otherwise six decimals.
    public static func formatValue(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value == .infinity { return "inf" }
        if value == -.infinity { return "-inf" }
        return String(format: "%.6f", value)
    }

    public static func isAlignmentGap(_ residue: Character) -> Bool {
        residue == "-" || residue == "."
    }

    // MARK: - Site coding

    static let gapCode: UInt8 = 0
    static let ambiguousCode: UInt8 = 1
    private static let codeA: UInt8 = 2
    private static let codeC: UInt8 = 3
    private static let codeG: UInt8 = 4
    private static let codeT: UInt8 = 5

    /// Codes each aligned character as a gap, an ambiguous character, or a comparable residue.
    static func siteCodes(_ sequence: String, alphabet: MSASequenceAlphabet) -> [UInt8] {
        var codes: [UInt8] = []
        codes.reserveCapacity(sequence.utf8.count)
        for character in sequence {
            guard let ascii = character.asciiValue else {
                codes.append(ambiguousCode)
                continue
            }
            let upper = (ascii >= 97 && ascii <= 122) ? ascii - 32 : ascii
            if upper == UInt8(ascii: "-") || upper == UInt8(ascii: ".") {
                codes.append(gapCode)
                continue
            }
            switch alphabet {
            case .nucleotide:
                switch upper {
                case UInt8(ascii: "A"): codes.append(codeA)
                case UInt8(ascii: "C"): codes.append(codeC)
                case UInt8(ascii: "G"): codes.append(codeG)
                case UInt8(ascii: "T"), UInt8(ascii: "U"): codes.append(codeT)
                default: codes.append(ambiguousCode)
                }
            case .protein:
                let isLetter = upper >= UInt8(ascii: "A") && upper <= UInt8(ascii: "Z")
                let isAmbiguous = upper == UInt8(ascii: "X") || upper == UInt8(ascii: "B")
                    || upper == UInt8(ascii: "Z") || upper == UInt8(ascii: "J")
                codes.append(isLetter && !isAmbiguous ? upper : ambiguousCode)
            }
        }
        return codes
    }

    private struct PairCounts {
        var comparable = 0
        var differences = 0
        var transitions = 0
        var transversions = 0
        var gapSkipped = 0
        var ambiguitySkipped = 0
    }

    private static func compare(_ lhs: [UInt8], _ rhs: [UInt8], nucleotide: Bool) -> PairCounts {
        var counts = PairCounts()
        lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                for index in 0..<left.count {
                    let a = left[index]
                    let b = right[index]
                    if a == gapCode || b == gapCode {
                        counts.gapSkipped += 1
                        continue
                    }
                    if a == ambiguousCode || b == ambiguousCode {
                        counts.ambiguitySkipped += 1
                        continue
                    }
                    counts.comparable += 1
                    guard a != b else { continue }
                    counts.differences += 1
                    if nucleotide {
                        // A (2) and G (4) are even, C (3) and T (5) are odd. Same parity is a transition.
                        if a % 2 == b % 2 {
                            counts.transitions += 1
                        } else {
                            counts.transversions += 1
                        }
                    }
                }
            }
        }
        return counts
    }

    private static func value(
        model: MSADistanceModel,
        comparable: Int,
        differences: Int,
        transitions: Int,
        transversions: Int
    ) -> Double {
        guard comparable > 0 else { return .nan }
        let sites = Double(comparable)
        let distance: Double
        switch model {
        case .identity:
            return Double(comparable - differences) / sites
        case .pDistance:
            return 1 - Double(comparable - differences) / sites
        case .jc69:
            // 1 - (4/3) p = (3L - 4D) / (3L), decided in integers so p = 0.75 saturates exactly.
            let argument = 3 * comparable - 4 * differences
            guard argument > 0 else { return .infinity }
            distance = -0.75 * log(Double(argument) / (3 * sites))
        case .k2p:
            // 1 - 2P - Q = (L - 2S - V) / L and 1 - 2Q = (L - 2V) / L.
            let first = comparable - 2 * transitions - transversions
            let second = comparable - 2 * transversions
            guard first > 0, second > 0 else { return .infinity }
            distance = -0.5 * log(Double(first) / sites) - 0.25 * log(Double(second) / sites)
        case .poisson:
            let argument = comparable - differences
            guard argument > 0 else { return .infinity }
            distance = -log(Double(argument) / sites)
        }
        // Identical sequences give -0.0, which would print as "-0.000000".
        return distance == 0 ? 0 : distance
    }

    private static func triangleIndex(_ row: Int, _ column: Int, count: Int) -> Int {
        row * count - row * (row - 1) / 2 + (column - row)
    }
}
