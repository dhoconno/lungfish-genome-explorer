// ViewerFigureReadMismatchConformanceTests.swift - The mismatch marks of an exported read track (OBS-W7)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane W7 (OBS-W7). The walk's mapping image drew every read as a perfect match where the window showed a
// variant column in nearly every read: minimap2 writes no MD tag and the figure was given no reference, so it had
// nothing to place a mark with. Each case builds the figure `bundle export-graphic` draws from a bundle whose BAM has
// two reads with one SNP and no MD tag, renders it, and reads the SNP's column of pixels. samtools reads the BAM, so
// the class needs a real tool, skips without it and fails under `LUNGFISH_REQUIRE_TOOLS=1`.

import CoreGraphics
import Foundation
import ImageIO
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest

final class ViewerFigureReadMismatchConformanceTests: XCTestCase {
    /// The reference repeats `ACGTTGCA`, so base 1148 (0-based) is a T. Both reads cover 1100 to 1200 and read G there.
    /// They start inside every window, since a capped pack leaves out a read that starts at the window's first pixel
    /// (a finding of this lane, `ReadRowAllocator.place`).
    private static let pattern = Array("ACGTTGCA")
    private static let contigLength = 24_000
    private static let readStart = 1_100
    private static let snpOffset = 48
    private static let snpBase: Character = "G"

    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "ViewerFigureReadMismatch")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    private static func referenceBase(_ position: Int) -> Character {
        pattern[position % pattern.count]
    }

    /// A bundle with `chr1` and the alignment track `reads`, a forward and a reverse read with the SNP and no MD tag.
    private func makeBundle() async throws -> ViewerGraphicBundle {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let bundle = folder.appendingPathComponent("snp.lungfishref", isDirectory: true)
        for sub in ["genome", "alignments"] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let bases = String((0..<Self.contigLength).map(Self.referenceBase))
        let lines = stride(from: 0, to: bases.count, by: 60).map { start -> String in
            let from = bases.index(bases.startIndex, offsetBy: start)
            return String(bases[from..<bases.index(from, offsetBy: min(60, bases.count - start))])
        }
        try (">chr1\n" + lines.joined(separator: "\n") + "\n")
            .write(to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t\(Self.contigLength)\t6\t60\t61\n"
            .write(to: bundle.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8)
        var read = Array(bases.dropFirst(Self.readStart).prefix(100))
        XCTAssertNotEqual(read[Self.snpOffset], Self.snpBase, "the SNP differs from the reference")
        read[Self.snpOffset] = Self.snpBase
        let quality = String(repeating: "I", count: 100)
        try BamFixtureBuilder.makeBAM(
            at: bundle.appendingPathComponent("alignments/reads.bam"),
            references: [BamFixtureBuilder.Reference(name: "chr1", length: Self.contigLength)],
            reads: [0, 16].map { flag in
                BamFixtureBuilder.Read(
                    qname: flag == 0 ? "forward" : "reverse", flag: flag, rname: "chr1", pos: Self.readStart + 1,
                    mapq: 60, cigar: "100M", seq: String(read), qual: quality, optionalFields: []
                )
            },
            samtoolsPath: samtools
        )
        try BundleManifest(
            name: "SNP Fixture", identifier: "org.lungfish.w7-snp-fixture",
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

    /// The figure of `start..<end` at the walk's width of 1856 points, the reads track alone.
    private func figure(_ bundle: ViewerGraphicBundle, start: Int, end: Int) async throws -> ViewerGraphicFigure {
        try await ViewerGraphicExport.figure(
            bundle: bundle, region: try bundle.region(contig: "chr1", start: start, end: end), trackIDs: ["reads"],
            settings: .init(region: "chr1:\(start + 1)-\(end)", width: 1856, format: .png), viewState: nil, viewStateURL: nil
        )
    }

    private static func bodies(_ scene: ViewerFigureScene) -> [ViewerFigureRect] {
        scene.items.compactMap { item in
            if case .fill(let rect, let paint) = item, paint.role == .forwardRead || paint.role == .reverseRead { rect } else { nil }
        }
    }

    private static let baseRoles: Set<ViewerFigureColorRole> = [.readBaseA, .readBaseC, .readBaseG, .readBaseT, .readBaseN]

    /// The 8-bit sRGB pixels of a PNG, top row first.
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(png: Data) throws {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            width = image.width
            height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
                guard let context = CGContext(
                    data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            XCTAssertTrue(drawn)
            bytes = buffer
        }

        /// The colour at a point of the figure, `scale` pixels a point.
        func color(x: Double, y: Double, scale: Double = 2) -> ViewerFigureColor {
            let px = min(width - 1, Int(x * scale)), py = min(height - 1, Int(y * scale))
            let offset = (py * width + px) * 4
            return ViewerFigureColor(
                red: Double(bytes[offset]) / 255, green: Double(bytes[offset + 1]) / 255, blue: Double(bytes[offset + 2]) / 255
            )
        }
    }

    private static func distance(_ a: ViewerFigureColor, _ b: ViewerFigureColor) -> Double {
        max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
    }

    /// Asserts that the SNP's column carries the G colour in both read rows, and that 20 bases before it the row
    /// carries the read fill.
    private func assertSNPColumnMarked(_ figure: ViewerGraphicFigure, file: StaticString = #filePath, line: UInt = #line) throws {
        let scene = figure.scene
        let frame = try XCTUnwrap(scene.frame, file: file, line: line)
        let pixelsPerBase = 1 / frame.scale
        let rows = Self.bodies(scene)
        XCTAssertEqual(
            rows.count, 2, "one row for each read, \(scene.items.count) items, omissions \(scene.omissions)", file: file, line: line
        )
        let pixels = try Pixels(png: try ViewerFigureRasterizer.render(scene, format: .png, pixelScale: 2))
        let snpColor = ViewerFigureTheme.light.color(.readBaseG)
        let snpX = Double(frame.screenPosition(for: Double(Self.readStart + Self.snpOffset))) + pixelsPerBase / 2
        let fillX = Double(frame.screenPosition(for: Double(Self.readStart + Self.snpOffset - 20))) + pixelsPerBase / 2
        for row in rows {
            let midY = row.y + row.height / 2
            let fill = pixels.color(x: fillX, y: midY)
            let snp = pixels.color(x: snpX, y: midY)
            XCTAssertGreaterThan(Self.distance(fill, snpColor), 0.3, "the read fill is not the G colour", file: file, line: line)
            XCTAssertLessThan(
                Self.distance(snp, snpColor), 0.15,
                "the SNP's column at row y \(row.y) carries the G colour, not the read fill \(fill), read \(snp)",
                file: file, line: line
            )
        }
    }

    /// The walk's zoom, 1000 bases across 1856 points, about 1.8 points a base, where the viewer fills each
    /// mismatch's cell in its base colour.
    func testExportGraphicDrawsMismatchesBelowLetterZoom() async throws {
        let bundle = try await makeBundle()
        let figure = try await figure(bundle, start: 1_000, end: 2_000)
        let frame = try XCTUnwrap(figure.scene.frame)
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: frame.scale), .base, "1.844 points a base, the walk's zoom")
        try assertSNPColumnMarked(figure)
        XCTAssertTrue(
            figure.inputURLs.map(\.lastPathComponent).contains("sequence.fa"),
            "the read track reads the reference it compares the reads with, so the record names it"
        )
    }

    /// 1500 bases across 1856 points, about 1.2 points a base, where the viewer draws a tick in the base colour.
    func testExportGraphicDrawsMismatchesInThePackedTier() async throws {
        let bundle = try await makeBundle()
        let figure = try await figure(bundle, start: 500, end: 2_000)
        let frame = try XCTUnwrap(figure.scene.frame)
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: frame.scale), .packed)
        try assertSNPColumnMarked(figure)
    }

    /// 20,000 bases across 1856 points, about 10.8 bases a point. The viewer draws no read and no mismatch mark there,
    /// only its coverage and a line that says to zoom in, so the image draws no read and no mark, and its footnote and
    /// its record say that the reads and their mismatch marks are left out at this zoom.
    func testExportGraphicAtTwentyKilobasesDrawsWhatTheViewerDraws() async throws {
        let bundle = try await makeBundle()
        let figure = try await figure(bundle, start: 0, end: 20_000)
        let scene = figure.scene
        let frame = try XCTUnwrap(scene.frame)
        XCTAssertEqual(ReadTrackRenderer.zoomTier(scale: frame.scale), .coverage)
        XCTAssertTrue(Self.bodies(scene).isEmpty, "no read body, as in the viewer")
        let marks = scene.items.filter { item in
            if case .fill(_, let paint) = item { Self.baseRoles.contains(paint.role) } else { false }
        }
        XCTAssertTrue(marks.isEmpty, "no mismatch mark, as in the viewer")
        let lines = scene.items.compactMap { item -> String? in if case .text(let text) = item { text.string } else { nil } }
        XCTAssertTrue(
            lines.contains { $0.contains("mismatch marks") && $0.contains("bases per point") },
            "the image's footnote says the reads and their mismatch marks are left out at this zoom, lines \(lines)"
        )
        let zoom = scene.omissions.filter { $0.trackID == "reads" && $0.kind == .scaleMode }
        XCTAssertEqual(zoom.count, 1)
        XCTAssertTrue(zoom.first?.reason.contains("mismatch marks") ?? false, "the record and log say so, \(zoom)")
        XCTAssertEqual(zoom.first?.count, 2, "both reads")
    }
}
