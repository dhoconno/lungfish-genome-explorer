// EditableSequenceTests.swift - Tests for EditableSequence
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

@MainActor
final class EditableSequenceTests: XCTestCase {

    // MARK: - Basic Operations

    func testInsert() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("GGG", at: 4)

        XCTAssertEqual(editable.sequence, "ATCGGGGATCG")
        XCTAssertTrue(editable.canUndo)
        XCTAssertFalse(editable.canRedo)
        XCTAssertTrue(editable.isDirty)
    }

    func testDelete() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.delete(range: 2..<5)

        XCTAssertEqual(editable.sequence, "ATTCG")
        XCTAssertTrue(editable.canUndo)
    }

    func testReplace() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.replace(range: 0..<3, with: "NNN")

        XCTAssertEqual(editable.sequence, "NNNGATCG")
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

    func testNewEditClearsRedoStack() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test")

        try editable.insert("A", at: 0)
        editable.undo()
        XCTAssertTrue(editable.canRedo)

        try editable.insert("B", at: 0)
        XCTAssertFalse(editable.canRedo)
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

    // MARK: - Conversion

    func testToSequence() throws {
        let editable = EditableSequence(sequence: "ATCGATCG", name: "test_seq", alphabet: .dna)
        try editable.insert("NNN", at: 4)

        let seq = try editable.toSequence()

        XCTAssertEqual(seq.name, "test_seq")
        XCTAssertEqual(seq.alphabet, .dna)
        XCTAssertEqual(seq.asString(), "ATCGNNNATCG")
    }

    func testInitFromSequence() throws {
        let seq = try Sequence(name: "source", alphabet: .dna, bases: "ATCGATCG")
        let editable = EditableSequence(from: seq)

        XCTAssertEqual(editable.name, "source")
        XCTAssertEqual(editable.alphabet, .dna)
        XCTAssertEqual(editable.sequence, "ATCGATCG")
    }
}
