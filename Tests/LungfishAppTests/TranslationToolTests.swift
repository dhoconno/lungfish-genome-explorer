// TranslationToolTests.swift - Tests for TranslationToolView types (Phase 6)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishApp

// MARK: - TranslationMode Tests

final class TranslationModeTests: XCTestCase {

    // MARK: - Enum Basics

    func testAllCasesCount() {
        XCTAssertEqual(TranslationMode.allCases.count, 4)
    }

    func testRawValues() {
        XCTAssertEqual(TranslationMode.singleFrame.rawValue, "Single Frame")
        XCTAssertEqual(TranslationMode.threeForward.rawValue, "3 Forward")
        XCTAssertEqual(TranslationMode.threeReverse.rawValue, "3 Reverse")
        XCTAssertEqual(TranslationMode.allSix.rawValue, "All 6 Frames")
    }

    func testIdentifiableIdMatchesRawValue() {
        for mode in TranslationMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue, "id should match rawValue for \(mode)")
        }
    }

    func testUniqueIds() {
        let ids = TranslationMode.allCases.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "All mode ids should be unique")
    }

    // MARK: - frames(singleFrame:) — Single Frame Mode

    func testSingleFrameModePlus1() {
        let frames = TranslationMode.singleFrame.frames(singleFrame: .plus1)
        XCTAssertEqual(frames, [.plus1])
    }

    func testSingleFrameModePlus2() {
        let frames = TranslationMode.singleFrame.frames(singleFrame: .plus2)
        XCTAssertEqual(frames, [.plus2])
    }

    func testSingleFrameModePlus3() {
        let frames = TranslationMode.singleFrame.frames(singleFrame: .plus3)
        XCTAssertEqual(frames, [.plus3])
    }

    func testSingleFrameModeMinus1() {
        let frames = TranslationMode.singleFrame.frames(singleFrame: .minus1)
        XCTAssertEqual(frames, [.minus1])
    }

    func testSingleFrameModeMinus2() {
        let frames = TranslationMode.singleFrame.frames(singleFrame: .minus2)
        XCTAssertEqual(frames, [.minus2])
    }

    func testSingleFrameModeMinus3() {
        let frames = TranslationMode.singleFrame.frames(singleFrame: .minus3)
        XCTAssertEqual(frames, [.minus3])
    }

    func testSingleFrameModeReturnsExactlyOneFrame() {
        for readingFrame in ReadingFrame.allCases {
            let frames = TranslationMode.singleFrame.frames(singleFrame: readingFrame)
            XCTAssertEqual(frames.count, 1, "Single frame mode should always return exactly 1 frame")
        }
    }

    // MARK: - frames(singleFrame:) — Three Forward Mode

    func testThreeForwardModeFrames() {
        let frames = TranslationMode.threeForward.frames(singleFrame: .plus1)
        XCTAssertEqual(frames, [.plus1, .plus2, .plus3])
    }

    func testThreeForwardModeAlwaysReturnsThree() {
        let frames = TranslationMode.threeForward.frames(singleFrame: .plus1)
        XCTAssertEqual(frames.count, 3)
    }

    func testThreeForwardModeAllForward() {
        let frames = TranslationMode.threeForward.frames(singleFrame: .plus1)
        XCTAssertTrue(frames.allSatisfy { !$0.isReverse }, "All frames should be forward")
    }

    func testThreeForwardModeIgnoresSingleFrameParameter() {
        let framesA = TranslationMode.threeForward.frames(singleFrame: .plus1)
        let framesB = TranslationMode.threeForward.frames(singleFrame: .minus3)
        XCTAssertEqual(framesA, framesB, "singleFrame parameter should not affect threeForward mode")
    }

    // MARK: - frames(singleFrame:) — Three Reverse Mode

    func testThreeReverseModeFrames() {
        let frames = TranslationMode.threeReverse.frames(singleFrame: .plus1)
        XCTAssertEqual(frames, [.minus1, .minus2, .minus3])
    }

    func testThreeReverseModeAlwaysReturnsThree() {
        let frames = TranslationMode.threeReverse.frames(singleFrame: .plus1)
        XCTAssertEqual(frames.count, 3)
    }

    func testThreeReverseModeAllReverse() {
        let frames = TranslationMode.threeReverse.frames(singleFrame: .plus1)
        XCTAssertTrue(frames.allSatisfy { $0.isReverse }, "All frames should be reverse")
    }

    func testThreeReverseModeIgnoresSingleFrameParameter() {
        let framesA = TranslationMode.threeReverse.frames(singleFrame: .plus1)
        let framesB = TranslationMode.threeReverse.frames(singleFrame: .minus2)
        XCTAssertEqual(framesA, framesB, "singleFrame parameter should not affect threeReverse mode")
    }

    // MARK: - frames(singleFrame:) — All Six Mode

    func testAllSixModeFrames() {
        let frames = TranslationMode.allSix.frames(singleFrame: .plus1)
        XCTAssertEqual(frames.count, 6)
    }

    func testAllSixModeContainsAllReadingFrames() {
        let frames = TranslationMode.allSix.frames(singleFrame: .plus1)
        let frameSet = Set(frames)
        XCTAssertEqual(frameSet, Set(ReadingFrame.allCases))
    }

    func testAllSixModeContainsForwardAndReverse() {
        let frames = TranslationMode.allSix.frames(singleFrame: .plus1)
        let forwardCount = frames.filter { !$0.isReverse }.count
        let reverseCount = frames.filter { $0.isReverse }.count
        XCTAssertEqual(forwardCount, 3, "Should contain 3 forward frames")
        XCTAssertEqual(reverseCount, 3, "Should contain 3 reverse frames")
    }

    func testAllSixModeIgnoresSingleFrameParameter() {
        let framesA = TranslationMode.allSix.frames(singleFrame: .plus1)
        let framesB = TranslationMode.allSix.frames(singleFrame: .minus3)
        XCTAssertEqual(framesA, framesB, "singleFrame parameter should not affect allSix mode")
    }

    // MARK: - Frame Offsets Correctness

    func testForwardFrameOffsetsAreCovered() {
        let frames = TranslationMode.threeForward.frames(singleFrame: .plus1)
        let offsets = frames.map(\.offset)
        XCTAssertEqual(Set(offsets), Set([0, 1, 2]), "Forward frames should cover offsets 0, 1, 2")
    }

    func testReverseFrameOffsetsAreCovered() {
        let frames = TranslationMode.threeReverse.frames(singleFrame: .plus1)
        let offsets = frames.map(\.offset)
        XCTAssertEqual(Set(offsets), Set([0, 1, 2]), "Reverse frames should cover offsets 0, 1, 2")
    }
}

// MARK: - TranslationToolConfiguration Tests

final class TranslationToolConfigurationTests: XCTestCase {

    // MARK: - Creation and Field Access

    func testConfigurationCreation() {
        let config = TranslationToolConfiguration(
            frames: [.plus1, .plus2, .plus3],
            codonTable: .standard,
            colorScheme: .zappo,
            showStopCodons: true
        )

        XCTAssertEqual(config.frames, [.plus1, .plus2, .plus3])
        XCTAssertEqual(config.codonTable.id, CodonTable.standard.id)
        XCTAssertEqual(config.colorScheme, .zappo)
        XCTAssertTrue(config.showStopCodons)
    }

    func testConfigurationWithEmptyFrames() {
        let config = TranslationToolConfiguration(
            frames: [],
            codonTable: .standard,
            colorScheme: .zappo,
            showStopCodons: true
        )

        XCTAssertTrue(config.frames.isEmpty, "Empty frames signals hide translation")
    }

    func testConfigurationWithSingleFrame() {
        let config = TranslationToolConfiguration(
            frames: [.minus2],
            codonTable: .vertebrateMitochondrial,
            colorScheme: .clustal,
            showStopCodons: false
        )

        XCTAssertEqual(config.frames.count, 1)
        XCTAssertEqual(config.frames.first, .minus2)
        XCTAssertEqual(config.codonTable.id, CodonTable.vertebrateMitochondrial.id)
        XCTAssertEqual(config.colorScheme, .clustal)
        XCTAssertFalse(config.showStopCodons)
    }

    func testConfigurationWithAllSixFrames() {
        let allFrames = ReadingFrame.allCases
        let config = TranslationToolConfiguration(
            frames: Array(allFrames),
            codonTable: .bacterial,
            colorScheme: .taylor,
            showStopCodons: true
        )

        XCTAssertEqual(config.frames.count, 6)
        XCTAssertEqual(config.codonTable.id, CodonTable.bacterial.id)
        XCTAssertEqual(config.colorScheme, .taylor)
    }

    func testConfigurationWithYeastMitoTable() {
        let config = TranslationToolConfiguration(
            frames: [.plus1],
            codonTable: .yeastMitochondrial,
            colorScheme: .hydrophobicity,
            showStopCodons: false
        )

        XCTAssertEqual(config.codonTable.id, CodonTable.yeastMitochondrial.id)
        XCTAssertEqual(config.colorScheme, .hydrophobicity)
    }

    // MARK: - Hide Translation Convention

    func testEmptyFramesIsHideSignal() {
        let hideConfig = TranslationToolConfiguration(
            frames: [],
            codonTable: .standard,
            colorScheme: .zappo,
            showStopCodons: true
        )

        let showConfig = TranslationToolConfiguration(
            frames: [.plus1],
            codonTable: .standard,
            colorScheme: .zappo,
            showStopCodons: true
        )

        XCTAssertTrue(hideConfig.frames.isEmpty)
        XCTAssertFalse(showConfig.frames.isEmpty)
    }

    // MARK: - All Codon Tables Available

    func testAllCodonTablesAccessible() {
        let tables = CodonTable.allTables
        XCTAssertEqual(tables.count, 4)

        for table in tables {
            let config = TranslationToolConfiguration(
                frames: [.plus1],
                codonTable: table,
                colorScheme: .zappo,
                showStopCodons: true
            )
            XCTAssertEqual(config.codonTable.id, table.id)
        }
    }

    // MARK: - All Color Schemes Available

    func testAllColorSchemesAccessible() {
        let schemes = AminoAcidColorScheme.allCases
        XCTAssertEqual(schemes.count, 4)

        for scheme in schemes {
            let config = TranslationToolConfiguration(
                frames: [.plus1],
                codonTable: .standard,
                colorScheme: scheme,
                showStopCodons: true
            )
            XCTAssertEqual(config.colorScheme, scheme)
        }
    }

    // MARK: - Mode-to-Configuration Integration

    func testSingleFrameModeProducesValidConfig() {
        let frames = TranslationMode.singleFrame.frames(singleFrame: .plus2)
        let config = TranslationToolConfiguration(
            frames: frames,
            codonTable: .standard,
            colorScheme: .zappo,
            showStopCodons: true
        )

        XCTAssertEqual(config.frames, [.plus2])
    }

    func testThreeForwardModeProducesValidConfig() {
        let frames = TranslationMode.threeForward.frames(singleFrame: .plus1)
        let config = TranslationToolConfiguration(
            frames: frames,
            codonTable: .standard,
            colorScheme: .zappo,
            showStopCodons: true
        )

        XCTAssertEqual(config.frames.count, 3)
        XCTAssertTrue(config.frames.allSatisfy { !$0.isReverse })
    }

    func testThreeReverseModeProducesValidConfig() {
        let frames = TranslationMode.threeReverse.frames(singleFrame: .plus1)
        let config = TranslationToolConfiguration(
            frames: frames,
            codonTable: .standard,
            colorScheme: .clustal,
            showStopCodons: false
        )

        XCTAssertEqual(config.frames.count, 3)
        XCTAssertTrue(config.frames.allSatisfy { $0.isReverse })
    }

    func testAllSixModeProducesValidConfig() {
        let frames = TranslationMode.allSix.frames(singleFrame: .plus1)
        let config = TranslationToolConfiguration(
            frames: frames,
            codonTable: .vertebrateMitochondrial,
            colorScheme: .taylor,
            showStopCodons: true
        )

        XCTAssertEqual(config.frames.count, 6)
    }
}

// MARK: - ReadingFrame Property Tests (Supporting Phase 6)

final class ReadingFramePropertyTests: XCTestCase {

    func testForwardFramesCount() {
        XCTAssertEqual(ReadingFrame.forwardFrames.count, 3)
    }

    func testReverseFramesCount() {
        XCTAssertEqual(ReadingFrame.reverseFrames.count, 3)
    }

    func testAllCasesIsSixFrames() {
        XCTAssertEqual(ReadingFrame.allCases.count, 6)
    }

    func testForwardFramesAreNotReverse() {
        for frame in ReadingFrame.forwardFrames {
            XCTAssertFalse(frame.isReverse, "\(frame.rawValue) should not be reverse")
        }
    }

    func testReverseFramesAreReverse() {
        for frame in ReadingFrame.reverseFrames {
            XCTAssertTrue(frame.isReverse, "\(frame.rawValue) should be reverse")
        }
    }

    func testForwardAndReversePartitionAllCases() {
        let forward = Set(ReadingFrame.forwardFrames)
        let reverse = Set(ReadingFrame.reverseFrames)
        let all = Set(ReadingFrame.allCases)

        XCTAssertEqual(forward.union(reverse), all, "Forward + reverse should equal all cases")
        XCTAssertTrue(forward.isDisjoint(with: reverse), "Forward and reverse should not overlap")
    }

    func testFrameRawValues() {
        XCTAssertEqual(ReadingFrame.plus1.rawValue, "+1")
        XCTAssertEqual(ReadingFrame.plus2.rawValue, "+2")
        XCTAssertEqual(ReadingFrame.plus3.rawValue, "+3")
        XCTAssertEqual(ReadingFrame.minus1.rawValue, "-1")
        XCTAssertEqual(ReadingFrame.minus2.rawValue, "-2")
        XCTAssertEqual(ReadingFrame.minus3.rawValue, "-3")
    }

    func testFrameOffsets() {
        XCTAssertEqual(ReadingFrame.plus1.offset, 0)
        XCTAssertEqual(ReadingFrame.plus2.offset, 1)
        XCTAssertEqual(ReadingFrame.plus3.offset, 2)
        XCTAssertEqual(ReadingFrame.minus1.offset, 0)
        XCTAssertEqual(ReadingFrame.minus2.offset, 1)
        XCTAssertEqual(ReadingFrame.minus3.offset, 2)
    }

    func testMatchingForwardReverseOffsets() {
        for forwardFrame in ReadingFrame.forwardFrames {
            let matchingReverse = ReadingFrame.reverseFrames.first { $0.offset == forwardFrame.offset }
            XCTAssertNotNil(matchingReverse, "Should find a reverse frame matching offset \(forwardFrame.offset)")
        }
    }
}
