// AnnotationCoordinateTransformTests.swift - Tests for extraction coordinate transformation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class AnnotationCoordinateTransformTests: XCTestCase {

    // MARK: - Simple Annotation, No RC

    func testFullyContainedNoRC() {
        let record = AnnotationDatabaseRecord(
            name: "gene1", type: "gene", chromosome: "chr1",
            start: 500, end: 800, strand: "+"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: false, newChromosome: "extracted"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.chromosome, "extracted")
        XCTAssertEqual(result?.start, 100)  // 500 - 400
        XCTAssertEqual(result?.end, 400)    // 800 - 400
        XCTAssertEqual(result?.strand, "+")
        XCTAssertEqual(result?.name, "gene1")
        XCTAssertEqual(result?.type, "gene")
    }

    func testClippedAtStartNoRC() {
        let record = AnnotationDatabaseRecord(
            name: "gene2", type: "CDS", chromosome: "chr1",
            start: 300, end: 600, strand: "+"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: false, newChromosome: "extracted"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 0)    // clipped to extractionStart
        XCTAssertEqual(result?.end, 200)    // 600 - 400
    }

    func testClippedAtEndNoRC() {
        let record = AnnotationDatabaseRecord(
            name: "gene3", type: "gene", chromosome: "chr1",
            start: 900, end: 1200, strand: "-"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: false, newChromosome: "extracted"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 500)  // 900 - 400
        XCTAssertEqual(result?.end, 600)    // clipped to seqLength (1000 - 400)
        XCTAssertEqual(result?.strand, "-")
    }

    func testFullyOutsideReturnsNil() {
        let record = AnnotationDatabaseRecord(
            name: "gene4", type: "gene", chromosome: "chr1",
            start: 100, end: 300, strand: "+"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: false, newChromosome: "extracted"
        )
        XCTAssertNil(result)
    }

    func testFullyOutsideAfterEndReturnsNil() {
        let record = AnnotationDatabaseRecord(
            name: "gene5", type: "gene", chromosome: "chr1",
            start: 1100, end: 1500, strand: "+"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: false, newChromosome: "extracted"
        )
        XCTAssertNil(result)
    }

    func testExactlyAtBoundary() {
        // Annotation ends exactly at extractionStart — no overlap
        let record1 = AnnotationDatabaseRecord(
            name: "boundary1", type: "gene", chromosome: "chr1",
            start: 300, end: 400, strand: "+"
        )
        XCTAssertNil(record1.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: false, newChromosome: "ext"
        ))

        // Annotation starts exactly at extractionEnd — no overlap
        let record2 = AnnotationDatabaseRecord(
            name: "boundary2", type: "gene", chromosome: "chr1",
            start: 1000, end: 1200, strand: "+"
        )
        XCTAssertNil(record2.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: false, newChromosome: "ext"
        ))
    }

    // MARK: - Simple Annotation, With RC

    func testFullyContainedWithRC() {
        // Extraction region [400, 1000), seqLength = 600
        // Annotation at [500, 800) on "+"
        // RC: newStart = 1000 - 800 = 200, newEnd = 1000 - 500 = 500
        let record = AnnotationDatabaseRecord(
            name: "gene1", type: "gene", chromosome: "chr1",
            start: 500, end: 800, strand: "+"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: true, newChromosome: "extracted"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 200)
        XCTAssertEqual(result?.end, 500)
        XCTAssertEqual(result?.strand, "-")  // flipped
    }

    func testRCStrandFlipReverse() {
        let record = AnnotationDatabaseRecord(
            name: "gene1", type: "CDS", chromosome: "chr1",
            start: 500, end: 800, strand: "-"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: true, newChromosome: "extracted"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.strand, "+")  // "-" becomes "+"
    }

    func testRCStrandDotUnchanged() {
        let record = AnnotationDatabaseRecord(
            name: "gene1", type: "gene", chromosome: "chr1",
            start: 500, end: 800, strand: "."
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: true, newChromosome: "extracted"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.strand, ".")  // unchanged
    }

    func testRCWithClipping() {
        // Annotation [300, 600) on "+", extraction [400, 1000)
        // Clipped to [400, 600), then RC:
        // newStart = 1000 - 600 = 400, newEnd = 1000 - 400 = 600
        let record = AnnotationDatabaseRecord(
            name: "gene2", type: "gene", chromosome: "chr1",
            start: 300, end: 600, strand: "+"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: true, newChromosome: "extracted"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 400)
        XCTAssertEqual(result?.end, 600)
        XCTAssertEqual(result?.strand, "-")
    }

    // MARK: - Multi-Block, No RC

    func testMultiBlockFullyContainedNoRC() {
        // Annotation start=500, blocks at relative [0, 200, 500], sizes [100, 100, 100]
        // Absolute blocks: [500-600, 700-800, 1000-1100]
        // Extraction [400, 1200), shift by -400
        // New blocks: [100-200, 300-400, 600-700]
        let record = AnnotationDatabaseRecord(
            name: "mRNA1", type: "mRNA", chromosome: "chr1",
            start: 500, end: 1100, strand: "+",
            blockCount: 3, blockSizes: "100,100,100,", blockStarts: "0,200,500,"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1200,
            isReverseComplement: false, newChromosome: "extracted"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 100)
        XCTAssertEqual(result?.end, 700)
        XCTAssertEqual(result?.blockCount, 3)

        // Verify block sizes (unchanged since fully contained)
        let sizes = result?.blockSizes?.split(separator: ",").compactMap { Int($0) }
        XCTAssertEqual(sizes, [100, 100, 100])

        // Verify block starts relative to new start (100)
        let starts = result?.blockStarts?.split(separator: ",").compactMap { Int($0) }
        XCTAssertEqual(starts, [0, 200, 500])
    }

    func testMultiBlockWithBlockClippingNoRC() {
        // Annotation start=300, blocks at relative [0, 200, 500], sizes [100, 100, 100]
        // Absolute blocks: [300-400, 500-600, 800-900]
        // Extraction [400, 850)
        // Block 1 [300-400]: fully outside -> dropped
        // Block 2 [500-600]: fully inside -> [100, 200)
        // Block 3 [800-900]: clipped to [800, 850) -> [400, 450)
        let record = AnnotationDatabaseRecord(
            name: "mRNA2", type: "mRNA", chromosome: "chr1",
            start: 300, end: 900, strand: "+",
            blockCount: 3, blockSizes: "100,100,100,", blockStarts: "0,200,500,"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 850,
            isReverseComplement: false, newChromosome: "extracted"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 100)
        XCTAssertEqual(result?.end, 450)
        XCTAssertEqual(result?.blockCount, 2)

        let sizes = result?.blockSizes?.split(separator: ",").compactMap { Int($0) }
        XCTAssertEqual(sizes, [100, 50])

        let starts = result?.blockStarts?.split(separator: ",").compactMap { Int($0) }
        XCTAssertEqual(starts, [0, 300])
    }

    func testMultiBlockAllBlocksClippedReturnsNil() {
        // Annotation start=100, blocks at [0, 50], sizes [30, 30]
        // Absolute blocks: [100-130, 150-180]
        // Extraction [400, 1000) -> all blocks fully outside
        let record = AnnotationDatabaseRecord(
            name: "mRNA3", type: "mRNA", chromosome: "chr1",
            start: 100, end: 180, strand: "+",
            blockCount: 2, blockSizes: "30,30,", blockStarts: "0,50,"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: false, newChromosome: "extracted"
        )
        XCTAssertNil(result)
    }

    // MARK: - Multi-Block, With RC

    func testMultiBlockWithRC() {
        // Annotation start=500, blocks at [0, 200, 500], sizes [100, 100, 100]
        // Absolute blocks: [500-600, 700-800, 1000-1100]
        // Extraction [400, 1200), seqLength=800
        //
        // RC transform:
        // Block 1 [500-600]: newStart=1200-600=600, newEnd=1200-500=700 -> [600, 700)
        // Block 2 [700-800]: newStart=1200-800=400, newEnd=1200-700=500 -> [400, 500)
        // Block 3 [1000-1100]: newStart=1200-1100=100, newEnd=1200-1000=200 -> [100, 200)
        // Reversed order: [100-200, 400-500, 600-700]
        let record = AnnotationDatabaseRecord(
            name: "mRNA1", type: "mRNA", chromosome: "chr1",
            start: 500, end: 1100, strand: "+",
            blockCount: 3, blockSizes: "100,100,100,", blockStarts: "0,200,500,"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1200,
            isReverseComplement: true, newChromosome: "extracted"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, 100)
        XCTAssertEqual(result?.end, 700)
        XCTAssertEqual(result?.strand, "-")
        XCTAssertEqual(result?.blockCount, 3)

        let sizes = result?.blockSizes?.split(separator: ",").compactMap { Int($0) }
        XCTAssertEqual(sizes, [100, 100, 100])

        // Block starts relative to newStart=100: [0, 300, 500]
        let starts = result?.blockStarts?.split(separator: ",").compactMap { Int($0) }
        XCTAssertEqual(starts, [0, 300, 500])
    }

    // MARK: - Attributes and Metadata Preservation

    func testAttributesPreserved() {
        let record = AnnotationDatabaseRecord(
            name: "gene1", type: "CDS", chromosome: "chr1",
            start: 500, end: 800, strand: "+",
            attributes: "gene=ABC1;product=some%20protein",
            geneName: "ABC1"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: false, newChromosome: "extracted"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.attributes, "gene=ABC1;product=some%20protein")
        XCTAssertEqual(result?.geneName, "ABC1")
    }

    // MARK: - Single Block Becomes No-Block After Transform

    func testSingleBlockNoBlockFields() {
        let record = AnnotationDatabaseRecord(
            name: "exon1", type: "exon", chromosome: "chr1",
            start: 500, end: 600, strand: "+"
        )
        let result = record.transformed(
            extractionStart: 400, extractionEnd: 1000,
            isReverseComplement: false, newChromosome: "extracted"
        )
        XCTAssertNotNil(result)
        XCTAssertNil(result?.blockCount)
        XCTAssertNil(result?.blockSizes)
        XCTAssertNil(result?.blockStarts)
    }

    // MARK: - toBED12PlusLine

    func testToBED12PlusLineSimple() {
        let record = AnnotationDatabaseRecord(
            name: "gene1", type: "gene", chromosome: "extracted",
            start: 100, end: 400, strand: "+"
        )
        let line = record.toBED12PlusLine()
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 14)
        XCTAssertEqual(fields[0], "extracted")  // chrom
        XCTAssertEqual(fields[1], "100")        // start
        XCTAssertEqual(fields[2], "400")        // end
        XCTAssertEqual(fields[3], "gene1")      // name
        XCTAssertEqual(fields[5], "+")          // strand
        XCTAssertEqual(fields[9], "1")          // blockCount
        XCTAssertEqual(fields[12], "gene")      // type
    }

    func testToBED12PlusLineMultiBlock() {
        let record = AnnotationDatabaseRecord(
            name: "mRNA1", type: "mRNA", chromosome: "extracted",
            start: 100, end: 700, strand: "-",
            attributes: "gene=ABC1",
            blockCount: 3, blockSizes: "100,100,100,", blockStarts: "0,300,500,"
        )
        let line = record.toBED12PlusLine()
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(fields[9], "3")                  // blockCount
        XCTAssertEqual(fields[10], "100,100,100,")      // blockSizes
        XCTAssertEqual(fields[11], "0,300,500,")        // blockStarts
        XCTAssertEqual(fields[12], "mRNA")              // type
        XCTAssertEqual(fields[13], "gene=ABC1")         // attributes
    }
}
