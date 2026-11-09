// BundleExportGraphicMaskingConformanceTests.swift - A window with Hide high-gap sites on exports a figure that says so
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 4 lane FIGURE-DEPTH, row ALIGN-IMAGE-EXPORT-MASKING (S3, BIO). The window hides high-gap sites from its reads
// when the person turns that switch on, and the figure never hid them, with no word in the image or the record. The
// figure still draws them, so the row asks for a recorded omission and no change to the drawing. The window's state
// reaches the leaf through the view-state file the app writes, so the case reads that file's JSON as the leaf does.
// The figure is built from a bundle whose BAM holds one read, so the class needs samtools, skips without it and fails
// under `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class BundleExportGraphicMaskingConformanceTests: XCTestCase {
    private static let contigLength = 1_200

    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "ExportGraphicMasking")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    /// A bundle with `chr1` and the alignment track `reads`, one forward read of 100 bases at 101 to 200.
    private func makeBundle() async throws -> ViewerGraphicBundle {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let bundle = folder.appendingPathComponent("masking.lungfishref", isDirectory: true)
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
                    qname: "read1", flag: 0, rname: "chr1", pos: 101, mapq: 60, cigar: "100M", seq: read,
                    qual: String(repeating: "I", count: 100), optionalFields: []
                ),
            ],
            samtoolsPath: samtools
        )
        try BundleManifest(
            name: "Masking Fixture", identifier: "org.lungfish.export-img-masking-fixture",
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

    /// The figure of the first `end` bases (400 unless given) at `width` points (800 unless given), with the view state
    /// the app would write, read from `json` as the leaf reads the file.
    private func figure(
        _ bundle: ViewerGraphicBundle, viewStateJSON json: String?, end: Int = 400, width: Double = 800
    ) async throws -> ViewerGraphicFigure {
        let state = try json.map { try JSONDecoder().decode(ViewerGraphicViewState.self, from: Data($0.utf8)) }
        return try await ViewerGraphicExport.figure(
            bundle: bundle, region: try bundle.region(contig: "chr1", start: 0, end: end), trackIDs: ["reads"],
            settings: .init(region: "chr1:1-\(end)", width: width, includeRuler: true, format: .png, coverageScale: .linear),
            viewState: state, viewStateURL: nil
        )
    }

    /// With the switch on the figure records one omission for the reads track and says in one sentence that the track
    /// still shows the high-gap sites. It draws every item it draws with the switch off, so masking off is the same
    /// figure as before the row.
    func testHideHighGapSitesOnRecordsOneOmissionAndDrawsTheSameFigure() async throws {
        let bundle = try await makeBundle()
        let off = try await figure(bundle, viewStateJSON: nil)
        let on = try await figure(bundle, viewStateJSON: #"{"schemaVersion":1,"tracks":[],"hideHighGapSites":true}"#)

        XCTAssertEqual(off.scene.omissions.filter { $0.kind.rawValue == "highGapMasking" }, [], "masking off records nothing")
        let masking = on.scene.omissions.filter { $0.kind.rawValue == "highGapMasking" }
        XCTAssertEqual(masking.count, 1, "masking on records one omission, \(on.scene.omissions)")
        let omission = try XCTUnwrap(masking.first)
        XCTAssertEqual(omission.trackID, "reads")
        XCTAssertEqual(omission.reason, "Hide high-gap sites applies in the window only")
        XCTAssertNil(omission.count)

        XCTAssertEqual(on.scene.items, off.scene.items, "masking on changes no drawn item")
        XCTAssertEqual(on.scene.height, off.scene.height)
        XCTAssertEqual(on.tracks, off.tracks, "masking on changes no track fact")
        XCTAssertEqual(on.scene.omissions.filter { $0.kind.rawValue != "highGapMasking" }, off.scene.omissions)

        XCTAssertEqual(
            BundleExportGraphicRecord.warning(omission),
            "The reads track still shows the high-gap sites (Hide high-gap sites applies in the window only)."
        )
        XCTAssertTrue(BundleExportGraphicRecord.warns(omission), "the image differs from the window, so the line is a warning")
        XCTAssertTrue(
            ViewerGraphicExport.degradedFacts(of: on.scene).contains(omission), "the record's degraded list holds the omission"
        )
    }

    /// Above 2 bases per point (the coverage tier) neither the window nor the figure draws a read, so the switch changes
    /// nothing there and the figure records no masking omission, which would warn about reads the image does not show
    /// (FIGURE-DEPTH-BIO and FIGURE-DEPTH-UX, should-fix 1). All 1,200 bases at 300 points is about 4 bases per point.
    func testHideHighGapSitesOnAtTheCoverageTierRecordsNoOmission() async throws {
        let frame = ViewerFigureFrame(
            chromosome: "chr1", start: 0, end: Double(Self.contigLength), pixelWidth: 300,
            sequenceLength: Self.contigLength, trailingInset: ViewerFigureFrame.defaultTrailingInset
        )
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: frame.scale), .coverage, "the case needs the coverage tier")

        let bundle = try await makeBundle()
        let on = try await figure(
            bundle, viewStateJSON: #"{"schemaVersion":1,"tracks":[],"hideHighGapSites":true}"#, end: Self.contigLength, width: 300
        )

        XCTAssertTrue(
            on.scene.omissions.contains { $0.trackID == "reads" && $0.kind.rawValue == "scaleMode" },
            "the reads track left its reads out at this zoom, \(on.scene.omissions)"
        )
        XCTAssertEqual(
            on.scene.omissions.filter { $0.kind.rawValue == "highGapMasking" }, [], "no read is drawn, so nothing is recorded"
        )
        XCTAssertEqual(
            ViewerGraphicExport.degradedFacts(of: on.scene).filter { $0.kind.rawValue == "highGapMasking" }, [],
            "the record's degraded list holds no masking line"
        )
    }
}
