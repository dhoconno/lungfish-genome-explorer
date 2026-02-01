// SequenceDiffTests.swift - Tests for SequenceDiff
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class SequenceDiffTests: XCTestCase {

    // MARK: - Compute Tests

    func testComputeNoChange() {
        let diff = SequenceDiff.compute(from: "ATCGATCG", to: "ATCGATCG")

        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.operationCount, 0)
    }

    func testComputeInsertion() {
        let diff = SequenceDiff.compute(from: "ATCGATCG", to: "ATCGNNNATCG")

        XCTAssertFalse(diff.isEmpty)
        XCTAssertEqual(diff.operationCount, 1)

        if case .insert(let position, let bases) = diff.operations[0] {
            XCTAssertEqual(position, 4)
            XCTAssertEqual(bases, "NNN")
        } else {
            XCTFail("Expected insert operation")
        }
    }

    func testComputeDeletion() {
        let diff = SequenceDiff.compute(from: "ATCGATCG", to: "ATCG")

        XCTAssertFalse(diff.isEmpty)
        XCTAssertEqual(diff.operationCount, 1)

        if case .delete(let position, let length, let original) = diff.operations[0] {
            XCTAssertEqual(position, 4)
            XCTAssertEqual(length, 4)
            XCTAssertEqual(original, "ATCG")
        } else {
            XCTFail("Expected delete operation")
        }
    }

    func testComputeReplacement() {
        let diff = SequenceDiff.compute(from: "ATCGATCG", to: "ATCGNNNNCG")

        XCTAssertFalse(diff.isEmpty)
        XCTAssertEqual(diff.operationCount, 1)

        if case .replace(let position, let original, let replacement) = diff.operations[0] {
            XCTAssertEqual(position, 4)
            XCTAssertEqual(original, "AT")
            XCTAssertEqual(replacement, "NNNN")
        } else {
            XCTFail("Expected replace operation")
        }
    }

    func testComputePrefixInsertion() {
        let diff = SequenceDiff.compute(from: "ATCG", to: "GGGATCG")

        XCTAssertEqual(diff.operationCount, 1)

        if case .insert(let position, let bases) = diff.operations[0] {
            XCTAssertEqual(position, 0)
            XCTAssertEqual(bases, "GGG")
        } else {
            XCTFail("Expected insert operation")
        }
    }

    func testComputeSuffixInsertion() {
        let diff = SequenceDiff.compute(from: "ATCG", to: "ATCGGGG")

        XCTAssertEqual(diff.operationCount, 1)

        if case .insert(let position, let bases) = diff.operations[0] {
            XCTAssertEqual(position, 4)
            XCTAssertEqual(bases, "GGG")
        } else {
            XCTFail("Expected insert operation")
        }
    }

    // MARK: - Apply Tests

    func testApplyInsertion() throws {
        let diff = SequenceDiff(operations: [
            .insert(position: 4, bases: "NNN")
        ])

        let result = try diff.apply(to: "ATCGATCG")

        XCTAssertEqual(result, "ATCGNNNATCG")
    }

    func testApplyDeletion() throws {
        let diff = SequenceDiff(operations: [
            .delete(position: 4, length: 4, original: "ATCG")
        ])

        let result = try diff.apply(to: "ATCGATCG")

        XCTAssertEqual(result, "ATCG")
    }

    func testApplyReplacement() throws {
        let diff = SequenceDiff(operations: [
            .replace(position: 0, original: "ATC", replacement: "GGG")
        ])

        let result = try diff.apply(to: "ATCGATCG")

        XCTAssertEqual(result, "GGGGATCG")
    }

    func testApplyInvalidPositionThrows() {
        let diff = SequenceDiff(operations: [
            .insert(position: 100, bases: "NNN")
        ])

        XCTAssertThrowsError(try diff.apply(to: "ATCG")) { error in
            guard case DiffError.positionOutOfBounds = error else {
                XCTFail("Expected positionOutOfBounds error")
                return
            }
        }
    }

    func testApplyContentMismatchThrows() {
        let diff = SequenceDiff(operations: [
            .delete(position: 0, length: 3, original: "GGG")
        ])

        XCTAssertThrowsError(try diff.apply(to: "ATCG")) { error in
            guard case DiffError.contentMismatch = error else {
                XCTFail("Expected contentMismatch error")
                return
            }
        }
    }

    // MARK: - Inverse Tests

    func testInverse() throws {
        let original = "ATCGATCG"
        let modified = "ATCGNNNATCG"

        let diff = SequenceDiff.compute(from: original, to: modified)
        let applied = try diff.apply(to: original)
        XCTAssertEqual(applied, modified)

        let inverse = diff.inverse()
        let restored = try inverse.apply(to: applied)
        XCTAssertEqual(restored, original)
    }

    // MARK: - Length Delta Tests

    func testLengthDelta() {
        let insertDiff = SequenceDiff(operations: [
            .insert(position: 0, bases: "ATCG")
        ])
        XCTAssertEqual(insertDiff.lengthDelta, 4)

        let deleteDiff = SequenceDiff(operations: [
            .delete(position: 0, length: 4, original: "ATCG")
        ])
        XCTAssertEqual(deleteDiff.lengthDelta, -4)

        let replaceDiff = SequenceDiff(operations: [
            .replace(position: 0, original: "AT", replacement: "GGGG")
        ])
        XCTAssertEqual(replaceDiff.lengthDelta, 2)
    }

    // MARK: - VCF Export Tests

    func testToVCFString() {
        let diff = SequenceDiff(operations: [
            .insert(position: 100, bases: "GGG"),
            .delete(position: 200, length: 4, original: "ATCG"),
            .replace(position: 300, original: "A", replacement: "G")
        ])

        let vcf = diff.toVCFString(sequenceName: "chr1")

        XCTAssertTrue(vcf.contains("#CHROM\tPOS\tREF\tALT\tTYPE"))
        XCTAssertTrue(vcf.contains("chr1\t101\t.\tGGG\tins"))
        XCTAssertTrue(vcf.contains("chr1\t201\tATCG\t.\tdel"))
        XCTAssertTrue(vcf.contains("chr1\t301\tA\tG\tsnp"))
    }

    // MARK: - Round-Trip Tests

    func testRoundTrip() throws {
        let original = "ATCGATCGATCGATCG"
        let modified = "ATCNNNGATCGATCG"

        let diff = SequenceDiff.compute(from: original, to: modified)
        let result = try diff.apply(to: original)

        XCTAssertEqual(result, modified)
    }
}
