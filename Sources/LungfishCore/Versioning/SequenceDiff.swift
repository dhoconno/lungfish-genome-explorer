// SequenceDiff.swift - VCF-like delta representation for sequence changes
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Version Control Specialist (Role 17)

import Foundation

/// A difference between two sequence states, represented as a series of operations.
///
/// SequenceDiff uses a VCF-like delta representation where changes are stored
/// as position-based operations. This is more space-efficient than storing
/// full sequence copies for small changes.
///
/// ## Example
/// ```swift
/// let diff = SequenceDiff.compute(from: "ATCGATCG", to: "ATCGGGGATCG")
/// let restored = try diff.apply(to: "ATCGATCG")
/// // restored == "ATCGGGGATCG"
/// ```
public struct SequenceDiff: Codable, Sendable, Equatable {

    /// The operations that make up this diff
    public let operations: [DiffOperation]

    /// Creates a diff from a list of operations.
    public init(operations: [DiffOperation]) {
        self.operations = operations
    }

    /// Creates an empty diff (no changes).
    public static var empty: SequenceDiff {
        SequenceDiff(operations: [])
    }

    /// Whether this diff represents no changes.
    public var isEmpty: Bool {
        operations.isEmpty
    }

    /// Number of operations in this diff.
    public var operationCount: Int {
        operations.count
    }

    /// The net length change caused by this diff.
    public var lengthDelta: Int {
        operations.reduce(0) { $0 + $1.lengthDelta }
    }

    // MARK: - Diff Computation

    /// Computes the diff between two sequences.
    ///
    /// Uses a simple algorithm suitable for sequences with localized changes.
    /// For sequences with many distributed changes, consider using a more
    /// sophisticated algorithm like Myers diff.
    ///
    /// - Parameters:
    ///   - original: The original sequence
    ///   - modified: The modified sequence
    /// - Returns: A diff that transforms original into modified
    public static func compute(from original: String, to modified: String) -> SequenceDiff {
        if original == modified {
            return .empty
        }

        var operations: [DiffOperation] = []

        // Find common prefix
        let prefixLength = commonPrefixLength(original, modified)

        // Find common suffix (after removing common prefix)
        let origSuffix = String(original.dropFirst(prefixLength))
        let modSuffix = String(modified.dropFirst(prefixLength))
        let suffixLength = commonSuffixLength(origSuffix, modSuffix)

        // Extract the changed middle portions
        let origMiddle = String(origSuffix.dropLast(suffixLength))
        let modMiddle = String(modSuffix.dropLast(suffixLength))

        // Create the appropriate operation
        if origMiddle.isEmpty && !modMiddle.isEmpty {
            // Pure insertion
            operations.append(.insert(position: prefixLength, bases: modMiddle))
        } else if !origMiddle.isEmpty && modMiddle.isEmpty {
            // Pure deletion
            operations.append(.delete(position: prefixLength, length: origMiddle.count, original: origMiddle))
        } else if !origMiddle.isEmpty && !modMiddle.isEmpty {
            // Replacement
            operations.append(.replace(position: prefixLength, original: origMiddle, replacement: modMiddle))
        }

        return SequenceDiff(operations: operations)
    }

    /// Computes a more detailed diff with multiple operations.
    ///
    /// This method identifies individual changes rather than grouping them
    /// into a single operation. Useful for displaying change history.
    ///
    /// - Parameters:
    ///   - original: The original sequence
    ///   - modified: The modified sequence
    /// - Returns: A diff with individual operations
    public static func computeDetailed(from original: String, to modified: String) -> SequenceDiff {
        // For now, delegate to the simple algorithm
        // A more sophisticated implementation could use Myers diff or similar
        return compute(from: original, to: modified)
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        let aChars = Array(a)
        let bChars = Array(b)
        let minLen = min(aChars.count, bChars.count)

        for i in 0..<minLen {
            if aChars[i] == bChars[i] {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    private static func commonSuffixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        let aChars = Array(a.reversed())
        let bChars = Array(b.reversed())
        let minLen = min(aChars.count, bChars.count)

        for i in 0..<minLen {
            if aChars[i] == bChars[i] {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    // MARK: - Application

    /// Applies this diff to a sequence.
    ///
    /// - Parameter sequence: The original sequence
    /// - Returns: The modified sequence
    /// - Throws: `DiffError` if the diff cannot be applied
    public func apply(to sequence: String) throws -> String {
        var result = sequence

        // Apply operations in reverse order to maintain position validity
        for operation in operations.reversed() {
            try operation.apply(to: &result)
        }

        return result
    }

    /// Returns the inverse diff that undoes this diff.
    public func inverse() -> SequenceDiff {
        SequenceDiff(operations: operations.reversed().map { $0.inverse() })
    }
}

// MARK: - DiffOperation

/// A single operation within a SequenceDiff.
public enum DiffOperation: Codable, Sendable, Equatable {

    /// Insert bases at a position
    case insert(position: Int, bases: String)

    /// Delete bases at a position
    case delete(position: Int, length: Int, original: String)

    /// Replace bases at a position
    case replace(position: Int, original: String, replacement: String)

    /// The position where this operation starts
    public var position: Int {
        switch self {
        case .insert(let pos, _): return pos
        case .delete(let pos, _, _): return pos
        case .replace(let pos, _, _): return pos
        }
    }

    /// The net length change caused by this operation
    public var lengthDelta: Int {
        switch self {
        case .insert(_, let bases): return bases.count
        case .delete(_, let length, _): return -length
        case .replace(_, let original, let replacement):
            return replacement.count - original.count
        }
    }

    /// Applies this operation to a mutable string.
    func apply(to sequence: inout String) throws {
        switch self {
        case .insert(let position, let bases):
            guard position >= 0 && position <= sequence.count else {
                throw DiffError.positionOutOfBounds(position: position, length: sequence.count)
            }
            let index = sequence.index(sequence.startIndex, offsetBy: position)
            sequence.insert(contentsOf: bases, at: index)

        case .delete(let position, let length, let original):
            guard position >= 0 && (position + length) <= sequence.count else {
                throw DiffError.rangeOutOfBounds(start: position, end: position + length, length: sequence.count)
            }
            let startIndex = sequence.index(sequence.startIndex, offsetBy: position)
            let endIndex = sequence.index(startIndex, offsetBy: length)
            let actual = String(sequence[startIndex..<endIndex])
            guard actual == original else {
                throw DiffError.contentMismatch(expected: original, actual: actual)
            }
            sequence.removeSubrange(startIndex..<endIndex)

        case .replace(let position, let original, let replacement):
            guard position >= 0 && (position + original.count) <= sequence.count else {
                throw DiffError.rangeOutOfBounds(start: position, end: position + original.count, length: sequence.count)
            }
            let startIndex = sequence.index(sequence.startIndex, offsetBy: position)
            let endIndex = sequence.index(startIndex, offsetBy: original.count)
            let actual = String(sequence[startIndex..<endIndex])
            guard actual == original else {
                throw DiffError.contentMismatch(expected: original, actual: actual)
            }
            sequence.replaceSubrange(startIndex..<endIndex, with: replacement)
        }
    }

    /// Returns the inverse operation.
    func inverse() -> DiffOperation {
        switch self {
        case .insert(let position, let bases):
            return .delete(position: position, length: bases.count, original: bases)
        case .delete(let position, _, let original):
            return .insert(position: position, bases: original)
        case .replace(let position, let original, let replacement):
            return .replace(position: position, original: replacement, replacement: original)
        }
    }
}

// MARK: - DiffError

/// Errors that can occur when applying diffs.
public enum DiffError: Error, LocalizedError, Sendable {

    case positionOutOfBounds(position: Int, length: Int)
    case rangeOutOfBounds(start: Int, end: Int, length: Int)
    case contentMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .positionOutOfBounds(let position, let length):
            return "Position \(position) is out of bounds for sequence of length \(length)"
        case .rangeOutOfBounds(let start, let end, let length):
            return "Range \(start)..<\(end) is out of bounds for sequence of length \(length)"
        case .contentMismatch(let expected, let actual):
            let expPreview = expected.count > 20 ? "\(expected.prefix(20))..." : expected
            let actPreview = actual.count > 20 ? "\(actual.prefix(20))..." : actual
            return "Content mismatch: expected '\(expPreview)', found '\(actPreview)'"
        }
    }
}

// MARK: - VCF-style Export

extension SequenceDiff {

    /// Exports the diff in VCF-like format.
    ///
    /// Format:
    /// ```
    /// #POS    REF    ALT    TYPE
    /// 100     A      G      snp
    /// 200     ACTG   A      del
    /// 300     C      CGTA   ins
    /// ```
    public func toVCFString(sequenceName: String = "seq") -> String {
        var lines: [String] = []
        lines.append("#CHROM\tPOS\tREF\tALT\tTYPE")

        for op in operations {
            let line: String
            switch op {
            case .insert(let position, let bases):
                // VCF requires anchor base for insertions
                line = "\(sequenceName)\t\(position + 1)\t.\t\(bases)\tins"
            case .delete(let position, _, let original):
                line = "\(sequenceName)\t\(position + 1)\t\(original)\t.\tdel"
            case .replace(let position, let original, let replacement):
                let type = original.count == 1 && replacement.count == 1 ? "snp" : "complex"
                line = "\(sequenceName)\t\(position + 1)\t\(original)\t\(replacement)\t\(type)"
            }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }
}
