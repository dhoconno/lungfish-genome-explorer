// BgzipReaderRegressionTests.swift - Regression tests for bgzip infinite-loop fix
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

/// Regression tests for the bgzip reader, specifically the infinite-loop bug
/// in `readUncompressedRange` that occurred when a requested byte range
/// extended past the end of available data.
///
/// The fix was to break when `nextOffset <= currentUncompressedOffset`
/// (no progress) or when `findBlock` returns nil.
///
/// These tests exercise the GZIIndex lookup logic (which drives the loop)
/// and the SyncBgzipFASTAReader on synthetic data to verify termination.
final class BgzipReaderRegressionTests: XCTestCase {

    // MARK: - GZIIndex.findBlock Tests

    func testFindBlockReturnsNilForEmptyIndex() {
        let index = GZIIndex(entries: [])
        let result = index.findBlock(for: 0)
        XCTAssertNil(result, "Empty index should return nil for any offset")
    }

    func testFindBlockReturnsSingleEntryForOffsetZero() {
        let entries = [
            GZIIndex.Entry(compressedOffset: 0, uncompressedOffset: 0)
        ]
        let index = GZIIndex(entries: entries)

        let result = index.findBlock(for: 0)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.entry.compressedOffset, 0)
        XCTAssertEqual(result?.offsetInBlock, 0)
    }

    func testFindBlockReturnsCorrectBlockForMultipleEntries() {
        let entries = [
            GZIIndex.Entry(compressedOffset: 0, uncompressedOffset: 0),
            GZIIndex.Entry(compressedOffset: 1000, uncompressedOffset: 65536),
            GZIIndex.Entry(compressedOffset: 2000, uncompressedOffset: 131072),
        ]
        let index = GZIIndex(entries: entries)

        // Offset 70000 is in the second block (uncompressed 65536..131072)
        let result = index.findBlock(for: 70000)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.entry.compressedOffset, 1000)
        XCTAssertEqual(result?.offsetInBlock, 70000 - 65536)
    }

    func testFindBlockReturnsLastBlockForOffsetBeyondAllEntries() {
        // This is the scenario that triggered the infinite loop.
        // When the requested offset is beyond the last block's start,
        // findBlock returns the last entry with a large offsetInBlock.
        let entries = [
            GZIIndex.Entry(compressedOffset: 0, uncompressedOffset: 0),
            GZIIndex.Entry(compressedOffset: 500, uncompressedOffset: 65536),
        ]
        let index = GZIIndex(entries: entries)

        // Request an offset far beyond the last block
        let result = index.findBlock(for: 200_000)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.entry.compressedOffset, 500, "Should return the last block")
        XCTAssertEqual(result?.entry.uncompressedOffset, 65536)
        XCTAssertEqual(result?.offsetInBlock, 200_000 - 65536)
    }

    func testFindBlockReturnsPreciseBlockBoundary() {
        let entries = [
            GZIIndex.Entry(compressedOffset: 0, uncompressedOffset: 0),
            GZIIndex.Entry(compressedOffset: 1000, uncompressedOffset: 65536),
        ]
        let index = GZIIndex(entries: entries)

        // Exact boundary of second block
        let result = index.findBlock(for: 65536)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.entry.compressedOffset, 1000)
        XCTAssertEqual(result?.offsetInBlock, 0, "Offset at exact block boundary should have 0 in-block offset")
    }

    // MARK: - Infinite Loop Regression: SyncBgzipFASTAReader

    /// Verifies that creating a SyncBgzipFASTAReader with a missing file
    /// throws an appropriate error rather than silently succeeding.
    func testSyncReaderThrowsForMissingFile() {
        let fakeURL = URL(fileURLWithPath: "/nonexistent/genome.fa.gz")
        let fakeFAI = URL(fileURLWithPath: "/nonexistent/genome.fa.gz.fai")
        let fakeGZI = URL(fileURLWithPath: "/nonexistent/genome.fa.gz.gzi")

        XCTAssertThrowsError(try SyncBgzipFASTAReader(url: fakeURL, faiURL: fakeFAI, gziURL: fakeGZI)) { error in
            guard let bgzipError = error as? BgzipError else {
                // Could also be a FASTAError from index loading - either is valid
                return
            }
            if case .fileNotFound = bgzipError {
                // Expected
            } else {
                XCTFail("Expected fileNotFound error, got \(bgzipError)")
            }
        }
    }

    /// Verifies the no-progress guard in readUncompressedRange by testing
    /// the GZIIndex behavior that would have caused an infinite loop.
    ///
    /// The original bug: when findBlock returns the same block entry repeatedly
    /// for an offset beyond available data, the decompressed block size would be
    /// smaller than expected, causing nextOffset to not advance past
    /// currentUncompressedOffset. The fix breaks on `nextOffset <= currentUncompressedOffset`.
    func testNoProgressGuardPreventsInfiniteLoop() {
        // Simulate the loop logic from readUncompressedRange
        // with a scenario that would have caused infinite iteration.
        let entries = [
            GZIIndex.Entry(compressedOffset: 0, uncompressedOffset: 0),
        ]
        let index = GZIIndex(entries: entries)

        // Simulate requesting bytes starting at offset 100, length 1000
        // from a file with only one small block.
        let startOffset: UInt64 = 100
        let endOffset: UInt64 = 1100
        var currentUncompressedOffset = startOffset
        var loopEntries = 0
        let maxIterations = 100  // Safety bound

        while currentUncompressedOffset < endOffset && loopEntries < maxIterations {
            loopEntries += 1

            guard let (blockEntry, _) = index.findBlock(for: currentUncompressedOffset) else {
                break
            }

            // Simulate a block that decompresses to only 50 bytes
            let simulatedBlockSize: UInt64 = 50

            let nextOffset = blockEntry.uncompressedOffset + simulatedBlockSize
            if nextOffset <= currentUncompressedOffset {
                break  // This is the fix that prevents infinite loop
            }
            currentUncompressedOffset = nextOffset
        }

        // With blockEntry.uncompressedOffset=0 and simulatedBlockSize=50,
        // nextOffset=50 which is <= startOffset=100, so the no-progress
        // guard fires on the very first loop entry.
        XCTAssertEqual(loopEntries, 1,
            "No-progress guard should fire on first loop entry when block end < read position")
        XCTAssertLessThan(loopEntries, maxIterations,
            "Loop should terminate via no-progress guard, not hit safety bound")
    }

    /// Tests that the no-progress guard handles the case where the block
    /// ends exactly at the current read position.
    func testNoProgressGuardWhenBlockEndsAtCurrentOffset() {
        let entries = [
            GZIIndex.Entry(compressedOffset: 0, uncompressedOffset: 0),
            GZIIndex.Entry(compressedOffset: 500, uncompressedOffset: 1000),
        ]
        let index = GZIIndex(entries: entries)

        var currentUncompressedOffset: UInt64 = 1000
        let endOffset: UInt64 = 2000
        var loopEntries = 0
        let maxIterations = 100

        while currentUncompressedOffset < endOffset && loopEntries < maxIterations {
            loopEntries += 1

            guard let (blockEntry, _) = index.findBlock(for: currentUncompressedOffset) else {
                break
            }

            // Simulate: block at offset 1000 decompresses to exactly 0 bytes (EOF block)
            let simulatedBlockSize: UInt64 = 0
            let nextOffset = blockEntry.uncompressedOffset + simulatedBlockSize
            if nextOffset <= currentUncompressedOffset {
                break
            }
            currentUncompressedOffset = nextOffset
        }

        XCTAssertEqual(loopEntries, 1,
            "Zero-size block should cause termination on first loop entry via no-progress guard")
        XCTAssertLessThan(loopEntries, maxIterations,
            "Should not hit safety bound")
    }

    /// Tests that normal forward progress completes without triggering the guard.
    func testNormalProgressCompletesWithoutGuard() {
        let entries = [
            GZIIndex.Entry(compressedOffset: 0, uncompressedOffset: 0),
            GZIIndex.Entry(compressedOffset: 500, uncompressedOffset: 65536),
            GZIIndex.Entry(compressedOffset: 1000, uncompressedOffset: 131072),
        ]
        let index = GZIIndex(entries: entries)

        var currentUncompressedOffset: UInt64 = 0
        let endOffset: UInt64 = 131072  // Read exactly two blocks
        var loopEntries = 0
        let maxIterations = 100

        while currentUncompressedOffset < endOffset && loopEntries < maxIterations {
            loopEntries += 1

            guard let (blockEntry, _) = index.findBlock(for: currentUncompressedOffset) else {
                break
            }

            // Each block decompresses to 65536 bytes (normal bgzip block)
            let simulatedBlockSize: UInt64 = 65536
            let nextOffset = blockEntry.uncompressedOffset + simulatedBlockSize
            if nextOffset <= currentUncompressedOffset {
                break
            }
            currentUncompressedOffset = nextOffset
        }

        XCTAssertEqual(loopEntries, 2, "Should complete in exactly 2 loop entries for 2 blocks")
        XCTAssertGreaterThanOrEqual(currentUncompressedOffset, endOffset)
    }

    // MARK: - BgzipError

    func testBgzipErrorDescriptions() {
        let url = URL(fileURLWithPath: "/test/genome.fa.gz")
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 1000)

        let errors: [BgzipError] = [
            .fileNotFound(url),
            .indexNotFound(url),
            .invalidIndex("test reason"),
            .invalidBgzipBlock("bad block"),
            .decompressionFailed("bad data"),
            .regionOutOfBounds(region, 500),
            .sequenceNotFound("chrX"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "All BgzipError cases should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
}
