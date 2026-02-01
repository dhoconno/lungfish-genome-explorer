// EditOperationTests.swift - Tests for edit operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class EditOperationTests: XCTestCase {

    // MARK: - Insert Tests

    func testInsertAtStart() throws {
        var sequence = "ATCGATCG"
        let op = EditOperation.insert(position: 0, bases: "GGG")

        try op.apply(to: &sequence)

        XCTAssertEqual(sequence, "GGGATCGATCG")
    }

    func testInsertAtMiddle() throws {
        var sequence = "ATCGATCG"
        let op = EditOperation.insert(position: 4, bases: "NNN")

        try op.apply(to: &sequence)

        XCTAssertEqual(sequence, "ATCGNNNATCG")
    }

    func testInsertAtEnd() throws {
        var sequence = "ATCGATCG"
        let op = EditOperation.insert(position: 8, bases: "TTT")

        try op.apply(to: &sequence)

        XCTAssertEqual(sequence, "ATCGATCGTTT")
    }

    func testInsertOutOfBoundsThrows() {
        var sequence = "ATCGATCG"
        let op = EditOperation.insert(position: 100, bases: "GGG")

        XCTAssertThrowsError(try op.apply(to: &sequence)) { error in
            guard case EditError.positionOutOfBounds = error else {
                XCTFail("Expected positionOutOfBounds error")
                return
            }
        }
    }

    // MARK: - Delete Tests

    func testDeleteFromStart() throws {
        var sequence = "ATCGATCG"
        let op = EditOperation.delete(position: 0, bases: "ATC")

        try op.apply(to: &sequence)

        XCTAssertEqual(sequence, "GATCG")
    }

    func testDeleteFromMiddle() throws {
        var sequence = "ATCGATCG"
        let op = EditOperation.delete(position: 3, bases: "GA")

        try op.apply(to: &sequence)

        XCTAssertEqual(sequence, "ATCTCG")
    }

    func testDeleteFromEnd() throws {
        var sequence = "ATCGATCG"
        let op = EditOperation.delete(position: 5, bases: "TCG")

        try op.apply(to: &sequence)

        XCTAssertEqual(sequence, "ATCGA")
    }

    func testDeleteContentMismatchThrows() {
        var sequence = "ATCGATCG"
        let op = EditOperation.delete(position: 0, bases: "GGG")

        XCTAssertThrowsError(try op.apply(to: &sequence)) { error in
            guard case EditError.contentMismatch = error else {
                XCTFail("Expected contentMismatch error")
                return
            }
        }
    }

    func testDeleteOutOfBoundsThrows() {
        var sequence = "ATCGATCG"
        let op = EditOperation.delete(position: 6, bases: "CGGGGG")

        XCTAssertThrowsError(try op.apply(to: &sequence)) { error in
            guard case EditError.rangeOutOfBounds = error else {
                XCTFail("Expected rangeOutOfBounds error")
                return
            }
        }
    }

    // MARK: - Replace Tests

    func testReplaceSingleBase() throws {
        var sequence = "ATCGATCG"
        let op = EditOperation.replace(position: 3, original: "G", replacement: "T")

        try op.apply(to: &sequence)

        XCTAssertEqual(sequence, "ATCTATCG")
    }

    func testReplaceWithShorter() throws {
        var sequence = "ATCGATCG"
        let op = EditOperation.replace(position: 2, original: "CGAT", replacement: "X")

        try op.apply(to: &sequence)

        XCTAssertEqual(sequence, "ATXCG")
    }

    func testReplaceWithLonger() throws {
        var sequence = "ATCGATCG"
        let op = EditOperation.replace(position: 3, original: "G", replacement: "NNNNN")

        try op.apply(to: &sequence)

        XCTAssertEqual(sequence, "ATCNNNNNATCG")
    }

    func testReplaceContentMismatchThrows() {
        var sequence = "ATCGATCG"
        let op = EditOperation.replace(position: 0, original: "GGG", replacement: "TTT")

        XCTAssertThrowsError(try op.apply(to: &sequence)) { error in
            guard case EditError.contentMismatch = error else {
                XCTFail("Expected contentMismatch error")
                return
            }
        }
    }

    // MARK: - Inverse Tests

    func testInsertInverse() throws {
        var sequence = "ATCGATCG"
        let insert = EditOperation.insert(position: 4, bases: "NNN")
        try insert.apply(to: &sequence)

        XCTAssertEqual(sequence, "ATCGNNNATCG")

        let inverse = insert.inverse()
        try inverse.apply(to: &sequence)

        XCTAssertEqual(sequence, "ATCGATCG")
    }

    func testDeleteInverse() throws {
        var sequence = "ATCGATCG"
        let delete = EditOperation.delete(position: 2, bases: "CG")
        try delete.apply(to: &sequence)

        XCTAssertEqual(sequence, "ATATCG")

        let inverse = delete.inverse()
        try inverse.apply(to: &sequence)

        XCTAssertEqual(sequence, "ATCGATCG")
    }

    func testReplaceInverse() throws {
        var sequence = "ATCGATCG"
        let replace = EditOperation.replace(position: 0, original: "ATC", replacement: "GGG")
        try replace.apply(to: &sequence)

        XCTAssertEqual(sequence, "GGGGATCG")

        let inverse = replace.inverse()
        try inverse.apply(to: &sequence)

        XCTAssertEqual(sequence, "ATCGATCG")
    }

    // MARK: - Properties Tests

    func testLengthDelta() {
        let insert = EditOperation.insert(position: 0, bases: "ATCG")
        XCTAssertEqual(insert.lengthDelta, 4)

        let delete = EditOperation.delete(position: 0, bases: "ATCG")
        XCTAssertEqual(delete.lengthDelta, -4)

        let replaceShorter = EditOperation.replace(position: 0, original: "ATCG", replacement: "A")
        XCTAssertEqual(replaceShorter.lengthDelta, -3)

        let replaceLonger = EditOperation.replace(position: 0, original: "A", replacement: "ATCG")
        XCTAssertEqual(replaceLonger.lengthDelta, 3)
    }

    func testIsValid() {
        let sequence = "ATCGATCG"  // length 8

        XCTAssertTrue(EditOperation.insert(position: 0, bases: "G").isValid(for: sequence.count))
        XCTAssertTrue(EditOperation.insert(position: 8, bases: "G").isValid(for: sequence.count))
        XCTAssertFalse(EditOperation.insert(position: 9, bases: "G").isValid(for: sequence.count))

        XCTAssertTrue(EditOperation.delete(position: 0, bases: "ATC").isValid(for: sequence.count))
        XCTAssertFalse(EditOperation.delete(position: 6, bases: "CGGG").isValid(for: sequence.count))
    }
}
