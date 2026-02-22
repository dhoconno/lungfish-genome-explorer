// AlignedReadTests.swift - Tests for AlignedRead and CIGAROperation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

// MARK: - CIGAROperation Tests

final class CIGAROperationTests: XCTestCase {

    func testParseSimpleCIGAR() {
        let ops = CIGAROperation.parse("75M")
        XCTAssertNotNil(ops)
        XCTAssertEqual(ops?.count, 1)
        XCTAssertEqual(ops?.first?.op, .match)
        XCTAssertEqual(ops?.first?.length, 75)
    }

    func testParseComplexCIGAR() {
        let ops = CIGAROperation.parse("50M2I3D45M")
        XCTAssertNotNil(ops)
        XCTAssertEqual(ops?.count, 4)
        XCTAssertEqual(ops?[0].op, .match)
        XCTAssertEqual(ops?[0].length, 50)
        XCTAssertEqual(ops?[1].op, .insertion)
        XCTAssertEqual(ops?[1].length, 2)
        XCTAssertEqual(ops?[2].op, .deletion)
        XCTAssertEqual(ops?[2].length, 3)
        XCTAssertEqual(ops?[3].op, .match)
        XCTAssertEqual(ops?[3].length, 45)
    }

    func testParseSoftClipCIGAR() {
        let ops = CIGAROperation.parse("5S95M")
        XCTAssertNotNil(ops)
        XCTAssertEqual(ops?.count, 2)
        XCTAssertEqual(ops?[0].op, .softClip)
        XCTAssertEqual(ops?[0].length, 5)
    }

    func testParseStarCIGAR() {
        let ops = CIGAROperation.parse("*")
        XCTAssertNotNil(ops)
        XCTAssertTrue(ops?.isEmpty ?? false)
    }

    func testParseInvalidCIGAR() {
        XCTAssertNil(CIGAROperation.parse("abc"))
        XCTAssertNil(CIGAROperation.parse("50"))
        XCTAssertNil(CIGAROperation.parse("M50"))
    }

    func testParseAllOperationTypes() {
        let ops = CIGAROperation.parse("10M5I3D2N4S1H1P2=3X")
        XCTAssertNotNil(ops)
        XCTAssertEqual(ops?.count, 9)
        XCTAssertEqual(ops?[0].op, .match)
        XCTAssertEqual(ops?[1].op, .insertion)
        XCTAssertEqual(ops?[2].op, .deletion)
        XCTAssertEqual(ops?[3].op, .skip)
        XCTAssertEqual(ops?[4].op, .softClip)
        XCTAssertEqual(ops?[5].op, .hardClip)
        XCTAssertEqual(ops?[6].op, .padding)
        XCTAssertEqual(ops?[7].op, .seqMatch)
        XCTAssertEqual(ops?[8].op, .seqMismatch)
    }

    func testConsumesReference() {
        let matchOp = CIGAROperation(op: .match, length: 10)
        XCTAssertTrue(matchOp.consumesReference)

        let insertOp = CIGAROperation(op: .insertion, length: 5)
        XCTAssertFalse(insertOp.consumesReference)

        let deletionOp = CIGAROperation(op: .deletion, length: 3)
        XCTAssertTrue(deletionOp.consumesReference)

        let softClipOp = CIGAROperation(op: .softClip, length: 5)
        XCTAssertFalse(softClipOp.consumesReference)
    }

    func testConsumesQuery() {
        let matchOp = CIGAROperation(op: .match, length: 10)
        XCTAssertTrue(matchOp.consumesQuery)

        let insertOp = CIGAROperation(op: .insertion, length: 5)
        XCTAssertTrue(insertOp.consumesQuery)

        let deletionOp = CIGAROperation(op: .deletion, length: 3)
        XCTAssertFalse(deletionOp.consumesQuery)
    }
}

// MARK: - AlignedRead Tests

final class AlignedReadTests: XCTestCase {

    private func makeRead(
        flag: UInt16 = 0,
        position: Int = 100,
        cigar: String = "100M",
        sequence: String = String(repeating: "A", count: 100),
        mapq: UInt8 = 60
    ) -> AlignedRead {
        AlignedRead(
            name: "read1",
            flag: flag,
            chromosome: "chr1",
            position: position,
            mapq: mapq,
            cigar: CIGAROperation.parse(cigar)!,
            sequence: sequence,
            qualities: Array(repeating: UInt8(30), count: sequence.count)
        )
    }

    func testAlignmentEnd() {
        let read = makeRead(position: 100, cigar: "75M")
        XCTAssertEqual(read.alignmentEnd, 175)
    }

    func testAlignmentEndWithDeletion() {
        let read = makeRead(position: 100, cigar: "50M5D50M")
        XCTAssertEqual(read.alignmentEnd, 205) // 50 + 5 + 50 = 105 ref bases
    }

    func testAlignmentEndWithInsertion() {
        // Insertion does not consume reference
        let read = makeRead(position: 100, cigar: "50M5I45M", sequence: String(repeating: "A", count: 100))
        XCTAssertEqual(read.alignmentEnd, 195) // 50 + 45 = 95 ref bases
    }

    func testReferenceLength() {
        let read = makeRead(cigar: "50M5I3D42M")
        XCTAssertEqual(read.referenceLength, 95) // 50 + 3 + 42 = 95
    }

    func testQueryLength() {
        let read = makeRead(cigar: "50M5I45M", sequence: String(repeating: "A", count: 100))
        XCTAssertEqual(read.queryLength, 100) // 50 + 5 + 45 = 100
    }

    func testFlagProperties() {
        // Forward read, first in pair, properly paired
        let forward = makeRead(flag: 0x3 | 0x40) // paired + proper pair + first
        XCTAssertTrue(forward.isPaired)
        XCTAssertTrue(forward.isProperPair)
        XCTAssertTrue(forward.isFirstInPair)
        XCTAssertFalse(forward.isReverse)
        XCTAssertFalse(forward.isDuplicate)
        XCTAssertEqual(forward.strand, .forward)

        // Reverse read, duplicate
        let reverse = makeRead(flag: 0x10 | 0x400)
        XCTAssertTrue(reverse.isReverse)
        XCTAssertTrue(reverse.isDuplicate)
        XCTAssertEqual(reverse.strand, .reverse)

        // Secondary and supplementary
        let secondary = makeRead(flag: 0x100)
        XCTAssertTrue(secondary.isSecondary)

        let supplementary = makeRead(flag: 0x800)
        XCTAssertTrue(supplementary.isSupplementary)
    }

    func testCigarString() {
        let read = makeRead(cigar: "50M2I3D45M")
        XCTAssertEqual(read.cigarString, "50M2I3D45M")
    }

    func testCigarStringEmpty() {
        let read = AlignedRead(
            name: "unmapped", flag: 4, chromosome: "*", position: 0,
            mapq: 0, cigar: [], sequence: "ACGT", qualities: [30, 30, 30, 30]
        )
        XCTAssertEqual(read.cigarString, "*")
    }

    func testForEachAlignedBase() {
        let read = makeRead(
            position: 100,
            cigar: "5M",
            sequence: "ACGTG"
        )

        var bases: [(Character, Int)] = []
        read.forEachAlignedBase { base, refPos, _ in
            bases.append((base, refPos))
        }

        XCTAssertEqual(bases.count, 5)
        XCTAssertEqual(bases[0].0, "A")
        XCTAssertEqual(bases[0].1, 100)
        XCTAssertEqual(bases[4].0, "G")
        XCTAssertEqual(bases[4].1, 104)
    }

    func testInsertions() {
        let read = makeRead(
            position: 100,
            cigar: "5M3I5M",
            sequence: "ACGTGAAACGTGG"
        )

        let insertions = read.insertions
        XCTAssertEqual(insertions.count, 1)
        XCTAssertEqual(insertions[0].position, 105)
        XCTAssertEqual(insertions[0].bases, "AAA")
    }

    func testMultipleInsertions() {
        let read = makeRead(
            position: 100,
            cigar: "3M2I3M1I2M",
            sequence: "ACGTTACGTCA"
        )

        let insertions = read.insertions
        XCTAssertEqual(insertions.count, 2)
        XCTAssertEqual(insertions[0].position, 103)
        XCTAssertEqual(insertions[0].bases, "TT")
        XCTAssertEqual(insertions[1].position, 106)
        XCTAssertEqual(insertions[1].bases, "T")
    }

    func testSendable() {
        let read = makeRead()
        let sendableCheck: @Sendable () -> String = { read.name }
        XCTAssertEqual(sendableCheck(), "read1")
    }

    // MARK: - Insert Size Classification

    private func makePairedRead(
        flag: UInt16 = 0x63,  // paired + proper pair + mate reverse + first in pair
        position: Int = 100,
        insertSize: Int = 400,
        mateChromosome: String? = nil,
        mapq: UInt8 = 60
    ) -> AlignedRead {
        // "=" means same chromosome — use default "chr1"
        let mateChr = mateChromosome ?? "chr1"
        return AlignedRead(
            name: "paired1",
            flag: flag,
            chromosome: "chr1",
            position: position,
            mapq: mapq,
            cigar: CIGAROperation.parse("100M")!,
            sequence: String(repeating: "A", count: 100),
            qualities: Array(repeating: UInt8(30), count: 100),
            mateChromosome: mateChr,
            matePosition: position + 200,
            insertSize: insertSize
        )
    }

    func testInsertSizeClassNormal() {
        // Default: expectedInsertSize=400, stdDev=100, stdDevs=3
        // Normal range: 400 - 300 = 100  to  400 + 300 = 700
        let read = makePairedRead(insertSize: 400)
        XCTAssertEqual(read.insertSizeClass(), .normal)

        // At boundaries
        let atLower = makePairedRead(insertSize: 100)
        XCTAssertEqual(atLower.insertSizeClass(), .normal)

        let atUpper = makePairedRead(insertSize: 700)
        XCTAssertEqual(atUpper.insertSizeClass(), .normal)
    }

    func testInsertSizeClassTooSmall() {
        // Below lower bound (100-1 = 99)
        let read = makePairedRead(insertSize: 99)
        XCTAssertEqual(read.insertSizeClass(), .tooSmall)

        let verySmall = makePairedRead(insertSize: 10)
        XCTAssertEqual(verySmall.insertSizeClass(), .tooSmall)
    }

    func testInsertSizeClassTooLarge() {
        // Above upper bound (700+1 = 701)
        let read = makePairedRead(insertSize: 701)
        XCTAssertEqual(read.insertSizeClass(), .tooLarge)

        let veryLarge = makePairedRead(insertSize: 5000)
        XCTAssertEqual(veryLarge.insertSizeClass(), .tooLarge)
    }

    func testInsertSizeClassInterchromosomal() {
        let read = makePairedRead(insertSize: 400, mateChromosome: "chr2")
        XCTAssertEqual(read.insertSizeClass(), .interchromosomal)
    }

    func testInsertSizeClassAbnormalOrientation() {
        // Both reads on forward strand: flag without 0x20 (mate reverse)
        // 0x43 = paired + proper pair + first in pair (mate is NOT reverse)
        let read = makePairedRead(flag: 0x43, insertSize: 400)
        XCTAssertFalse(read.isReverse)
        XCTAssertFalse(read.isMateReverse)
        XCTAssertEqual(read.insertSizeClass(), .abnormalOrientation)

        // Both reads on reverse strand: flag with 0x10 (reverse) AND 0x20 (mate reverse)
        // 0x73 = paired + proper pair + reverse + mate reverse + first in pair
        let bothReverse = makePairedRead(flag: 0x73, insertSize: 400)
        XCTAssertTrue(bothReverse.isReverse)
        XCTAssertTrue(bothReverse.isMateReverse)
        XCTAssertEqual(bothReverse.insertSizeClass(), .abnormalOrientation)
    }

    func testInsertSizeClassNotApplicableUnpaired() {
        // Not paired (flag=0 → isPaired=false)
        let read = makeRead(flag: 0)
        XCTAssertEqual(read.insertSizeClass(), .notApplicable)
    }

    func testInsertSizeClassNotApplicableMateUnmapped() {
        // Mate unmapped: flag 0x9 = paired + mate unmapped
        let read = makePairedRead(flag: 0x49) // paired + mate unmapped + first in pair
        XCTAssertTrue(read.isPaired)
        XCTAssertTrue(read.isMateUnmapped)
        XCTAssertEqual(read.insertSizeClass(), .notApplicable)
    }

    func testInsertSizeClassNotApplicableTLENZero() {
        // TLEN=0 means insert size not computable (SAM spec §1.4)
        let read = makePairedRead(insertSize: 0)
        XCTAssertEqual(read.insertSizeClass(), .notApplicable)
    }

    func testInsertSizeClassNegativeTLEN() {
        // Negative TLEN is normal for second-in-pair reads
        let read = makePairedRead(insertSize: -400)
        XCTAssertEqual(read.insertSizeClass(), .normal)

        let tooSmallNeg = makePairedRead(insertSize: -50)
        XCTAssertEqual(tooSmallNeg.insertSizeClass(), .tooSmall)
    }

    func testInsertSizeClassCustomParameters() {
        // Custom: expected=300, stdDev=50, stdDevs=2 → range 200-400
        let normalRead = makePairedRead(insertSize: 300)
        XCTAssertEqual(normalRead.insertSizeClass(expectedInsertSize: 300, stdDev: 50, stdDevs: 2), .normal)

        let tooLarge = makePairedRead(insertSize: 401)
        XCTAssertEqual(tooLarge.insertSizeClass(expectedInsertSize: 300, stdDev: 50, stdDevs: 2), .tooLarge)

        let tooSmall = makePairedRead(insertSize: 199)
        XCTAssertEqual(tooSmall.insertSizeClass(expectedInsertSize: 300, stdDev: 50, stdDevs: 2), .tooSmall)
    }

    // MARK: - Supplementary Alignment Parsing

    func testParsedSupplementaryAlignmentsSingle() {
        let read = AlignedRead(
            name: "split1", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: CIGAROperation.parse("100M")!,
            sequence: String(repeating: "A", count: 100), qualities: [],
            supplementaryAlignments: "chr2,5000,+,50M50S,40,2;"
        )

        let supps = read.parsedSupplementaryAlignments
        XCTAssertEqual(supps.count, 1)
        XCTAssertEqual(supps[0].chromosome, "chr2")
        XCTAssertEqual(supps[0].position, 4999) // 1-based 5000 → 0-based 4999
        XCTAssertEqual(supps[0].strand, .forward)
        XCTAssertEqual(supps[0].cigarString, "50M50S")
        XCTAssertEqual(supps[0].mapq, 40)
        XCTAssertEqual(supps[0].editDistance, 2)
    }

    func testParsedSupplementaryAlignmentsMultiple() {
        let read = AlignedRead(
            name: "split2", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: CIGAROperation.parse("100M")!,
            sequence: String(repeating: "A", count: 100), qualities: [],
            supplementaryAlignments: "chr2,5000,+,50M50S,40,2;chr3,10000,-,30M70S,20,5;"
        )

        let supps = read.parsedSupplementaryAlignments
        XCTAssertEqual(supps.count, 2)

        XCTAssertEqual(supps[0].chromosome, "chr2")
        XCTAssertEqual(supps[0].strand, .forward)

        XCTAssertEqual(supps[1].chromosome, "chr3")
        XCTAssertEqual(supps[1].position, 9999)
        XCTAssertEqual(supps[1].strand, .reverse)
        XCTAssertEqual(supps[1].mapq, 20)
        XCTAssertEqual(supps[1].editDistance, 5)
    }

    func testParsedSupplementaryAlignmentsNil() {
        let read = makeRead()
        XCTAssertTrue(read.parsedSupplementaryAlignments.isEmpty)
    }

    func testParsedSupplementaryAlignmentsMalformed() {
        // Too few fields
        let read = AlignedRead(
            name: "bad", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: CIGAROperation.parse("100M")!,
            sequence: String(repeating: "A", count: 100), qualities: [],
            supplementaryAlignments: "chr2,5000;bad_data;"
        )
        XCTAssertTrue(read.parsedSupplementaryAlignments.isEmpty)
    }

    func testParsedSupplementaryAlignmentsTrailingSemicolon() {
        // SA tag commonly has trailing semicolon — empty trailing segment should be skipped
        let read = AlignedRead(
            name: "trail", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: CIGAROperation.parse("100M")!,
            sequence: String(repeating: "A", count: 100), qualities: [],
            supplementaryAlignments: "chr2,5000,+,50M50S,40,2;"
        )
        XCTAssertEqual(read.parsedSupplementaryAlignments.count, 1)
    }

    func testHasSplitAlignments() {
        let withSA = AlignedRead(
            name: "split", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: CIGAROperation.parse("100M")!,
            sequence: String(repeating: "A", count: 100), qualities: [],
            supplementaryAlignments: "chr2,5000,+,50M50S,40,2;"
        )
        XCTAssertTrue(withSA.hasSplitAlignments)

        let withoutSA = makeRead()
        XCTAssertFalse(withoutSA.hasSplitAlignments)
    }

    // MARK: - Optional Tag Storage

    func testEditDistanceStorage() {
        let read = AlignedRead(
            name: "r1", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: CIGAROperation.parse("100M")!,
            sequence: String(repeating: "A", count: 100), qualities: [],
            editDistance: 3
        )
        XCTAssertEqual(read.editDistance, 3)
    }

    func testNumHitsStorage() {
        let read = AlignedRead(
            name: "r1", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: CIGAROperation.parse("100M")!,
            sequence: String(repeating: "A", count: 100), qualities: [],
            numHits: 5
        )
        XCTAssertEqual(read.numHits, 5)
    }

    func testStrandTagStorage() {
        let read = AlignedRead(
            name: "r1", flag: 0, chromosome: "chr1", position: 100,
            mapq: 60, cigar: CIGAROperation.parse("100M")!,
            sequence: String(repeating: "A", count: 100), qualities: [],
            strandTag: "+"
        )
        XCTAssertEqual(read.strandTag, "+")
    }
}
