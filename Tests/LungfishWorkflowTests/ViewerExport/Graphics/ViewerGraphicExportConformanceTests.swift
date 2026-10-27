// ViewerGraphicExportConformanceTests.swift - The Depth track and range label of an exported mapping view (WF-5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane EXPORT-IMG (walk WF-5, rows 80 and 89). The walk's PNG and PDF of a mapping view had no Depth track,
// no depth scale and no contig name or range, where the window shows all three, and said nothing about it. Each case
// builds the figure `bundle export-graphic` draws from a bundle whose BAM holds three reads over 1101 to 1200, so
// samtools depth gives 3x over those 100 bases. samtools reads the BAM, so the class needs a real tool, skips without
// it and fails under `LUNGFISH_REQUIRE_TOOLS=1`. UX named the first case in `ViewerGraphicExportTests`, and the lane
// moved it here because it runs samtools.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest

final class ViewerGraphicExportConformanceTests: XCTestCase {
    /// The reference repeats `ACGTTGCA`. 60 bases a line is 4 more than a multiple of 8, so the lines alternate two strings.
    private static let pattern = Array("ACGTTGCA")
    private static let contigLength = 1_200_000
    private static let readStart = 1_100
    private static let readLength = 100

    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "ViewerGraphicExportDepth")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    /// A bundle with `chr1` and the alignment track `reads`, three forward reads that match the reference at 1101 to 1200.
    private func makeBundle() async throws -> ViewerGraphicBundle {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let bundle = folder.appendingPathComponent("depth.lungfishref", isDirectory: true)
        for sub in ["genome", "alignments"] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let even = String(String(repeating: "ACGTTGCA", count: 8).prefix(60))
        let odd = String(String(repeating: "TGCAACGT", count: 8).prefix(60))
        let lines = (0..<(Self.contigLength / 60)).map { $0 % 2 == 0 ? even : odd }
        try (">chr1\n" + lines.joined(separator: "\n") + "\n")
            .write(to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t\(Self.contigLength)\t6\t60\t61\n"
            .write(to: bundle.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8)
        let read = String((Self.readStart..<(Self.readStart + Self.readLength)).map { Self.pattern[$0 % Self.pattern.count] })
        try BamFixtureBuilder.makeBAM(
            at: bundle.appendingPathComponent("alignments/reads.bam"),
            references: [BamFixtureBuilder.Reference(name: "chr1", length: Self.contigLength)],
            reads: (1...3).map { index in
                BamFixtureBuilder.Read(
                    qname: "read\(index)", flag: 0, rname: "chr1", pos: Self.readStart + 1, mapq: 60,
                    cigar: "\(Self.readLength)M", seq: read, qual: String(repeating: "I", count: Self.readLength),
                    optionalFields: []
                )
            },
            samtoolsPath: samtools
        )
        try BundleManifest(
            name: "Depth Fixture", identifier: "org.lungfish.export-img-depth-fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: Int64(Self.contigLength),
                chromosomes: [ChromosomeInfo(name: "chr1", length: Int64(Self.contigLength), offset: 6, lineBases: 60, lineWidth: 61)]
            ),
            alignments: [AlignmentTrackInfo(
                id: "reads", name: "Reads", format: .bam, sourcePath: "alignments/reads.bam", indexPath: "alignments/reads.bam.bai"
            )]
        ).save(to: bundle)
        return try ViewerGraphicBundle(url: bundle)
    }

    /// The figure of `start..<end` at the command's default width of 800 points, Ruler and Tracks, the reads track
    /// alone, with the scale the app passes (`--coverage-scale linear`).
    private func figure(_ bundle: ViewerGraphicBundle, start: Int, end: Int) async throws -> ViewerGraphicFigure {
        try await ViewerGraphicExport.figure(
            bundle: bundle, region: try bundle.region(contig: "chr1", start: start, end: end), trackIDs: ["reads"],
            settings: .init(
                region: "chr1:\(start + 1)-\(end)", width: 800, includeRuler: true, format: .png, coverageScale: .linear
            ),
            viewState: nil, viewStateURL: nil
        )
    }

    private static func coverageLayers(_ scene: ViewerFigureScene) -> [ViewerFigureCoverageLayer] {
        scene.items.compactMap { item in
            if case .layer(.coverage(let layer)) = item { layer } else { nil }
        }
    }

    private static func texts(_ scene: ViewerFigureScene) -> [ViewerFigureText] {
        scene.items.compactMap { item in
            if case .text(let text) = item { text } else { nil }
        }
    }

    /// The text of the band at the top of the figure, 20 points high as the window's info bar.
    private static func labelRuns(_ scene: ViewerFigureScene) -> [String] {
        texts(scene).filter { $0.point.y < 20 }.map(\.string)
    }

    /// UX's test of WF-5 on the 400-base view. The figure draws the Depth track above the reads in the scale the command
    /// names, with the depth samtools gives, and the band at its top names the contig and the range as the window does.
    func testMappingExportDrawsDepthTrackAndRangeLabel() async throws {
        let figure = try await figure(try await makeBundle(), start: 1_100, end: 1_500)
        let layers = Self.coverageLayers(figure.scene)
        XCTAssertEqual(layers.count, 1, "the figure draws one Depth track for its one alignment track")
        let depth = try XCTUnwrap(layers.first, "the figure draws no Depth track")
        XCTAssertEqual(depth.scaleMode, .linear)
        XCTAssertEqual(depth.regionStart, 1_100)
        XCTAssertEqual(depth.regionEnd, 1_500)
        XCTAssertEqual(
            depth.depths, (Self.readStart..<(Self.readStart + Self.readLength)).map { .init(position: $0, depth: 3) },
            "samtools depth gives 3x over the three reads and nothing elsewhere"
        )
        // The stack is the label band, the ruler, the Depth track and the reads, from the top.
        XCTAssertEqual(depth.rect, ViewerFigureRect(x: 0, y: 40, width: 800, height: 60))
        XCTAssertEqual(figure.scene.height, 20 + 20 + 60 + 200)
        XCTAssertEqual(Self.labelRuns(figure.scene), ["chr1", "1,101 - 1,500 bp", "of 1.2 Mb total"])
        XCTAssertTrue(
            figure.tracks.contains { $0.id == "reads" && $0.kind == "depth" && $0.displayMode == "linear" },
            "the record names the Depth track and its scale"
        )
        XCTAssertFalse(figure.scene.omissions.contains { $0.kind == .trackNotDrawn }, "\(figure.scene.omissions)")
    }

    /// Above the depth threshold the figure reads no depth and says so in one line where the track would be, in the form
    /// of the reads line, and the record states it. The label band still names the contig and the range.
    func testWideMappingExportSaysTheDepthTrackIsLeftOut() async throws {
        let figure = try await figure(try await makeBundle(), start: 0, end: Self.contigLength)
        XCTAssertEqual(Self.coverageLayers(figure.scene), [], "no Depth track above the threshold")
        let line = "Depth not drawn at 1522.8 bases per point. Export 788000 bases or fewer at this width to draw it."
        let strings = Self.texts(figure.scene).map(\.string)
        XCTAssertTrue(strings.contains(line), "\(strings)")
        XCTAssertTrue(
            figure.scene.omissions.contains { $0.trackID == "reads" && $0.kind == .trackNotDrawn && $0.reason.contains("depth") },
            "\(figure.scene.omissions)"
        )
        XCTAssertEqual(Self.labelRuns(figure.scene), ["chr1", "1 - 1,200,000 bp", "of 1.2 Mb total"])
    }
}
