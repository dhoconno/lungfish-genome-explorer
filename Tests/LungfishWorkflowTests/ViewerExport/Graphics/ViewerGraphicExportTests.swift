// ViewerGraphicExportTests.swift - The range label of every exported figure (WF-5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane EXPORT-IMG (walk WF-5, rows 80 and 89). The walk's image of a reference bundle with no tracks was the
// sequence bar alone, with no contig name and no range, where the window names both (walk/row80-ref-notracks.png).
// These cases open no tool, so they run in the unit tier. The mapping view's case reads its BAM with samtools and is in
// `ViewerGraphicExportConformanceTests`.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class ViewerGraphicExportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "ViewerGraphicExportLabel")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    /// A reference bundle with `chr1` of 3,000 bases and no track.
    private func makeReferenceBundle() throws -> ViewerGraphicBundle {
        let bundle = folder.appendingPathComponent("reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("genome"), withIntermediateDirectories: true)
        let line = String(String(repeating: "ACGTTGCA", count: 8).prefix(60))
        let other = String(String(repeating: "TGCAACGT", count: 8).prefix(60))
        let lines = (0..<50).map { $0 % 2 == 0 ? line : other }
        try (">chr1\n" + lines.joined(separator: "\n") + "\n")
            .write(to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t3000\t6\t60\t61\n".write(to: bundle.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8)
        try BundleManifest(
            name: "Reference Fixture", identifier: "org.lungfish.export-img-reference-fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 3000,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 3000, offset: 6, lineBases: 60, lineWidth: 61)]
            )
        ).save(to: bundle)
        return try ViewerGraphicBundle(url: bundle)
    }

    /// The text of the band at the top of the figure, 20 points high as the window's info bar.
    private static func labelRuns(_ scene: ViewerFigureScene) -> [String] {
        scene.items.compactMap { item in
            if case .text(let text) = item, text.point.y < 20 { text.string } else { nil }
        }
    }

    /// The image of a reference bundle with no tracks, Tracks scope, carries the contig name and the range the window's
    /// info bar writes, "1,101 - 1,300 bp" and "of 3 kb total".
    func testReferenceOnlyExportCarriesTheContigAndRangeLabel() async throws {
        let bundle = try makeReferenceBundle()
        let figure = try await ViewerGraphicExport.figure(
            bundle: bundle, region: try bundle.region(contig: "chr1", start: 1_100, end: 1_300),
            trackIDs: try ViewerGraphicExport.trackIDs([], in: bundle),
            settings: .init(region: "chr1:1101-1300", width: 600, format: .png), viewState: nil, viewStateURL: nil
        )
        XCTAssertEqual(Self.labelRuns(figure.scene), ["chr1", "1,101 - 1,300 bp", "of 3 kb total"])
        XCTAssertFalse(figure.scene.omissions.contains { $0.trackID == "label" }, "the label fits at 600 points")
    }

    /// The walk's 400-base window reads as the window writes it, with the contig name first.
    func testLabelRunsOfTheWalksWindow() {
        let frame = ViewerFigureFrame(
            chromosome: "chr20_10.0-10.5Mb", start: 250_000, end: 250_400, pixelWidth: 1648, sequenceLength: 500_001,
            trailingInset: ViewerFigureFrame.defaultTrailingInset
        )
        XCTAssertEqual(
            ViewerFigureRangeLabelTrack.runs(frame: frame), ["chr20_10.0-10.5Mb", "250,001 - 250,400 bp", "of 500.0 kb total"]
        )
        XCTAssertEqual(ViewerFigureRangeLabelTrack.totalText(812), "of 812 bp total")
        XCTAssertEqual(ViewerFigureRangeLabelTrack.totalText(29_903), "of 29.9 kb total")
        XCTAssertEqual(ViewerFigureRangeLabelTrack.totalText(2_000_000), "of 2 Mb total")
    }

    /// A narrow figure leaves the length out first and records it.
    func testLabelLeavesOutTheLengthFirstWhenTheFigureIsNarrow() async throws {
        let frame = ViewerFigureFrame(chromosome: "chr1", start: 1_100, end: 1_300, pixelWidth: 200, sequenceLength: 3_000)
        let scene = try await ViewerFigureSceneBuilder.build(frame: frame, appearance: .light, tracks: [ViewerFigureRangeLabelTrack()])
        XCTAssertEqual(Self.labelRuns(scene), ["chr1", "1,101 - 1,300 bp"])
        XCTAssertEqual(scene.omissions.map(\.trackID), ["label"])
        XCTAssertEqual(scene.omissions.first?.kind, .labelsOmitted)
        XCTAssertEqual(scene.omissions.first?.count, 1)
    }

    /// The threshold is inclusive, 1,000 bases a point draws and one base more does not.
    func testDepthTrackDrawsUpToItsThreshold() {
        let width = 800
        let data = width - Int(ViewerFigureFrame.defaultTrailingInset)
        func frame(_ end: Int) -> ViewerFigureFrame {
            ViewerFigureFrame(
                chromosome: "chr1", start: 0, end: Double(end), pixelWidth: width,
                trailingInset: ViewerFigureFrame.defaultTrailingInset
            )
        }
        XCTAssertTrue(ViewerFigureDepthTrack.draws(at: frame(1_000 * data)))
        XCTAssertFalse(ViewerFigureDepthTrack.draws(at: frame(1_000 * data + 1)))
        XCTAssertEqual(ViewerFigureDepthTrack(trackID: "reads", source: nil, frame: frame(1_000 * data)).height, 60)
        XCTAssertEqual(ViewerFigureDepthTrack(trackID: "reads", source: nil, frame: frame(1_000 * data + 1)).height, 16)
    }

    /// Below the threshold the track adds one coverage layer across its area in the scale it was given.
    func testDepthTrackDrawsOneCoverageLayerInTheNamedScale() {
        let frame = ViewerFigureFrame(chromosome: "chr1", start: 1_100, end: 1_500, pixelWidth: 800, trailingInset: 12)
        let track = ViewerFigureDepthTrack(trackID: "reads", source: nil, frame: frame, scaleMode: .log10)
        let area = ViewerFigureRect(x: 0, y: 40, width: 800, height: track.height)
        let depths = [ViewerFigureCoverageLayer.Depth(position: 1_200, depth: 7)]
        var canvas = ViewerFigureCanvas()
        track.draw(depths, into: &canvas, frame: frame, area: area)
        XCTAssertEqual(canvas.items, [.layer(.coverage(ViewerFigureCoverageLayer(
            rect: area, regionStart: 1_100, regionEnd: 1_500, depths: depths, scaleMode: .log10
        )))])
        XCTAssertEqual(canvas.omissions, [])
    }

    /// Above the threshold the track reads nothing and draws UX's one line, and the scene records a `trackNotDrawn` fact.
    func testDepthTrackLeavesItselfOutAboveItsThresholdWithOneLine() async throws {
        let frame = ViewerFigureFrame(
            chromosome: "chr1", start: 0, end: 1_200_000, pixelWidth: 800, trailingInset: ViewerFigureFrame.defaultTrailingInset
        )
        let scene = try await ViewerFigureSceneBuilder.build(
            frame: frame, appearance: .light, tracks: [ViewerFigureDepthTrack(trackID: "reads", source: nil, frame: frame)]
        )
        let strings = scene.items.compactMap { item -> String? in
            if case .text(let text) = item { text.string } else { nil }
        }
        XCTAssertEqual(strings, ["Depth not drawn at 1522.8 bases per point. Export 788000 bases or fewer at this width to draw it."])
        XCTAssertEqual(scene.height, 16)
        XCTAssertEqual(scene.omissions, [ViewerFigureOmission(
            trackID: "reads", kind: .trackNotDrawn, reason: "depth not drawn above 1000 bases per point", count: nil
        )])
    }
}
