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
}
