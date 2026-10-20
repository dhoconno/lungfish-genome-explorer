// ViewerFigureTrackSceneGoldenTests.swift - Scene goldens of the annotation and read tracks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishWorkflow

/// Each case builds a scene and compares its `goldenJSON()` with
/// `Tests/Fixtures/golden/viewer-graphics/<case>.scene.json`. A golden moves only by a named
/// prediction (BIO 7). `LUNGFISH_CAPTURE_SCENE_GOLDENS=1` writes the files instead.
final class ViewerFigureTrackSceneGoldenTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/golden/viewer-graphics")

    /// A track that draws in-memory features or reads.
    private struct DrawnTrack: ViewerFigureTrackBuilding {
        let height: Double
        let body: @Sendable (inout ViewerFigureCanvas, ViewerFigureFrame, ViewerFigureRect) throws -> Void

        func build(into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect) async throws {
            try body(&canvas, frame, area)
        }
    }

    private func check(_ scene: ViewerFigureScene, _ name: String) throws {
        let url = Self.folder.appendingPathComponent("\(name).scene.json")
        let data = try scene.goldenJSON()
        if ProcessInfo.processInfo.environment["LUNGFISH_CAPTURE_SCENE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let golden = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), String(decoding: golden, as: UTF8.self), "\(name) moved")
    }

    private func scene(end: Double, appearance: ViewerFigureAppearance, track: DrawnTrack) async throws -> ViewerFigureScene {
        try await ViewerFigureSceneBuilder.build(
            frame: ViewerFigureFrame(chromosome: "chr1", start: 0, end: end, pixelWidth: 1_000),
            appearance: appearance, tracks: [track]
        )
    }

    func testAnnotationExpandedFromADatabase() async throws {
        try check(try await ViewerFigureAnnotationFixture.databaseScene(), "annotation-expanded")
    }

    func testAnnotationSquishedLeavesItsLabelsOut() async throws {
        let features = [
            SequenceAnnotation(type: .gene, name: "geneA", chromosome: "chr1", start: 10_000, end: 200_000, strand: .forward),
            SequenceAnnotation(type: .gene, name: "geneB", chromosome: "chr1", start: 100_000, end: 300_000, strand: .reverse),
            SequenceAnnotation(type: .mRNA, name: "tx1", chromosome: "chr1", start: 400_000, end: 600_000, strand: .forward),
        ]
        let track = DrawnTrack(height: 60) { canvas, frame, area in
            try ViewerFigureAnnotationTrack(sources: [], height: 60).draw(features, into: &canvas, frame: frame, area: area)
        }
        try check(try await scene(end: 1_000_000, appearance: .light, track: track), "annotation-squished")
    }

    func testReadsPackedPastTheRowCap() async throws {
        var options = ViewerFigureReadTrack.Options()
        options.maxRows = 2
        let track = DrawnTrack(height: 100) { [options] canvas, frame, area in
            try ViewerFigureReadTrack(source: nil, height: 100, options: options)
                .draw(ViewerFigureReadFixture.packed, into: &canvas, frame: frame, area: area)
        }
        try check(try await scene(end: 1_000, appearance: .light, track: track), "reads-packed")
    }

    func testReadsBaseTierInTheDarkAppearance() async throws {
        let reads = [
            ViewerFigureReadFixture.read("b", 10, md: "50T49"),
            ViewerFigureReadFixture.read("c", 60, reverse: true, mapq: 5, cigar: "20M2I30M"),
        ]
        let track = DrawnTrack(height: 40) { canvas, frame, area in
            try ViewerFigureReadTrack(source: nil, height: 40).draw(reads, into: &canvas, frame: frame, area: area)
        }
        try check(try await scene(end: 400, appearance: .dark, track: track), "reads-base-tier")
    }
}
