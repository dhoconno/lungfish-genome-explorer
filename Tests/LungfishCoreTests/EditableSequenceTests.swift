// EditableSequenceTests.swift - Comprehensive tests for EditableSequence
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

@MainActor
final class EditableSequenceTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInitWithString() {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        XCTAssertEqual(editable.sequence, "ATCGATCG")
        XCTAssertEqual(editable.name, "test")
        XCTAssertEqual(editable.alphabet, .dna)  // Default
        XCTAssertEqual(editable.originalSequence, "ATCGATCG")
        XCTAssertFalse(editable.isDirty)
        XCTAssertFalse(editable.canUndo)
        XCTAssertFalse(editable.canRedo)
    }

    func testInitWithCustomAlphabet() {
        let editable = EditableSequence(sequence: "AUCGAUCG", name: "rna_test", alphabet: .rna)

        XCTAssertEqual(editable.alphabet, .rna)
    }

    func testInitFromSequence() throws {
        let seq = try Sequence(name: "source", alphabet: .dna, bases: "ATCGATCG")
        let editable = EditableSequence(from: seq)

        XCTAssertEqual(editable.name, "source")
        XCTAssertEqual(editable.alphabet, .dna)
        XCTAssertEqual(editable.sequence, "ATCGATCG")
    }

    func testLength() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")
        XCTAssertEqual(editable.length, 8)

        try editable.insert("GGG", at: 4)
        XCTAssertEqual(editable.length, 11)
    }

    // MARK: - Basic Operations

    func testInsert() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("GGG", at: 4)

        XCTAssertEqual(editable.sequence, "ATCGGGGATCG")
        XCTAssertTrue(editable.canUndo)
        XCTAssertFalse(editable.canRedo)
        XCTAssertTrue(editable.isDirty)
    }

    func testInsertAtStart() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("GGG", at: 0)

        XCTAssertEqual(editable.sequence, "GGGATCGATCG")
    }

    func testInsertAtEnd() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("GGG", at: 8)

        XCTAssertEqual(editable.sequence, "ATCGATCGGGG")
    }

    func testDelete() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.delete(range: 2..<5)

        XCTAssertEqual(editable.sequence, "ATTCG")
        XCTAssertTrue(editable.canUndo)
    }

    func testDeleteAtStart() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.delete(range: 0..<3)

        XCTAssertEqual(editable.sequence, "GATCG")
    }

    func testDeleteAtEnd() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.delete(range: 5..<8)

        XCTAssertEqual(editable.sequence, "ATCGA")
    }

    func testDeleteAll() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.delete(range: 0..<8)

        XCTAssertEqual(editable.sequence, "")
        XCTAssertEqual(editable.length, 0)
    }

    func testReplace() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.replace(range: 0..<3, with: "NNN")

        XCTAssertEqual(editable.sequence, "NNNGATCG")
    }

    func testReplaceWithDifferentLength() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.replace(range: 2..<4, with: "NNNNN")

        XCTAssertEqual(editable.sequence, "ATNNNNNATCG")
        XCTAssertEqual(editable.length, 11)
    }

    func testReplaceWithShorter() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.replace(range: 0..<4, with: "N")

        XCTAssertEqual(editable.sequence, "NATCG")
    }

    func testReplaceWithEmpty() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.replace(range: 2..<5, with: "")

        XCTAssertEqual(editable.sequence, "ATTCG")
    }

    func testReplaceBase() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.replaceBase(at: 0, with: "G")

        XCTAssertEqual(editable.sequence, "GTCGATCG")
    }

    // MARK: - Undo/Redo

    func testUndo() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("GGG", at: 4)
        XCTAssertEqual(editable.sequence, "ATCGGGGATCG")

        let undone = editable.undo()
        XCTAssertTrue(undone)
        XCTAssertEqual(editable.sequence, "ATCGATCG")
        XCTAssertFalse(editable.canUndo)
        XCTAssertTrue(editable.canRedo)
    }

    func testUndoWithNothingToUndo() {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        let undone = editable.undo()

        XCTAssertFalse(undone)
        XCTAssertEqual(editable.sequence, "ATCGATCG")
    }

    func testRedo() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("GGG", at: 4)
        editable.undo()
        XCTAssertEqual(editable.sequence, "ATCGATCG")

        let redone = editable.redo()
        XCTAssertTrue(redone)
        XCTAssertEqual(editable.sequence, "ATCGGGGATCG")
        XCTAssertTrue(editable.canUndo)
        XCTAssertFalse(editable.canRedo)
    }

    func testRedoWithNothingToRedo() {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        let redone = editable.redo()

        XCTAssertFalse(redone)
    }

    func testMultipleUndoRedo() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("A", at: 0)  // AATCGATCG
        try editable.insert("B", at: 0)  // BAATCGATCG
        try editable.insert("C", at: 0)  // CBAATCGATCG

        XCTAssertEqual(editable.sequence, "CBAATCGATCG")

        editable.undo()  // BAATCGATCG
        XCTAssertEqual(editable.sequence, "BAATCGATCG")

        editable.undo()  // AATCGATCG
        XCTAssertEqual(editable.sequence, "AATCGATCG")

        editable.redo()  // BAATCGATCG
        XCTAssertEqual(editable.sequence, "BAATCGATCG")
    }

    func testUndoDelete() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.delete(range: 2..<5)
        XCTAssertEqual(editable.sequence, "ATTCG")

        editable.undo()
        XCTAssertEqual(editable.sequence, "ATCGATCG")
    }

    func testUndoReplace() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.replace(range: 0..<4, with: "NNNN")
        XCTAssertEqual(editable.sequence, "NNNNATCG")

        editable.undo()
        XCTAssertEqual(editable.sequence, "ATCGATCG")
    }

    func testNewEditClearsRedoStack() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("A", at: 0)
        editable.undo()
        XCTAssertTrue(editable.canRedo)

        try editable.insert("B", at: 0)
        XCTAssertFalse(editable.canRedo)
    }

    func testComplexUndoRedoSequence() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        // Edit 1: Insert
        try editable.insert("NNN", at: 4)  // ATCGNNNATCG

        // Edit 2: Delete
        try editable.delete(range: 0..<3)  // GNNNATCG

        // Edit 3: Replace
        try editable.replace(range: 4..<7, with: "GGG")  // GNNNGGG G

        XCTAssertEqual(editable.sequence, "GNNNGGG G".replacingOccurrences(of: " ", with: ""))

        // Undo all three
        editable.undo()  // GNNNATCG
        XCTAssertEqual(editable.sequence, "GNNNATCG")

        editable.undo()  // ATCGNNNATCG
        XCTAssertEqual(editable.sequence, "ATCGNNNATCG")

        editable.undo()  // ATCGATCG
        XCTAssertEqual(editable.sequence, "ATCGATCG")

        XCTAssertFalse(editable.canUndo)
        XCTAssertTrue(editable.canRedo)

        // Redo all three
        editable.redo()
        editable.redo()
        editable.redo()
        XCTAssertEqual(editable.sequence, "GNNNGGG G".replacingOccurrences(of: " ", with: ""))
    }

    // MARK: - State Management

    func testIsDirty() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        XCTAssertFalse(editable.isDirty)

        try editable.insert("G", at: 0)
        XCTAssertTrue(editable.isDirty)

        editable.undo()
        XCTAssertFalse(editable.isDirty)
    }

    func testIsDirtyAfterMultipleEdits() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("G", at: 0)
        try editable.delete(range: 0..<1)  // Back to original

        // Dirty is based on sequence content, not edit history
        // After insert "G" at 0: "GATCGATCG"
        // After delete 0..<1: "ATCGATCG" - same as original
        XCTAssertFalse(editable.isDirty)
    }

    func testMarkSaved() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("G", at: 0)
        XCTAssertTrue(editable.isDirty)

        editable.markSaved()
        XCTAssertFalse(editable.isDirty)
    }

    func testRevertToOriginal() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("G", at: 0)
        try editable.delete(range: 5..<8)

        editable.revertToOriginal()

        XCTAssertEqual(editable.sequence, "ATCGATCG")
        XCTAssertFalse(editable.canUndo)
        XCTAssertFalse(editable.canRedo)
        XCTAssertFalse(editable.isDirty)
    }

    func testClearHistory() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("G", at: 0)
        editable.clearHistory()

        XCTAssertFalse(editable.canUndo)
        // Sequence remains changed
        XCTAssertEqual(editable.sequence, "GATCGATCG")
    }

    // MARK: - Error Handling

    func testInsertEmptyStringThrows() {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        XCTAssertThrowsError(try editable.insert("", at: 0)) { error in
            guard case EditError.invalidOperation = error else {
                XCTFail("Expected invalidOperation error")
                return
            }
        }
    }

    func testInsertInvalidBasesThrows() {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test", alphabet: .dna)

        XCTAssertThrowsError(try editable.insert("XYZ", at: 0)) { error in
            guard case EditError.invalidOperation = error else {
                XCTFail("Expected invalidOperation error")
                return
            }
        }
    }

    func testDeleteEmptyRangeThrows() {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        XCTAssertThrowsError(try editable.delete(range: 5..<5)) { error in
            guard case EditError.invalidOperation = error else {
                XCTFail("Expected invalidOperation error")
                return
            }
        }
    }

    func testDeleteOutOfRangeThrows() {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        XCTAssertThrowsError(try editable.delete(range: 5..<100)) { error in
            guard case EditError.rangeOutOfBounds = error else {
                XCTFail("Expected rangeOutOfBounds error")
                return
            }
        }
    }

    func testReplaceOutOfRangeThrows() {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        XCTAssertThrowsError(try editable.replace(range: 5..<100, with: "NNN")) { error in
            guard case EditError.rangeOutOfBounds = error else {
                XCTFail("Expected rangeOutOfBounds error")
                return
            }
        }
    }

    func testReplaceInvalidBasesThrows() {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test", alphabet: .dna)

        XCTAssertThrowsError(try editable.replace(range: 0..<3, with: "XYZ")) { error in
            guard case EditError.invalidOperation = error else {
                XCTFail("Expected invalidOperation error")
                return
            }
        }
    }

    // MARK: - Conversion

    func testToSequence() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test_seq", alphabet: .dna)
        try editable.insert("NNN", at: 4)

        let seq = try editable.toSequence()

        XCTAssertEqual(seq.name, "test_seq")
        XCTAssertEqual(seq.alphabet, .dna)
        XCTAssertEqual(seq.asString(), "ATCGNNNATCG")
    }

    // MARK: - Operation History

    func testGetOperationHistory() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("A", at: 0)
        try editable.delete(range: 0..<1)

        let history = editable.getOperationHistory()

        XCTAssertEqual(history.count, 2)
    }

    func testReplayOperations() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        let operations = [
            EditOperation.insert(position: 0, bases: "GGG"),
            EditOperation.delete(position: 0, bases: "G")
        ]

        try editable.replayOperations(operations)

        XCTAssertEqual(editable.sequence, "GGATCGATCG")
    }

    // MARK: - Max Undo Levels

    func testMaxUndoLevels() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")
        editable.maxUndoLevels = 3

        // Perform 5 operations (using valid DNA bases)
        try editable.insert("A", at: 0)
        try editable.insert("G", at: 0)
        try editable.insert("C", at: 0)
        try editable.insert("T", at: 0)
        try editable.insert("N", at: 0)

        // Should only be able to undo 3 times
        var undoCount = 0
        while editable.undo() {
            undoCount += 1
        }

        XCTAssertEqual(undoCount, 3)
    }

    // MARK: - Batch Operations

    func testBatchOperations() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        let operations = [
            EditOperation.insert(position: 0, bases: "GGG"),
            EditOperation.insert(position: 11, bases: "CCC")  // After first insert
        ]

        try editable.performBatch(operations)

        XCTAssertEqual(editable.sequence, "GGGATCGATCGCCC")
    }

    func testBatchOperationRollbackOnFailure() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        let operations = [
            EditOperation.insert(position: 0, bases: "GGG"),
            EditOperation.delete(position: 100, bases: "X")  // Invalid - will fail
        ]

        do {
            try editable.performBatch(operations)
            XCTFail("Should throw error")
        } catch {
            // Should be rolled back to original
            XCTAssertEqual(editable.sequence, "ATCGATCG")
        }
    }

    func testBatchClosure() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.batch { seq in
            try seq.insert("GGG", at: 0)
            try seq.insert("CCC", at: seq.length)
        }

        XCTAssertEqual(editable.sequence, "GGGATCGATCGCCC")
    }

    func testBatchClosureRollbackOnFailure() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        do {
            try editable.batch { seq in
                try seq.insert("GGG", at: 0)
                try seq.delete(range: 100..<200)  // Invalid
            }
            XCTFail("Should throw error")
        } catch {
            XCTAssertEqual(editable.sequence, "ATCGATCG")
        }
    }

    // MARK: - Edge Cases

    func testOperationsOnEmptySequence() throws {
        let editable = EditableSequence(sequence: "", name: "empty")

        try editable.insert("ATCG", at: 0)
        XCTAssertEqual(editable.sequence, "ATCG")

        editable.undo()
        XCTAssertEqual(editable.sequence, "")
    }

    func testLargeSequenceEdits() throws {
        let largeSequence = String(repeating: "ATCG", count: 10000)  // 40,000 bases
        let editable = EditableSequence(sequence: largeSequence, name: "large")

        // Edit in the middle
        try editable.insert("NNNNN", at: 20000)

        XCTAssertEqual(editable.length, 40005)
        XCTAssertTrue(editable.canUndo)

        editable.undo()
        XCTAssertEqual(editable.length, 40000)
    }

    // MARK: - RNA Alphabet Tests

    func testRNAEditing() throws {
        let editable = EditableSequence(sequence: "AUCGAUCG", name: "rna", alphabet: .rna)

        try editable.insert("UUU", at: 4)
        XCTAssertEqual(editable.sequence, "AUCGUUUAUCG")

        // RNA molecules share the T alphabet, so T is accepted.
        XCTAssertNoThrow(try editable.insert("TTT", at: 0))
    }

    // MARK: - Protein Alphabet Tests

    func testProteinEditing() throws {
        let editable = EditableSequence(sequence: "MKTAY", name: "protein", alphabet: .protein)

        try editable.insert("WWW", at: 3)
        XCTAssertEqual(editable.sequence, "MKTWWWAY")

        // Lowercase should work
        try editable.insert("qqq", at: 0)
    }
}
