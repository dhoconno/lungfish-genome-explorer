// ViewerFigureVariantTrackTests.swift - The variant track of a viewer figure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.30 (GFX-2, MANAGER 1 reading A, MD23 item 1). The track reads a real variant database and draws
// the summary bar and the genotype rows as layers of the moved `VariantTrackRenderer` functions.

import Foundation
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow
import XCTest

final class ViewerFigureVariantTrackTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewerFigureVariantTrack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A database of two calls on `contig` for samples `s1` and `s2`, at 1-based 1151 (a SNP) and 1201 (a deletion).
    static func makeDatabase(in folder: URL, contig: String = "chr1") throws -> URL {
        let vcf = folder.appendingPathComponent("calls-\(contig).vcf")
        let lines = [
            "##fileformat=VCFv4.2",
            "##contig=<ID=\(contig),length=3000>",
            "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
            "##FORMAT=<ID=AD,Number=R,Type=Integer,Description=\"Allele depths\">",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\ts1\ts2",
            "\(contig)\t1151\t.\tA\tG\t50\tPASS\t.\tGT:AD\t0/1:5,5\t1/1:0,10",
            "\(contig)\t1201\t.\tAC\tA\t40\tPASS\t.\tGT:AD\t0/0:9,1\t0/1:4,6",
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: vcf, atomically: true, encoding: .utf8)
        let database = folder.appendingPathComponent("calls-\(contig).db")
        _ = try VariantDatabase.createFromVCF(vcfURL: vcf, outputURL: database)
        return database
    }

    private func frame(start: Double = 1100, end: Double = 1300) -> ViewerFigureFrame {
        ViewerFigureFrame(chromosome: "chr1", start: start, end: end, pixelWidth: 600, sequenceLength: 3000)
    }

    private func layers(_ scene: ViewerFigureScene) -> [ViewerFigureContextLayer] {
        scene.items.compactMap { item in
            if case .layer(let layer) = item { return layer }
            return nil
        }
    }

    func testLoadReadsTheWindowAndDrawsBothLayers() async throws {
        let database = try Self.makeDatabase(in: folder)
        let track = try ViewerFigureVariantTrack.load(
            trackID: "calls", databaseURL: database, chromosome: "chr1", aliases: [], start: 1100, end: 1300
        )
        XCTAssertEqual(track.content.marks.map(\.start), [1150, 1200])
        XCTAssertEqual(track.content.marks.map(\.variantType), ["SNP", "DEL"])
        XCTAssertEqual(track.content.sampleNames, ["s1", "s2"])
        // The import stores no row for a 0/0 call, and the rows draw a sample with no call as the live view does.
        XCTAssertEqual(track.content.sites.map(\.calls), [["s1": "HET", "s2": "HOM_ALT"], ["s2": "HET"]])
        XCTAssertEqual(track.content.sites.first?.alleleFractions["s1"], 0.5)
        XCTAssertEqual(track.height, 20 + 2 + 2 * 12, "the summary bar, its gap and one 12-point row per sample")

        let scene = try await ViewerFigureSceneBuilder.build(frame: frame(), appearance: .light, tracks: [track])
        let drawn = layers(scene)
        XCTAssertEqual(drawn.count, 2)
        guard case .variantSummary(let bar) = drawn.first, case .genotypeRows(let rows) = drawn.last else {
            return XCTFail("expected the summary bar, then the genotype rows: \(drawn)")
        }
        XCTAssertEqual(bar.yOffset, 0)
        XCTAssertEqual(bar.barHeight, 20)
        XCTAssertEqual(rows.yOffset, 22)
        XCTAssertEqual(rows.availableHeight, 24)
        XCTAssertEqual(rows.sampleNames, ["s1", "s2"])
        XCTAssertEqual(scene.omissions, [])
    }

    func testAWindowWithNoVariantsDrawsNothing() async throws {
        let database = try Self.makeDatabase(in: folder)
        let track = try ViewerFigureVariantTrack.load(
            trackID: "calls", databaseURL: database, chromosome: "chr1", aliases: [], start: 2000, end: 2100
        )
        let scene = try await ViewerFigureSceneBuilder.build(frame: frame(start: 2000, end: 2100), appearance: .light, tracks: [track])
        XCTAssertEqual(scene.items, [])
        XCTAssertEqual(scene.omissions, [])
    }

    func testAnAliasTheManifestListsNamesTheDatabaseContig() throws {
        let database = try Self.makeDatabase(in: folder, contig: "NC_000001")
        let unnamed = try ViewerFigureVariantTrack.load(
            trackID: "calls", databaseURL: database, chromosome: "chr1", aliases: [], start: 1100, end: 1300
        )
        XCTAssertEqual(unnamed.content.marks, [])
        let aliased = try ViewerFigureVariantTrack.load(
            trackID: "calls", databaseURL: database, chromosome: "chr1", aliases: ["NC_000001"], start: 1100, end: 1300
        )
        XCTAssertEqual(aliased.content.marks.count, 2)
    }

    func testOverTheGenotypeCapDrawsTheZoomLineAndRecordsTheLimit() throws {
        var content = ViewerFigureVariantTrack.Content()
        content.marks = (0..<5_001).map { .init(start: $0 % 3000, end: $0 % 3000 + 1, variantType: "SNP") }
        content.sampleNames = ["s1", "s2"]
        let track = ViewerFigureVariantTrack(trackID: "calls", content: content)
        var canvas = ViewerFigureCanvas()
        try track.draw(into: &canvas, area: ViewerFigureRect(x: 0, y: 10, width: 600, height: track.height))
        guard case .layer(.variantSummary(let bar)) = canvas.items.first else {
            return XCTFail("expected the summary bar first: \(canvas.items)")
        }
        XCTAssertEqual(bar.yOffset, 10)
        guard case .text(let line) = canvas.items.last else { return XCTFail("expected the zoom-in line last") }
        XCTAssertEqual(line.string, "Zoom in to display genotypes (5001 variants visible)")
        XCTAssertEqual(line.fontName, "HelveticaNeue")
        XCTAssertEqual(line.fontSize, 10)
        XCTAssertEqual(canvas.omissions, [ViewerFigureOmission(
            trackID: "calls", kind: .annotationLimit, reason: "genotype rows above 5000 variants", count: 2
        )])
    }

    func testSampleRowsPastTheTrackHeightAreRecorded() throws {
        var content = ViewerFigureVariantTrack.Content()
        content.marks = [.init(start: 1150, end: 1151, variantType: "SNP")]
        content.sites = [.init(position: 1150, ref: "A", alt: "G", variantType: "SNP", calls: ["s1": "HET"])]
        content.sampleNames = ["s1", "s2", "s3"]
        let track = ViewerFigureVariantTrack(trackID: "calls", content: content, height: 46)
        var canvas = ViewerFigureCanvas()
        try track.draw(into: &canvas, area: ViewerFigureRect(x: 0, y: 0, width: 600, height: track.height))
        XCTAssertEqual(canvas.items.count, 2)
        XCTAssertEqual(canvas.omissions, [ViewerFigureOmission(
            trackID: "calls", kind: .readRowCap, reason: "sample rows past the track height of 46 points", count: 1
        )])
    }

    func testTheLayersTakeTheViewersColourTheme() throws {
        var state = SampleDisplayState()
        state.colorThemeName = VariantColorTheme.highContrast.name
        var content = ViewerFigureVariantTrack.Content()
        content.marks = [.init(start: 1150, end: 1151, variantType: "SNP")]
        let track = ViewerFigureVariantTrack(trackID: "calls", content: content, state: state)
        var canvas = ViewerFigureCanvas()
        try track.draw(into: &canvas, area: ViewerFigureRect(x: 0, y: 0, width: 600, height: track.height))
        guard case .layer(.variantSummary(let bar)) = canvas.items.first else { return XCTFail("no summary bar") }
        XCTAssertEqual(bar.colorThemeName, state.colorThemeName)
    }
}
