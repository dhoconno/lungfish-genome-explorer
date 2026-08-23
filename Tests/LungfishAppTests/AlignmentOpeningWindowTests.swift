// AlignmentOpeningWindowTests.swift - BAM viewers open at full contig width
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

/// Every BAM viewer opens showing the whole contig, so reads mapped anywhere on
/// the reference are visible before the user zooms. Plain reference bundles
/// (no alignments) keep the zoomed-in 10 kb opening window.
@MainActor
final class AlignmentOpeningWindowTests: XCTestCase {
    func testDetachedAlignmentOpensAtFullContigWidth() {
        let frame = ViewerViewController.initialDetachedReferenceFrame(
            contigName: "NC_001806.2",
            contigLength: 152_222,
            pixelWidth: 1_000
        )
        XCTAssertEqual(frame.chromosome, "NC_001806.2")
        XCTAssertEqual(frame.start, 0)
        XCTAssertEqual(frame.end, 152_222)
        XCTAssertEqual(frame.sequenceLength, 152_222)
    }

    func testDetachedAlignmentToleratesZeroLengthContig() {
        let frame = ViewerViewController.initialDetachedReferenceFrame(
            contigName: "empty", contigLength: 0, pixelWidth: 800
        )
        XCTAssertGreaterThan(frame.end, frame.start)
    }

    func testBundleWithAlignmentTracksOpensAtFullChromosome() {
        XCTAssertEqual(
            ViewerViewController.initialBundleWindowLength(chromosomeLength: 29_903, hasAlignmentTracks: true),
            29_903
        )
        XCTAssertEqual(
            ViewerViewController.initialBundleWindowLength(chromosomeLength: 5_000_000, hasAlignmentTracks: true),
            5_000_000
        )
    }

    func testBundleWithoutAlignmentTracksKeepsTenKilobaseWindow() {
        XCTAssertEqual(
            ViewerViewController.initialBundleWindowLength(chromosomeLength: 5_000_000, hasAlignmentTracks: false),
            10_000
        )
        XCTAssertEqual(
            ViewerViewController.initialBundleWindowLength(chromosomeLength: 4_000, hasAlignmentTracks: false),
            4_000
        )
    }
}
