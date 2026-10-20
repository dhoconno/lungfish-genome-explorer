// AnnotationPackingPinTests.swift - The live annotation row packing on fixed annotations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.29 M3 (QA 1). Pinned at 9aec9f971, before the figure's annotation track builder
// copied the packing, so the copy is held to what the live view did and not to itself.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore

/// Annotations the pins and the figure parity test share, in two tracks. The repeat track is
/// met first, so the discovered track order puts it first.
enum AnnotationPackingFixture {
    static let chromosome = "chr1"

    static func annotation(
        _ name: String, _ type: AnnotationType, _ start: Int, _ end: Int, track: String,
        strand: Strand = .forward
    ) -> SequenceAnnotation {
        SequenceAnnotation(
            type: type, name: name, chromosome: chromosome, start: start, end: end, strand: strand,
            qualifiers: ["annotation_db_track_id": AnnotationQualifier(track)]
        )
    }

    static var genes: [SequenceAnnotation] {
        [
            annotation("geneB", .gene, 100, 300, track: "genes", strand: .reverse),
            annotation("rs1", .snp, 150, 151, track: "genes"),
            annotation("geneA", .gene, 10, 200, track: "genes"),
            annotation("tx1", .mRNA, 400, 600, track: "genes"),
            annotation("cdsX", .cds, 250, 260, track: "genes"),
            annotation("geneZ", .gene, 700, 800, track: "genes"),
            annotation("geneY", .gene, 700, 800, track: "genes"),
        ]
    }

    static var repeats: [SequenceAnnotation] {
        [
            annotation("rep2", .repeatRegion, 60, 90, track: "repeats", strand: .unknown),
            annotation("rep1", .repeatRegion, 50, 500, track: "repeats", strand: .unknown),
        ]
    }

    /// Both tracks, the repeat track met first.
    static var all: [SequenceAnnotation] {
        [repeats[0]] + genes + [repeats[1]]
    }

    static func names(_ rows: [[SequenceAnnotation]]) -> [[String]] {
        rows.map { $0.map(\.name) }
    }
}

@MainActor
final class AnnotationPackingPinTests: XCTestCase {
    private typealias Fixture = AnnotationPackingFixture

    private func frame(width: Int = 1_000) -> ReferenceFrame {
        ReferenceFrame(chromosome: Fixture.chromosome, start: 0, end: 1_000, pixelWidth: width, sequenceLength: 1_000)
    }

    private func viewer() -> SequenceViewerView {
        SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 300))
    }

    func testTrackOrderFollowsTheFirstAnnotationOfEachTrack() {
        XCTAssertEqual(viewer().debugPackedAnnotationTrackIDs(Fixture.all, frame: frame()), ["repeats", "genes"])
        XCTAssertEqual(viewer().debugPackedAnnotationTrackIDs(Fixture.genes + Fixture.repeats, frame: frame()), ["genes", "repeats"])
    }

    func testLayeredRowsStackTracksAndPutVariantsBeneathLandmarks() {
        let packed = viewer().packAnnotationsLayered(Fixture.all, frame: frame())
        XCTAssertEqual(Fixture.names(packed.rows), [
            ["rep1"], ["rep2"],
            ["geneA", "cdsX", "tx1", "geneY"], ["geneB", "geneZ"], ["rs1"],
        ])
        XCTAssertEqual(packed.overflow, 0)
    }

    func testRowCapCountsLandmarksAndVariantsLeftOut() {
        let view = viewer()
        let two = view.packAnnotationsLayeredWithinTrack(Fixture.genes, frame: frame(), maxRows: 2)
        XCTAssertEqual(Fixture.names(two.rows), [["geneA", "cdsX", "tx1", "geneY"], ["geneB", "geneZ"]])
        XCTAssertEqual(two.overflow, 1)
        let one = view.packAnnotationsLayeredWithinTrack(Fixture.genes, frame: frame(), maxRows: 1)
        XCTAssertEqual(Fixture.names(one.rows), [["geneA", "cdsX", "tx1", "geneY"]])
        XCTAssertEqual(one.overflow, 3)
        let none = view.packAnnotationsLayeredWithinTrack(Fixture.genes, frame: frame(), maxRows: 0)
        XCTAssertEqual(none.rows.count, 0)
        XCTAssertEqual(none.overflow, 7)
    }

    func testPixelPackingKeepsATwoPointGapAndAThreePointMinimum() {
        // At 100 points a point holds more than 10 bases, and the one-base rs1 still takes three
        // points, so it cannot share a row with geneA or geneB. One list packs every type.
        let packed = viewer().packAnnotationsPixelBased(Fixture.genes, frame: frame(width: 100), maxRows: 5)
        XCTAssertEqual(Fixture.names(packed.rows), [
            ["geneA", "cdsX", "tx1", "geneY"], ["geneB", "geneZ"], ["rs1"],
        ])
        XCTAssertEqual(packed.overflow, 0)
    }
}
