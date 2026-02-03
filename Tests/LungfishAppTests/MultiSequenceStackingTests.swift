// MultiSequenceStackingTests.swift - Tests for multi-sequence stacking
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishApp

/// Tests for multi-sequence stacking functionality in the viewer.
final class MultiSequenceStackingTests: XCTestCase {

    // MARK: - StackedSequenceInfo Tests

    func testStackedSequenceInfoCreation() throws {
        let seq = try Sequence(name: "Test", alphabet: .dna, bases: "ATCGATCG")

        let info = StackedSequenceInfo(
            sequence: seq,
            trackIndex: 0,
            yOffset: 20,
            sequenceHeight: 40,
            annotationHeight: 0,
            isReference: true,
            isActive: true,
            alignmentOffset: 0,
            annotations: []
        )

        XCTAssertEqual(info.sequence.name, "Test")
        XCTAssertEqual(info.trackIndex, 0)
        XCTAssertEqual(info.yOffset, 20)
        XCTAssertEqual(info.height, 40)  // sequenceHeight + annotationHeight
        XCTAssertTrue(info.isReference)
        XCTAssertTrue(info.isActive)
        XCTAssertEqual(info.alignmentOffset, 0)
    }

    // MARK: - SequenceStackLayout Tests

    func testLayoutYOffsetCalculation() {
        let layout = SequenceStackLayout(startY: 20, trackHeight: 40, spacing: 4)

        XCTAssertEqual(layout.yOffset(forTrack: 0), 20)
        XCTAssertEqual(layout.yOffset(forTrack: 1), 64)  // 20 + 44
        XCTAssertEqual(layout.yOffset(forTrack: 2), 108) // 20 + 88
    }

    func testLayoutTotalHeight() {
        let layout = SequenceStackLayout(startY: 20, trackHeight: 40, spacing: 4)

        XCTAssertEqual(layout.totalHeight(forSequenceCount: 0), 20)
        XCTAssertEqual(layout.totalHeight(forSequenceCount: 1), 64)  // 20 + 40 + 4
        XCTAssertEqual(layout.totalHeight(forSequenceCount: 3), 152) // 20 + 2*44 + 40 + 4
    }

    func testLayoutTrackIndexAtY() throws {
        let layout = SequenceStackLayout(startY: 20, trackHeight: 40, spacing: 4)

        // Create test sequences and stacked info
        let seq1 = try Sequence(name: "Seq1", alphabet: .dna, bases: "ATCG")
        let seq2 = try Sequence(name: "Seq2", alphabet: .dna, bases: "GCTA")
        let seq3 = try Sequence(name: "Seq3", alphabet: .dna, bases: "AAAA")

        let stackedSequences = [
            StackedSequenceInfo(sequence: seq1, trackIndex: 0, yOffset: 20, sequenceHeight: 40, annotationHeight: 0, isReference: true, isActive: true, alignmentOffset: 0, annotations: []),
            StackedSequenceInfo(sequence: seq2, trackIndex: 1, yOffset: 64, sequenceHeight: 40, annotationHeight: 0, isReference: false, isActive: false, alignmentOffset: 0, annotations: []),
            StackedSequenceInfo(sequence: seq3, trackIndex: 2, yOffset: 108, sequenceHeight: 40, annotationHeight: 0, isReference: false, isActive: false, alignmentOffset: 0, annotations: [])
        ]

        // Within first track
        XCTAssertEqual(layout.trackIndex(atY: 25, sequences: stackedSequences), 0)
        XCTAssertEqual(layout.trackIndex(atY: 55, sequences: stackedSequences), 0)

        // Within second track
        XCTAssertEqual(layout.trackIndex(atY: 70, sequences: stackedSequences), 1)

        // In spacing (should return nil or adjacent track)
        let spacingY: CGFloat = 62  // Between track 0 and 1
        XCTAssertNil(layout.trackIndex(atY: spacingY, sequences: stackedSequences))

        // Before first track
        XCTAssertNil(layout.trackIndex(atY: 10, sequences: stackedSequences))

        // After last track
        XCTAssertNil(layout.trackIndex(atY: 200, sequences: stackedSequences))
    }

    func testLayoutTrackRect() {
        let layout = SequenceStackLayout(startY: 20, trackHeight: 40, spacing: 4)

        let rect0 = layout.trackRect(forIndex: 0, width: 800)
        XCTAssertEqual(rect0.origin.x, 0)
        XCTAssertEqual(rect0.origin.y, 20)
        XCTAssertEqual(rect0.width, 800)
        XCTAssertEqual(rect0.height, 40)

        let rect1 = layout.trackRect(forIndex: 1, width: 800)
        XCTAssertEqual(rect1.origin.y, 64)
    }

    // MARK: - MultiSequenceState Tests

    @MainActor
    func testMultiSequenceStateCreation() {
        let state = MultiSequenceState()

        XCTAssertEqual(state.sequenceCount, 0)
        XCTAssertNil(state.referenceSequence)
        XCTAssertNil(state.activeSequence)
        XCTAssertFalse(state.hasMultipleSequences)
    }

    @MainActor
    func testSetSequences() throws {
        let state = MultiSequenceState()

        let seq1 = try Sequence(name: "Seq1", alphabet: .dna, bases: "ATCGATCGATCG")
        let seq2 = try Sequence(name: "Seq2", alphabet: .dna, bases: "GCTAGCTA")
        let seq3 = try Sequence(name: "Seq3", alphabet: .dna, bases: "AAAA")

        state.setSequences([seq1, seq2, seq3])

        XCTAssertEqual(state.sequenceCount, 3)
        XCTAssertTrue(state.hasMultipleSequences)
        XCTAssertEqual(state.referenceSequence?.name, "Seq1")
        XCTAssertEqual(state.activeSequence?.name, "Seq1")
        XCTAssertEqual(state.maxSequenceLength, 12)
    }

    @MainActor
    func testSetSequencesUseFirstAsReference() throws {
        let state = MultiSequenceState()

        // Seq2 is longest but Seq1 should be reference when useFirstAsReference=true
        let seq1 = try Sequence(name: "Seq1", alphabet: .dna, bases: "ATCG")
        let seq2 = try Sequence(name: "Seq2", alphabet: .dna, bases: "GCTAGCTAGCTA")

        state.setSequences([seq1, seq2], useFirstAsReference: true)

        XCTAssertEqual(state.referenceSequence?.name, "Seq1")
        XCTAssertEqual(state.maxSequenceLength, 12)
    }

    @MainActor
    func testSetActiveSequence() throws {
        let state = MultiSequenceState()

        let seq1 = try Sequence(name: "Seq1", alphabet: .dna, bases: "ATCG")
        let seq2 = try Sequence(name: "Seq2", alphabet: .dna, bases: "GCTA")

        state.setSequences([seq1, seq2])

        XCTAssertEqual(state.activeSequenceIndex, 0)
        XCTAssertEqual(state.activeSequence?.name, "Seq1")

        state.setActiveSequence(index: 1)

        XCTAssertEqual(state.activeSequenceIndex, 1)
        XCTAssertEqual(state.activeSequence?.name, "Seq2")
        XCTAssertTrue(state.stackedSequences[1].isActive)
        XCTAssertFalse(state.stackedSequences[0].isActive)
    }

    @MainActor
    func testAddSequence() throws {
        let state = MultiSequenceState()

        let seq1 = try Sequence(name: "Seq1", alphabet: .dna, bases: "ATCG")
        state.setSequences([seq1])

        XCTAssertEqual(state.sequenceCount, 1)
        XCTAssertFalse(state.hasMultipleSequences)

        let seq2 = try Sequence(name: "Seq2", alphabet: .dna, bases: "GCTA")
        state.addSequence(seq2)

        XCTAssertEqual(state.sequenceCount, 2)
        XCTAssertTrue(state.hasMultipleSequences)
    }

    @MainActor
    func testRemoveSequence() throws {
        let state = MultiSequenceState()

        let seq1 = try Sequence(name: "Seq1", alphabet: .dna, bases: "ATCG")
        let seq2 = try Sequence(name: "Seq2", alphabet: .dna, bases: "GCTA")
        let seq3 = try Sequence(name: "Seq3", alphabet: .dna, bases: "AAAA")

        state.setSequences([seq1, seq2, seq3])
        state.setActiveSequence(index: 1)

        state.removeSequence(at: 1)

        XCTAssertEqual(state.sequenceCount, 2)
        XCTAssertEqual(state.stackedSequences[0].sequence.name, "Seq1")
        XCTAssertEqual(state.stackedSequences[1].sequence.name, "Seq3")
        // Active index should be clamped
        XCTAssertEqual(state.activeSequenceIndex, 1)
    }

    @MainActor
    func testRemoveReferenceSequence() throws {
        let state = MultiSequenceState()

        let seq1 = try Sequence(name: "Seq1", alphabet: .dna, bases: "ATCG")
        let seq2 = try Sequence(name: "Seq2", alphabet: .dna, bases: "GCTA")

        state.setSequences([seq1, seq2])
        XCTAssertTrue(state.stackedSequences[0].isReference)

        state.removeSequence(at: 0)

        XCTAssertEqual(state.sequenceCount, 1)
        XCTAssertEqual(state.referenceSequence?.name, "Seq2")
        XCTAssertTrue(state.stackedSequences[0].isReference)
    }

    @MainActor
    func testClear() throws {
        let state = MultiSequenceState()

        let seq1 = try Sequence(name: "Seq1", alphabet: .dna, bases: "ATCG")
        let seq2 = try Sequence(name: "Seq2", alphabet: .dna, bases: "GCTA")

        state.setSequences([seq1, seq2])
        state.clear()

        XCTAssertEqual(state.sequenceCount, 0)
        XCTAssertNil(state.referenceSequence)
        XCTAssertEqual(state.activeSequenceIndex, 0)
    }

    @MainActor
    func testSequenceInfoAtY() throws {
        let state = MultiSequenceState()

        let seq1 = try Sequence(name: "Seq1", alphabet: .dna, bases: "ATCG")
        let seq2 = try Sequence(name: "Seq2", alphabet: .dna, bases: "GCTA")

        state.setSequences([seq1, seq2])

        // Y position in first track
        let info1 = state.sequenceInfo(atY: 30)
        XCTAssertEqual(info1?.sequence.name, "Seq1")

        // Y position in second track
        let info2 = state.sequenceInfo(atY: 70)
        XCTAssertEqual(info2?.sequence.name, "Seq2")

        // Y position outside tracks
        let infoNil = state.sequenceInfo(atY: 5)
        XCTAssertNil(infoNil)
    }

    // MARK: - Stacked Sequence Y Offset Tests

    @MainActor
    func testStackedSequenceYOffsets() throws {
        let state = MultiSequenceState()

        let seq1 = try Sequence(name: "Seq1", alphabet: .dna, bases: "ATCG")
        let seq2 = try Sequence(name: "Seq2", alphabet: .dna, bases: "GCTA")
        let seq3 = try Sequence(name: "Seq3", alphabet: .dna, bases: "AAAA")

        state.setSequences([seq1, seq2, seq3])

        // With default trackHeight=28, spacing=4:
        // Track 0: startY=20
        // Track 1: 20 + 28 + 4 = 52
        // Track 2: 52 + 28 + 4 = 84
        XCTAssertEqual(state.stackedSequences[0].yOffset, 20)
        XCTAssertEqual(state.stackedSequences[1].yOffset, 52)
        XCTAssertEqual(state.stackedSequences[2].yOffset, 84)
    }

    // MARK: - Edge Cases

    @MainActor
    func testEmptySequencesArray() {
        let state = MultiSequenceState()
        state.setSequences([])

        XCTAssertEqual(state.sequenceCount, 0)
        XCTAssertNil(state.referenceSequence)
        XCTAssertNil(state.activeSequence)
    }

    @MainActor
    func testSingleSequence() throws {
        let state = MultiSequenceState()

        let seq1 = try Sequence(name: "Single", alphabet: .dna, bases: "ATCG")
        state.setSequences([seq1])

        XCTAssertEqual(state.sequenceCount, 1)
        XCTAssertFalse(state.hasMultipleSequences)
        XCTAssertEqual(state.referenceSequence?.name, "Single")
        XCTAssertEqual(state.activeSequence?.name, "Single")
    }

    @MainActor
    func testInvalidActiveIndex() throws {
        let state = MultiSequenceState()

        let seq1 = try Sequence(name: "Seq1", alphabet: .dna, bases: "ATCG")
        state.setSequences([seq1])

        // Setting invalid index should be ignored
        state.setActiveSequence(index: 10)
        XCTAssertEqual(state.activeSequenceIndex, 0)

        state.setActiveSequence(index: -1)
        XCTAssertEqual(state.activeSequenceIndex, 0)
    }
}

// MARK: - Array Extension Tests

final class ArraySafeSubscriptTests: XCTestCase {

    func testSafeSubscriptValidIndex() {
        let array = [1, 2, 3, 4, 5]

        XCTAssertEqual(array[safe: 0], 1)
        XCTAssertEqual(array[safe: 2], 3)
        XCTAssertEqual(array[safe: 4], 5)
    }

    func testSafeSubscriptInvalidIndex() {
        let array = [1, 2, 3]

        XCTAssertNil(array[safe: -1])
        XCTAssertNil(array[safe: 3])
        XCTAssertNil(array[safe: 100])
    }

    func testSafeSubscriptEmptyArray() {
        let array: [Int] = []

        XCTAssertNil(array[safe: 0])
        XCTAssertNil(array[safe: -1])
    }
}
