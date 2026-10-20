// ViewerGraphicBundleSceneGoldenTests.swift - Scene goldens of a figure built from a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.30 (GFX-2, M1 step 2). Each case builds the figure `bundle export-graphic` draws from a small
// bundle and compares its `goldenJSON()` with `Tests/Fixtures/golden/viewer-graphics/bundle-<case>.scene.json`. A
// layer is written as its inputs, so the golden shows what the variant layers draw without any rendered byte. A
// golden moves only by a named prediction. `LUNGFISH_CAPTURE_SCENE_GOLDENS=1` writes the files instead.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class ViewerGraphicBundleSceneGoldenTests: XCTestCase {
    private static let goldenFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/golden/viewer-graphics")

    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "ViewerGraphicBundleScene")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    /// `chr1` of 3,000 bases, the annotation track `genes` with one gene at 1101 to 1400, and the variant track
    /// `calls` with a SNP at 1151 and a deletion at 1201 for samples `s1` and `s2`.
    private func makeBundle() throws -> URL {
        let bundle = folder.appendingPathComponent("golden.lungfishref", isDirectory: true)
        for sub in ["genome", "annotations", "variants"] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let bases = String(repeating: "ACGTTGCA", count: 375)
        let lines = stride(from: 0, to: bases.count, by: 60).map { start -> String in
            let from = bases.index(bases.startIndex, offsetBy: start)
            return String(bases[from..<bases.index(from, offsetBy: min(60, bases.count - start))])
        }
        try (">chr1\n" + lines.joined(separator: "\n") + "\n")
            .write(to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t3000\t6\t60\t61\n".write(to: bundle.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8)
        let bed = folder.appendingPathComponent("genes.bed")
        try "chr1\t1100\t1400\tgene-a\t0\t+\n".write(to: bed, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/genes.db"))
        let database = try ViewerFigureVariantTrackTests.makeDatabase(in: folder)
        try FileManager.default.copyItem(at: database, to: bundle.appendingPathComponent("variants/calls.db"))
        try BundleManifest(
            name: "Golden Fixture",
            identifier: "org.lungfish.golden-fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 3000,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 3000, offset: 6, lineBases: 60, lineWidth: 61)]
            ),
            annotations: [AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db")],
            variants: [VariantTrackInfo(
                id: "calls", name: "Calls", path: "variants/calls.vcf.gz", indexPath: "variants/calls.vcf.gz.tbi",
                databasePath: "variants/calls.db"
            )],
            recordStore: nil
        ).save(to: bundle)
        return bundle
    }

    private func assertGolden(_ name: String, settings: ViewerGraphicExport.Settings) async throws {
        let opened = try ViewerGraphicBundle(url: try makeBundle())
        let figure = try await ViewerGraphicExport.figure(
            bundle: opened, region: try opened.region(contig: "chr1", start: 1100, end: 1300),
            trackIDs: try ViewerGraphicExport.trackIDs(settings.tracks, in: opened), settings: settings,
            viewState: nil, viewStateURL: nil
        )
        let data = try figure.scene.goldenJSON()
        let url = Self.goldenFolder.appendingPathComponent("\(name).scene.json")
        if ProcessInfo.processInfo.environment["LUNGFISH_CAPTURE_SCENE_GOLDENS"] == "1" {
            try data.write(to: url)
            return
        }
        let golden = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), String(decoding: golden, as: UTF8.self), "\(name) moved")
    }

    func testBundleTracksScene() async throws {
        try await assertGolden("bundle-tracks", settings: .init(region: "chr1:1101-1300", width: 600, format: .png))
    }

    func testBundleRulerAndTracksSceneInTheDarkTheme() async throws {
        try await assertGolden(
            "bundle-ruler-and-tracks-dark",
            settings: .init(region: "chr1:1101-1300", width: 600, includeRuler: true, format: .pdf, theme: .dark)
        )
    }
}
