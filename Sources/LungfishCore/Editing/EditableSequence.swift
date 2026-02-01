// EditableSequence.swift - Mutable sequence wrapper with undo/redo
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Sequence Viewer Specialist (Role 03)

import Foundation

/// A mutable sequence with full undo/redo support.
///
/// EditableSequence wraps a sequence string and tracks all modifications,
/// enabling complete edit history with undo/redo capability.
///
/// ## Example
/// ```swift
/// var editable = EditableSequence(sequence: "ATCGATCG", name: "my_seq")
/// try editable.insert("GGG", at: 4)   // "ATCGGGGATCG"
/// try editable.delete(range: 0..<3)   // "GGGGATCG"
/// editable.undo()                      // "ATCGGGGATCG"
/// editable.undo()                      // "ATCGATCG"
/// editable.redo()                      // "ATCGGGGATCG"
/// ```
@MainActor
public final class EditableSequence: ObservableObject {

    // MARK: - Published Properties

    /// The current sequence string
    @Published public private(set) var sequence: String

    /// Whether there are operations to undo
    @Published public private(set) var canUndo: Bool = false

    /// Whether there are operations to redo
    @Published public private(set) var canRedo: Bool = false

    /// Whether the sequence has unsaved changes
    @Published public private(set) var isDirty: Bool = false

    // MARK: - Properties

    /// Name of the sequence
    public let name: String

    /// The sequence alphabet
    public let alphabet: SequenceAlphabet

    /// The original sequence (before any edits)
    public let originalSequence: String

    /// Current length
    public var length: Int { sequence.count }

    // MARK: - History

    /// Stack of operations that can be undone
    private var undoStack: [EditOperation] = []

    /// Stack of operations that can be redone
    private var redoStack: [EditOperation] = []

    /// Maximum undo history size (0 = unlimited)
    public var maxUndoLevels: Int = 100

    // MARK: - Initialization

    /// Creates an editable sequence from a string.
    ///
    /// - Parameters:
    ///   - sequence: The initial sequence string
    ///   - name: Name for the sequence
    ///   - alphabet: The sequence alphabet (default: DNA)
    public init(sequence: String, name: String, alphabet: SequenceAlphabet = .dna) {
        self.sequence = sequence
        self.originalSequence = sequence
        self.name = name
        self.alphabet = alphabet
    }

    /// Creates an editable sequence from a Sequence object.
    ///
    /// - Parameter source: The source sequence
    public init(from source: Sequence) {
        let sequenceString = source.asString()
        self.sequence = sequenceString
        self.originalSequence = sequenceString
        self.name = source.name
        self.alphabet = source.alphabet
    }

    // MARK: - Edit Operations

    /// Inserts bases at the specified position.
    ///
    /// - Parameters:
    ///   - bases: The bases to insert
    ///   - position: The position to insert at (0-based)
    /// - Throws: `EditError` if the operation fails
    public func insert(_ bases: String, at position: Int) throws {
        guard !bases.isEmpty else {
            throw EditError.invalidOperation(reason: "Cannot insert empty string")
        }

        // Validate bases for alphabet
        try validateBases(bases)

        let operation = EditOperation.insert(position: position, bases: bases)
        try applyOperation(operation)
    }

    /// Deletes bases in the specified range.
    ///
    /// - Parameter range: The range to delete
    /// - Throws: `EditError` if the operation fails
    public func delete(range: Range<Int>) throws {
        guard !range.isEmpty else {
            throw EditError.invalidOperation(reason: "Cannot delete empty range")
        }

        guard range.lowerBound >= 0 && range.upperBound <= sequence.count else {
            throw EditError.rangeOutOfBounds(start: range.lowerBound, end: range.upperBound, length: sequence.count)
        }

        let startIndex = sequence.index(sequence.startIndex, offsetBy: range.lowerBound)
        let endIndex = sequence.index(sequence.startIndex, offsetBy: range.upperBound)
        let deletedBases = String(sequence[startIndex..<endIndex])

        let operation = EditOperation.delete(position: range.lowerBound, bases: deletedBases)
        try applyOperation(operation)
    }

    /// Replaces bases in the specified range with new bases.
    ///
    /// - Parameters:
    ///   - range: The range to replace
    ///   - bases: The replacement bases
    /// - Throws: `EditError` if the operation fails
    public func replace(range: Range<Int>, with bases: String) throws {
        guard range.lowerBound >= 0 && range.upperBound <= sequence.count else {
            throw EditError.rangeOutOfBounds(start: range.lowerBound, end: range.upperBound, length: sequence.count)
        }

        // Validate replacement bases
        if !bases.isEmpty {
            try validateBases(bases)
        }

        let startIndex = sequence.index(sequence.startIndex, offsetBy: range.lowerBound)
        let endIndex = sequence.index(sequence.startIndex, offsetBy: range.upperBound)
        let originalBases = String(sequence[startIndex..<endIndex])

        let operation = EditOperation.replace(position: range.lowerBound, original: originalBases, replacement: bases)
        try applyOperation(operation)
    }

    /// Replaces a single base at the specified position.
    ///
    /// - Parameters:
    ///   - position: The position of the base to replace
    ///   - base: The replacement base
    /// - Throws: `EditError` if the operation fails
    public func replaceBase(at position: Int, with base: Character) throws {
        try replace(range: position..<(position + 1), with: String(base))
    }

    // MARK: - Undo/Redo

    /// Undoes the most recent operation.
    ///
    /// - Returns: `true` if an operation was undone
    @discardableResult
    public func undo() -> Bool {
        guard let operation = undoStack.popLast() else {
            return false
        }

        let inverse = operation.inverse()
        do {
            try inverse.apply(to: &sequence)
            redoStack.append(operation)
            updateState()
            return true
        } catch {
            // Restore the operation to the undo stack on failure
            undoStack.append(operation)
            return false
        }
    }

    /// Redoes the most recently undone operation.
    ///
    /// - Returns: `true` if an operation was redone
    @discardableResult
    public func redo() -> Bool {
        guard let operation = redoStack.popLast() else {
            return false
        }

        do {
            try operation.apply(to: &sequence)
            undoStack.append(operation)
            updateState()
            return true
        } catch {
            // Restore the operation to the redo stack on failure
            redoStack.append(operation)
            return false
        }
    }

    /// Clears all undo/redo history.
    public func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateState()
    }

    // MARK: - State Management

    /// Marks the current state as saved (clears dirty flag).
    public func markSaved() {
        isDirty = false
    }

    /// Reverts all changes to the original sequence.
    public func revertToOriginal() {
        sequence = originalSequence
        clearHistory()
        isDirty = false
    }

    /// Returns the operation history for persistence.
    public func getOperationHistory() -> [EditOperation] {
        return undoStack
    }

    /// Replays a sequence of operations (for loading saved edits).
    ///
    /// - Parameter operations: The operations to replay
    /// - Throws: `EditError` if any operation fails
    public func replayOperations(_ operations: [EditOperation]) throws {
        for operation in operations {
            try applyOperation(operation)
        }
    }

    // MARK: - Conversion

    /// Creates a new Sequence object from the current state.
    ///
    /// - Returns: A new Sequence with the current content
    /// - Throws: `SequenceError` if the sequence is invalid
    public func toSequence() throws -> Sequence {
        try Sequence(name: name, alphabet: alphabet, bases: sequence)
    }

    // MARK: - Private Methods

    private func applyOperation(_ operation: EditOperation) throws {
        try operation.apply(to: &sequence)

        // Add to undo stack
        undoStack.append(operation)

        // Trim undo stack if needed
        if maxUndoLevels > 0 && undoStack.count > maxUndoLevels {
            undoStack.removeFirst(undoStack.count - maxUndoLevels)
        }

        // Clear redo stack (new edit invalidates redo history)
        redoStack.removeAll()

        updateState()
    }

    private func updateState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        isDirty = sequence != originalSequence
    }

    private func validateBases(_ bases: String) throws {
        for (index, char) in bases.enumerated() {
            if !alphabet.validCharacters.contains(char) && !alphabet.validCharacters.contains(Character(char.uppercased())) {
                throw EditError.invalidOperation(reason: "Invalid character '\(char)' at position \(index) for \(alphabet) alphabet")
            }
        }
    }
}

// MARK: - Batch Operations

extension EditableSequence {

    /// Performs multiple operations as a single undoable batch.
    ///
    /// All operations succeed or fail together. If any operation fails,
    /// all previous operations in the batch are rolled back.
    ///
    /// - Parameter operations: The operations to perform
    /// - Throws: `EditError` if any operation fails
    public func performBatch(_ operations: [EditOperation]) throws {
        let checkpoint = sequence
        let undoCheckpoint = undoStack

        do {
            for operation in operations {
                try operation.apply(to: &sequence)
                undoStack.append(operation)
            }
            redoStack.removeAll()
            updateState()
        } catch {
            // Rollback on failure
            sequence = checkpoint
            undoStack = undoCheckpoint
            throw error
        }
    }

    /// Performs operations within a closure as a batch.
    ///
    /// - Parameter block: The closure containing edit operations
    /// - Throws: Rethrows any error from the closure
    public func batch(_ block: (EditableSequence) throws -> Void) throws {
        let checkpoint = sequence
        let undoCheckpoint = undoStack

        do {
            try block(self)
        } catch {
            sequence = checkpoint
            undoStack = undoCheckpoint
            throw error
        }
    }
}
