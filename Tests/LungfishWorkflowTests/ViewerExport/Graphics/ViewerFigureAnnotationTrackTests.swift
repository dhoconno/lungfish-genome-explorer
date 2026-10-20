// ViewerFigureAnnotationTrackTests.swift - The annotation track builder's items and omissions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishWorkflow

final class ViewerFigureAnnotationTrackTests: XCTestCase {
    private func feature(
        _ name: String, _ type: AnnotationType, _ start: Int, _ end: Int, strand: Strand = .forward
    ) -> SequenceAnnotation {
        SequenceAnnotation(type: type, name: name, chromosome: "chr1", start: start, end: end, strand: strand)
    }

    private var genes: [SequenceAnnotation] {
        [
            feature("geneA", .gene, 10, 200), feature("geneB", .gene, 100, 300, strand: .reverse),
            feature("rs1", .snp, 150, 151), feature("cdsX", .cds, 250, 260), feature("tx1", .mRNA, 400, 600),
        ]
    }

    private func draw(
        _ annotations: [SequenceAnnotation], end: Double = 1_000, height: Double = 200,
        options: ViewerFigureAnnotationTrack.Options = .init()
    ) throws -> ViewerFigureCanvas {
        let frame = ViewerFigureFrame(chromosome: "chr1", start: 0, end: end, pixelWidth: 1_000)
        let track = ViewerFigureAnnotationTrack(sources: [], height: height, options: options)
        var canvas = ViewerFigureCanvas()
        try track.draw(annotations, into: &canvas, frame: frame, area: ViewerFigureRect(x: 0, y: 10, width: 1_000, height: height))
        return canvas
    }

    private func texts(_ canvas: ViewerFigureCanvas) -> [ViewerFigureText] {
        canvas.items.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    func testExpandedRowsDrawBoxesLabelsAndArrowsInRoles() throws {
        let canvas = try draw(genes)
        XCTAssertEqual(texts(canvas).map(\.string), ["geneA", "tx1", "geneB"], "row by row, and cdsX is 10 points wide, under 72")
        XCTAssertEqual(Set(texts(canvas).map(\.fontName)), ["HelveticaNeue"])
        XCTAssertEqual(texts(canvas).first?.paint, ViewerFigurePaint(.text))
        XCTAssertEqual(texts(canvas).first?.point.x, 12, "two points inside the box")
        XCTAssertTrue(canvas.items.contains(.fill(
            rect: ViewerFigureRect(x: 10, y: 10, width: 190, height: 16), paint: ViewerFigurePaint(.annotationGene, alpha: 0.7)
        )))
        XCTAssertTrue(canvas.items.contains(.strokeRect(
            rect: ViewerFigureRect(x: 10, y: 10, width: 190, height: 16), lineWidth: 1, paint: ViewerFigurePaint(.annotationGene)
        )))
        XCTAssertTrue(canvas.items.contains(.strokeSegments(segments: [
            ViewerFigureSegment(from: ViewerFigurePoint(x: 194, y: 16), to: ViewerFigurePoint(x: 198, y: 18)),
            ViewerFigureSegment(from: ViewerFigurePoint(x: 198, y: 18), to: ViewerFigurePoint(x: 194, y: 20)),
        ], lineWidth: 1, paint: ViewerFigurePaint(.text, alpha: 0.5))), "the forward arrow at the right end")
        XCTAssertEqual(canvas.omissions, [
            ViewerFigureOmission(trackID: "annotations", kind: .labelsOmitted, reason: "narrower than 72 points or more than 12 rows", count: 1),
            ViewerFigureOmission(trackID: "annotations", kind: .trackNotDrawn, reason: "embedded CDS translations", count: 1),
        ])
    }

    func testRowCapAndTrackHeightAreCountedAsLeftOut() throws {
        var options = ViewerFigureAnnotationTrack.Options()
        options.maxRows = 1
        let capped = try draw(genes, options: options)
        XCTAssertEqual(capped.omissions.first, ViewerFigureOmission(trackID: "annotations", kind: .annotationLimit, reason: "max 1 rows", count: 2))
        XCTAssertEqual(texts(capped).last?.string, "+2 more features")
        let short = try draw(genes, height: 20)
        XCTAssertEqual(short.omissions.first, ViewerFigureOmission(
            trackID: "annotations", kind: .annotationLimit, reason: "rows past the track height of 20 points", count: 2
        ))
        XCTAssertEqual(texts(short).last?.string, "+2 more features")
    }

    func testSquishedRowsLeaveEveryLabelOutAndSaySo() throws {
        let canvas = try draw(genes.map { feature($0.name, $0.type, $0.start * 1_000, $0.end * 1_000) }, end: 1_000_000)
        XCTAssertTrue(texts(canvas).isEmpty)
        XCTAssertEqual(canvas.omissions, [ViewerFigureOmission(
            trackID: "annotations", kind: .labelsOmitted, reason: "squished rows above 500 bases per point", count: 4
        )])
    }

    func testDensityRecordsTheScaleAndCountsEveryFeature() throws {
        let canvas = try draw(genes.map { feature($0.name, $0.type, $0.start * 100_000, $0.end * 100_000) }, end: 100_000_000)
        XCTAssertEqual(texts(canvas).map(\.string), ["5 features (zoom in to see details)"])
        XCTAssertEqual(canvas.omissions, [ViewerFigureOmission(
            trackID: "annotations", kind: .scaleMode, reason: "density above 50000 bases per point", count: 5
        )])
        XCTAssertEqual(canvas.items.first, .fill(
            rect: ViewerFigureRect(x: 0, y: 10, width: 1_000, height: 30), paint: ViewerFigurePaint(.controlBackground, alpha: 0.3)
        ))
    }

    func testEveryAnnotationTypeHasAColourRole() {
        let roles = Set(AnnotationType.allCases.map(ViewerFigureAnnotationColors.role(for:)))
        XCTAssertEqual(roles.count, 51)
        XCTAssertTrue(roles.allSatisfy { $0.rawValue.hasPrefix("annotation") })
    }
}
