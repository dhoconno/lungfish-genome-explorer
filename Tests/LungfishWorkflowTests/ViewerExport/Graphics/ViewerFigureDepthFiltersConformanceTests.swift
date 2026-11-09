// ViewerFigureDepthFiltersConformanceTests.swift - A figure's depth equals the window's under changed filters
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 4 lane FIGURE-DEPTH, row EXPORT-DEPTH-FILTERS (S2, BIO). The window draws its depth strip under the person's
// mapping-quality and base-quality filters, and the figure drew depth at 0 and 0, so with a filter set the image
// printed larger depths than the window with no word. The bundle's BAM holds the two reads of
// `SCR/lanes/FIGURE-DEPTH/depth-fixture.sam`, one at MAPQ 60 and one at MAPQ 0 over the same 100 bases, where the
// MAPQ 60 read has base quality 40 on its first 50 bases and 10 on its last 50. Every literal below is the output of
// `samtools depth -a` run directly on that SAM (samtools 1.24, `-Q` the mapping quality and `-q` the base quality).
// The filters reach the leaf through the view-state file the app writes, so each case reads that file's JSON as the
// leaf does. The class needs samtools, skips without it and fails under `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest

final class ViewerFigureDepthFiltersConformanceTests: XCTestCase {
    private static let contigLength = 1_200

    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "ViewerFigureDepthFilters")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    /// A bundle with `chr1` and the alignment track `reads`, the two reads of `depth-fixture.sam` over 101 to 200.
    private func makeBundle() async throws -> ViewerGraphicBundle {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let bundle = folder.appendingPathComponent("filters.lungfishref", isDirectory: true)
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
        let pattern = Array("ACGTTGCA")
        let read = String((100..<200).map { pattern[$0 % pattern.count] })
        try BamFixtureBuilder.makeBAM(
            at: bundle.appendingPathComponent("alignments/reads.bam"),
            references: [BamFixtureBuilder.Reference(name: "chr1", length: Self.contigLength)],
            reads: [
                BamFixtureBuilder.Read(
                    qname: "hiq", flag: 0, rname: "chr1", pos: 101, mapq: 60, cigar: "100M", seq: read,
                    qual: String(repeating: "I", count: 50) + String(repeating: "+", count: 50), optionalFields: []
                ),
                BamFixtureBuilder.Read(
                    qname: "loq", flag: 0, rname: "chr1", pos: 101, mapq: 0, cigar: "100M", seq: read,
                    qual: String(repeating: "I", count: 100), optionalFields: []
                ),
            ],
            samtoolsPath: samtools
        )
        try BundleManifest(
            name: "Depth Filters Fixture", identifier: "org.lungfish.export-depth-filters-fixture",
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

    /// The figure of the first 400 bases at the command's width, with the view state the app would write, read from
    /// `json` as the leaf reads the file.
    private func figure(_ bundle: ViewerGraphicBundle, viewStateJSON json: String?) async throws -> ViewerGraphicFigure {
        let state = try json.map { try JSONDecoder().decode(ViewerGraphicViewState.self, from: Data($0.utf8)) }
        return try await ViewerGraphicExport.figure(
            bundle: bundle, region: try bundle.region(contig: "chr1", start: 0, end: 400), trackIDs: ["reads"],
            settings: .init(region: "chr1:1-400", width: 800, includeRuler: true, format: .png, coverageScale: .linear),
            viewState: state, viewStateURL: nil
        )
    }

    /// The depth of each position the figure's Depth track draws, 0-based.
    private static func depths(of figure: ViewerGraphicFigure) throws -> [Int: Int] {
        let layers = figure.scene.items.compactMap { item -> ViewerFigureCoverageLayer? in
            if case .layer(.coverage(let layer)) = item { layer } else { nil }
        }
        let layer = try XCTUnwrap(layers.first, "the figure draws no Depth track")
        return Dictionary(layer.depths.map { ($0.position, $0.depth) }, uniquingKeysWith: { _, last in last })
    }

    /// The depth `samtools depth` prints, as runs of 0-based positions with the depth over each run. A position with
    /// no depth is left out, as the Depth track leaves it out.
    private static func depth(_ runs: [(Range<Int>, Int)]) -> [Int: Int] {
        var depths: [Int: Int] = [:]
        for (range, depth) in runs {
            for position in range {
                depths[position] = depth
            }
        }
        return depths
    }

    /// The figure's depth is the window's, which is `samtools depth` under the window's two cutoffs. At the defaults it
    /// stays the unfiltered depth, so every figure made before the row is the figure made after it.
    func testFigureDepthEqualsWindowDepthUnderChangedFilters() async throws {
        let bundle = try await makeBundle()
        // samtools depth -a: both reads count over 101 to 200.
        let atDefaults = try Self.depths(of: try await figure(bundle, viewStateJSON: nil))
        XCTAssertEqual(atDefaults, Self.depth([(100..<200, 2)]), "no filter counts both reads")
        // samtools depth -a -Q 30: the MAPQ 0 read is left out over 101 to 200.
        let mapQ30 = try Self.depths(
            of: try await figure(bundle, viewStateJSON: #"{"schemaVersion":1,"tracks":[],"depthMinMapQ":30}"#)
        )
        XCTAssertEqual(mapQ30, Self.depth([(100..<200, 1)]), "MAPQ 30 leaves out the MAPQ 0 read")
        // samtools depth -a -q 20: the Q10 bases of the MAPQ 60 read are left out over 151 to 200.
        let baseQ20 = try Self.depths(
            of: try await figure(bundle, viewStateJSON: #"{"schemaVersion":1,"tracks":[],"depthMinBaseQ":20}"#)
        )
        XCTAssertEqual(baseQ20, Self.depth([(100..<150, 2), (150..<200, 1)]), "base quality 20 leaves out the Q10 bases")
        // samtools depth -a -Q 30 -q 20: the MAPQ 60 read over 101 to 150 is the only depth.
        let both = try Self.depths(
            of: try await figure(
                bundle, viewStateJSON: #"{"schemaVersion":1,"tracks":[],"depthMinMapQ":30,"depthMinBaseQ":20}"#
            )
        )
        XCTAssertEqual(both, Self.depth([(100..<150, 1)]), "both cutoffs together")
    }

    /// The record's facts and the image's own line state the cutoffs the depth counted under. At the defaults no fact
    /// holds a cutoff and the image draws no such line. The reads' own cutoff is its own number in the alignment fact,
    /// since the window's reads use `minMapQSetting` alone and its depth the larger of two mapping qualities.
    func testFigureStatesTheCutoffsOfItsDepthInTheFactsAndInOneLine() async throws {
        let bundle = try await makeBundle()
        let atDefaults = try await figure(bundle, viewStateJSON: nil)
        XCTAssertEqual(atDefaults.tracks.map(\.kind), ["depth", "alignment"])
        XCTAssertEqual(atDefaults.tracks.map(\.minMapQ), [nil, nil])
        XCTAssertEqual(atDefaults.tracks.map(\.minBaseQ), [nil, nil])
        XCTAssertEqual(Self.cutoffLines(of: atDefaults), [], "no line at the defaults")

        let set = try await figure(
            bundle, viewStateJSON: #"{"schemaVersion":1,"tracks":[],"readMinMapQ":10,"depthMinMapQ":30,"depthMinBaseQ":20}"#
        )
        let depth = try XCTUnwrap(set.tracks.first { $0.kind == "depth" })
        let reads = try XCTUnwrap(set.tracks.first { $0.kind == "alignment" })
        XCTAssertEqual(depth.minMapQ, 30)
        XCTAssertEqual(depth.minBaseQ, 20)
        XCTAssertEqual(reads.minMapQ, 10, "the reads' cutoff is the window's reads number, not the depth's")
        XCTAssertNil(reads.minBaseQ)
        XCTAssertEqual(
            Self.cutoffLines(of: set),
            ["Depth counts reads with mapping quality 30 or more and bases with quality 20 or more."]
        )
        // The line sits under the strip in the live overflow bar's 16 points, so the Depth fact is taller by one bar.
        let plainDepth = try XCTUnwrap(atDefaults.tracks.first { $0.kind == "depth" })
        XCTAssertEqual(depth.height - plainDepth.height, 16)
    }

    /// The text of each line the Depth track draws about its cutoffs, in either form.
    private static func cutoffLines(of figure: ViewerGraphicFigure) -> [String] {
        figure.scene.items.compactMap { item -> String? in
            guard case .text(let text) = item else { return nil }
            let line = text.string.hasPrefix("Depth counts") || text.string.hasPrefix("Depth: mapping")
                || text.string.hasPrefix("Depth: base")
            return line ? text.string : nil
        }
    }
}
