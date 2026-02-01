// EditOperation.swift - Sequence edit operations with undo support
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Sequence Viewer Specialist (Role 03)

import Foundation

/// A reversible operation on a sequence.
///
/// Edit operations follow the Command pattern, enabling undo/redo functionality.
/// Each operation knows how to apply itself and create its inverse.
///
/// ## Example
/// ```swift
/// let insert = EditOperation.insert(position: 100, bases: "ATCG")
/// try insert.apply(to: &sequence)
/// let undo = insert.inverse()
/// try undo.apply(to: &sequence)  // Sequence restored
/// ```
public enum EditOperation: Codable, Sendable, Equatable {

    /// Insert bases at a position
    case insert(position: Int, bases: String)

    /// Delete bases from a range
    case delete(position: Int, bases: String)

    /// Replace bases in a range with new bases
    case replace(position: Int, original: String, replacement: String)

    // MARK: - Properties

    /// The position where this operation starts
    public var position: Int {
        switch self {
        case .insert(let pos, _): return pos
        case .delete(let pos, _): return pos
        case .replace(let pos, _, _): return pos
        }
    }

    /// The length of the affected region before the operation
    public var originalLength: Int {
        switch self {
        case .insert: return 0
        case .delete(_, let bases): return bases.count
        case .replace(_, let original, _): return original.count
        }
    }

    /// The length change caused by this operation
    public var lengthDelta: Int {
        switch self {
        case .insert(_, let bases): return bases.count
        case .delete(_, let bases): return -bases.count
        case .replace(_, let original, let replacement):
            return replacement.count - original.count
        }
    }

    // MARK: - Apply

    /// Applies this operation to a mutable string.
    ///
    /// - Parameter sequence: The sequence string to modify
    /// - Throws: `EditError` if the operation cannot be applied
    public func apply(to sequence: inout String) throws {
        switch self {
        case .insert(let position, let bases):
            try applyInsert(to: &sequence, position: position, bases: bases)

        case .delete(let position, let bases):
            try applyDelete(to: &sequence, position: position, expectedBases: bases)

        case .replace(let position, let original, let replacement):
            try applyReplace(to: &sequence, position: position, original: original, replacement: replacement)
        }
    }

    private func applyInsert(to sequence: inout String, position: Int, bases: String) throws {
        guard position >= 0 && position <= sequence.count else {
            throw EditError.positionOutOfBounds(position: position, length: sequence.count)
        }

        let index = sequence.index(sequence.startIndex, offsetBy: position)
        sequence.insert(contentsOf: bases, at: index)
    }

    private func applyDelete(to sequence: inout String, position: Int, expectedBases: String) throws {
        let end = position + expectedBases.count
        guard position >= 0 && end <= sequence.count else {
            throw EditError.rangeOutOfBounds(start: position, end: end, length: sequence.count)
        }

        let startIndex = sequence.index(sequence.startIndex, offsetBy: position)
        let endIndex = sequence.index(startIndex, offsetBy: expectedBases.count)
        let actualBases = String(sequence[startIndex..<endIndex])

        guard actualBases == expectedBases else {
            throw EditError.contentMismatch(expected: expectedBases, actual: actualBases)
        }

        sequence.removeSubrange(startIndex..<endIndex)
    }

    private func applyReplace(to sequence: inout String, position: Int, original: String, replacement: String) throws {
        let end = position + original.count
        guard position >= 0 && end <= sequence.count else {
            throw EditError.rangeOutOfBounds(start: position, end: end, length: sequence.count)
        }

        let startIndex = sequence.index(sequence.startIndex, offsetBy: position)
        let endIndex = sequence.index(startIndex, offsetBy: original.count)
        let actualBases = String(sequence[startIndex..<endIndex])

        guard actualBases == original else {
            throw EditError.contentMismatch(expected: original, actual: actualBases)
        }

        sequence.replaceSubrange(startIndex..<endIndex, with: replacement)
    }

    // MARK: - Inverse

    /// Returns the inverse operation that undoes this edit.
    ///
    /// - Returns: An operation that reverses the effect of this operation
    public func inverse() -> EditOperation {
        switch self {
        case .insert(let position, let bases):
            return .delete(position: position, bases: bases)

        case .delete(let position, let bases):
            return .insert(position: position, bases: bases)

        case .replace(let position, let original, let replacement):
            return .replace(position: position, original: replacement, replacement: original)
        }
    }

    // MARK: - Validation

    /// Validates that this operation can be applied to a sequence of the given length.
    ///
    /// - Parameter sequenceLength: The length of the target sequence
    /// - Returns: `true` if the operation is valid
    public func isValid(for sequenceLength: Int) -> Bool {
        switch self {
        case .insert(let position, _):
            return position >= 0 && position <= sequenceLength

        case .delete(let position, let bases):
            return position >= 0 && (position + bases.count) <= sequenceLength

        case .replace(let position, let original, _):
            return position >= 0 && (position + original.count) <= sequenceLength
        }
    }
}

// MARK: - EditError

/// Errors that can occur during sequence editing
public enum EditError: Error, LocalizedError, Sendable {

    /// Position is outside the sequence bounds
    case positionOutOfBounds(position: Int, length: Int)

    /// Range extends beyond sequence bounds
    case rangeOutOfBounds(start: Int, end: Int, length: Int)

    /// The content at the position doesn't match expected
    case contentMismatch(expected: String, actual: String)

    /// Invalid operation (e.g., empty insert)
    case invalidOperation(reason: String)

    /// Cannot undo - no operations in history
    case nothingToUndo

    /// Cannot redo - no operations in redo stack
    case nothingToRedo

    public var errorDescription: String? {
        switch self {
        case .positionOutOfBounds(let position, let length):
            return "Position \(position) is out of bounds for sequence of length \(length)"
        case .rangeOutOfBounds(let start, let end, let length):
            return "Range \(start)..<\(end) is out of bounds for sequence of length \(length)"
        case .contentMismatch(let expected, let actual):
            return "Content mismatch: expected '\(expected)', found '\(actual)'"
        case .invalidOperation(let reason):
            return "Invalid operation: \(reason)"
        case .nothingToUndo:
            return "Nothing to undo"
        case .nothingToRedo:
            return "Nothing to redo"
        }
    }
}

// MARK: - EditOperation Description

extension EditOperation: CustomStringConvertible {
    public var description: String {
        switch self {
        case .insert(let position, let bases):
            let preview = bases.count > 10 ? "\(bases.prefix(10))..." : bases
            return "Insert '\(preview)' at \(position)"
        case .delete(let position, let bases):
            let preview = bases.count > 10 ? "\(bases.prefix(10))..." : bases
            return "Delete '\(preview)' at \(position)"
        case .replace(let position, let original, let replacement):
            let origPreview = original.count > 5 ? "\(original.prefix(5))..." : original
            let replPreview = replacement.count > 5 ? "\(replacement.prefix(5))..." : replacement
            return "Replace '\(origPreview)' with '\(replPreview)' at \(position)"
        }
    }
}
