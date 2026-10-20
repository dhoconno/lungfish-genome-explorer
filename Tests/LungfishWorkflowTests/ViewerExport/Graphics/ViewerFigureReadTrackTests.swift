// ViewerFigureReadTrackTests.swift - The read track builder's items, sample and omissions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishWorkflow

/// In-memory reads for the read track's unit and golden cases.
enum ViewerFigureReadFixture {
    static func read(
        _ name: String, _ position: Int, length: Int = 100, reverse: Bool = false, mapq: UInt8 = 60,
        cigar: String? = nil, md: String? = nil
    ) -> AlignedRead {
        let operations = CIGAROperation.parse(cigar ?? "\(length)M") ?? []
        let readLength = operations.filter(\.consumesQuery).reduce(0) { $0 + $1.length }
        return AlignedRead(
            name: name, flag: reverse ? 16 : 0, chromosome: "chr1", position: position, mapq: mapq, cigar: operations,
            sequence: String(repeating: "A", count: readLength), qualities: Array(repeating: 30, count: readLength), mdTag: md
        )
    }

    /// A forward read with a mismatch at 60, a reverse read, a read with a deletion at 340 to
    /// 350 and a soft clip, an insertion read, and three reads stacked past a two-row cap.
    static var packed: [AlignedRead] {
        [
            read("fwd", 10, md: "50T49"), read("rev", 50, reverse: true, mapq: 25),
            read("del", 300, cigar: "5S35M10D60M"), read("ins", 500, cigar: "50M3I47M"),
            read("stack1", 700), read("stack2", 710), read("stack3", 720, reverse: true),
        ]
    }
}

final class ViewerFigureReadTrackTests: XCTestCase {
    private typealias Fixture = ViewerFigureReadFixture

    private func draw(
        _ reads: [AlignedRead], end: Double = 1_000, height: Double = 100,
        options: ViewerFigureReadTrack.Options = .init()
    ) throws -> ViewerFigureCanvas {
        let frame = ViewerFigureFrame(chromosome: "chr1", start: 0, end: end, pixelWidth: 1_000)
        var canvas = ViewerFigureCanvas()
        try ViewerFigureReadTrack(source: nil, height: height, options: options)
            .draw(reads, into: &canvas, frame: frame, area: ViewerFigureRect(x: 0, y: 0, width: 1_000, height: height))
        return canvas
    }

    private func fills(_ canvas: ViewerFigureCanvas, _ role: ViewerFigureColorRole) -> [ViewerFigureRect] {
        canvas.items.compactMap { if case .fill(let rect, let paint) = $0, paint.role == role { rect } else { nil } }
    }

    func testPackedReadsDrawPointedBodiesTicksAndIndelsInRoles() throws {
        let canvas = try draw(Fixture.packed)
        XCTAssertEqual(fills(canvas, .forwardRead).first, ViewerFigureRect(x: 10, y: 0, width: 97, height: 6), "the body stops at the 3-point tip")
        XCTAssertTrue(canvas.items.contains(.strokeSegments(segments: [
            ViewerFigureSegment(from: ViewerFigurePoint(x: 10, y: 0), to: ViewerFigurePoint(x: 107, y: 0)),
            ViewerFigureSegment(from: ViewerFigurePoint(x: 107, y: 0), to: ViewerFigurePoint(x: 110, y: 3)),
            ViewerFigureSegment(from: ViewerFigurePoint(x: 110, y: 3), to: ViewerFigurePoint(x: 107, y: 6)),
            ViewerFigureSegment(from: ViewerFigurePoint(x: 107, y: 6), to: ViewerFigurePoint(x: 10, y: 6)),
            ViewerFigureSegment(from: ViewerFigurePoint(x: 10, y: 6), to: ViewerFigurePoint(x: 10, y: 0)),
        ], lineWidth: 0.5, paint: ViewerFigurePaint(.forwardReadStroke, alpha: 1))), "the live pentagon's outline")
        XCTAssertTrue(canvas.items.contains(.fill(
            rect: ViewerFigureRect(x: 53, y: 7, width: 97, height: 6), paint: ViewerFigurePaint(.reverseRead, alpha: 0.7)
        )), "a reverse read in row 1, MAPQ 25 at alpha 0.7")
        XCTAssertEqual(fills(canvas, .readBaseA), [ViewerFigureRect(x: 60, y: 0, width: 1, height: 6)], "the MD tag's mismatch")
        let dashes = canvas.items.compactMap { item -> [ViewerFigureSegment]? in
            if case .strokeSegments(let segments, _, let paint) = item, paint.role == .deletion { segments } else { nil }
        }
        XCTAssertEqual(dashes.first?.map(\.from.x), [335, 339, 343], "the live 2-point dash over 335 to 345")
        XCTAssertEqual(fills(canvas, .softClip).first, ViewerFigureRect(x: 295, y: 0, width: 5, height: 6))
        XCTAssertEqual(fills(canvas, .insertion).first?.x, 549.5)
        XCTAssertTrue(canvas.omissions.isEmpty)
    }

    func testRowCapRecordsTheOverflowAndDrawsTheLiveLine() throws {
        var options = ViewerFigureReadTrack.Options()
        options.maxRows = 2
        let canvas = try draw(Fixture.packed, options: options)
        XCTAssertEqual(canvas.omissions, [ViewerFigureOmission(trackID: "reads", kind: .readRowCap, reason: "max 2 rows", count: 1)])
        XCTAssertEqual(fills(canvas, .quaternarySystemFill), [ViewerFigureRect(x: 0, y: 84, width: 1_000, height: 16)])
        guard case .text(let line) = canvas.items.last else { return XCTFail("the overflow line comes last") }
        XCTAssertEqual(line.string, "+1 reads not shown (max 2 rows)")
        XCTAssertEqual(line.anchor, .baselineCenter)
        XCTAssertEqual(line.fontName, "HelveticaNeue")
        XCTAssertEqual(line.paint, ViewerFigurePaint(.label))
    }

    func testTrackHeightCoverageTierBaseTierAndNarrowReadsAreCounted() throws {
        let short = try draw(Fixture.packed, height: 10)
        XCTAssertEqual(short.omissions, [ViewerFigureOmission(
            trackID: "reads", kind: .readRowCap, reason: "rows past the track height of 10 points", count: 3
        )])
        let coverage = try draw(Fixture.packed, end: 10_000)
        XCTAssertTrue(coverage.items.isEmpty)
        XCTAssertEqual(coverage.omissions, [ViewerFigureOmission(
            trackID: "reads", kind: .scaleMode, reason: "reads drawn as coverage above 2 bases per point", count: 7
        )])
        let base = try draw([Fixture.read("b", 10)], end: 400)
        XCTAssertEqual(fills(base, .forwardRead).first?.height, 14, "base-tier rows")
        XCTAssertEqual(base.omissions, [ViewerFigureOmission(
            trackID: "reads", kind: .labelsOmitted, reason: "base letters of the base tier", count: 1
        )])
        let narrow = try draw([Fixture.read("n", 10, length: 3)], end: 1_900)
        XCTAssertTrue(narrow.items.isEmpty)
        XCTAssertEqual(narrow.omissions, [ViewerFigureOmission(
            trackID: "reads", kind: .scaleMode, reason: "reads narrower than 2 points", count: 1
        )])
    }

    func testOverflowBarNeverCoversDrawnReads() throws {
        var options = ViewerFigureReadTrack.Options()
        options.maxRows = 75
        let canvas = try draw((0..<80).map { Fixture.read("r\($0)", 100) }, height: 100, options: options)
        let bodies = fills(canvas, .forwardRead)
        XCTAssertFalse(bodies.isEmpty)
        XCTAssertTrue(bodies.allSatisfy { $0.y + $0.height <= 84 }, "the overflow bar fills the last 16 of the 100 points")
        XCTAssertEqual(fills(canvas, .quaternarySystemFill), [ViewerFigureRect(x: 0, y: 84, width: 1_000, height: 16)])
    }

    func testSourceMapsTheReferenceNameToTheAlignmentContig() {
        let plain = ViewerFigureReadTrack.Source(alignmentPath: "a.bam", indexPath: "a.bam.bai")
        XCTAssertEqual(plain.alignmentChromosome(for: "chr1"), "chr1", "with no map the name is handed over unchanged")
        let mapped = ViewerFigureReadTrack.Source(alignmentPath: "a.bam", indexPath: "a.bam.bai", chromosomeAliases: ["chr1": "1"])
        XCTAssertEqual(mapped.alignmentChromosome(for: "chr1"), "1", "the live view's reference to alignment contig map")
        XCTAssertEqual(mapped.alignmentChromosome(for: "chr2"), "chr2", "a name outside the map stays")
    }

    func testFigureReadSampleIsTheSameInTwoRenders() throws {
        let reads = (0..<6_000).map { Fixture.read("r\($0)", ($0 * 7) % 900, length: 50, reverse: $0 % 3 == 0) }
        let first = ViewerFigureReadSample.sample(reads, maxReads: 5_000)
        let second = ViewerFigureReadSample.sample(reads, maxReads: 5_000)
        XCTAssertEqual(first.reads.map(\.name), second.reads.map(\.name))
        XCTAssertEqual(first.totalCount, 6_000)
        XCTAssertEqual(first.reads.filter(\.isReverse).count, 1_667, "the reverse strand's share, 5000 less 3333")
        XCTAssertNotEqual(first.reads.map(\.name), Array(reads.prefix(5_000)).sorted { $0.position < $1.position }.map(\.name))
        // The pin reads ids, so it does not depend on the order of ties in the final sort by position.
        let ids = first.reads.compactMap { Int($0.name.dropFirst()) }
        XCTAssertEqual(ids.count, 5_000)
        XCTAssertEqual(ids.reduce(0, +), 14_922_406, "the sum of the sampled read ids, taken from a run kept in build/lane/")
        XCTAssertEqual(Array(ids.sorted().prefix(8)), [0, 1, 2, 3, 4, 5, 8, 14], "the eight smallest sampled read ids")
        let canvasA = try draw(reads, height: 600)
        let canvasB = try draw(reads, height: 600)
        XCTAssertEqual(canvasA.items, canvasB.items)
        XCTAssertEqual(canvasA.omissions.first, ViewerFigureOmission(
            trackID: "reads", kind: .readSample, reason: ViewerFigureReadSample.rule(maxReads: 5_000), count: 1_000
        ))
        XCTAssertEqual(ViewerFigureReadSample.rule(maxReads: 5_000),
                       "max 5000 reads, a SplitMix64 reservoir sample within each strand, seed 0x5EED1329")
    }
}
