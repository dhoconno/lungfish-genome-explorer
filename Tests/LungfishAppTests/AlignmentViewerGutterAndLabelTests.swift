// AlignmentViewerGutterAndLabelTests.swift - The coverage label and the reads keep to the data area
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// TV-ALIGN (sub-phase 5.6, ruling UX-ALIGN). The alignment viewer drew two things outside its data
// area. The coverage strip's right label "max: <n>x  mean: <n.n>x" ended 4 pt from the view's right
// edge, so the 12 pt right band painted over its last 8 pt, which hid the unit and half of the
// mean's tenths digit. A read that starts left of the window drew into the label gutter, because the
// read clip began at x 0. Every test here reads a drawn bitmap and never source text.

import AppKit
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class AlignmentViewerGutterAndLabelTests: XCTestCase {
    /// The view is 800 pt wide with a 60 pt gutter and the viewer's 12 pt right band. The window shows
    /// 728 bases, the width of the data area, so the scale is exactly 1 base per point and reads draw
    /// as plain filled bars (the packed tier runs above 0.6 and up to 2 bases per point).
    private let viewWidth: CGFloat = 800
    private let leadingInset: CGFloat = 60
    private let trailingInset: CGFloat = 12
    private let windowBases = 728
    private let bundleChromosome = "tvalign-chr1"
    private var dataRight: CGFloat { viewWidth - trailingInset }

    private struct Fixture {
        let controller: ViewerViewController
        let view: SequenceViewerView
    }

    // MARK: - Item 1, the coverage label

    func testDetachedCoverageLabelEndsInsideTheDataArea() async throws {
        let start = 50
        let points = depth(from: start, full: 66, count: 691, last: 34)
        let text = try fixtureLabel(points, start: start, equals: "max: 66x  mean: 62.7x")
        let fixture = try await makeDetachedViewer(windowStart: start, depth: points, reads: [])
        let rep = try render(fixture.view)
        try assertLabelInsideTheDataArea(rep, stripTop: fixture.view.readTrackY, text: text)
    }

    /// A label that ends in a "1x" has the thinnest last digit, so a cut there is the easiest to miss.
    func testDetachedCoverageLabelEndingInOneXEndsInsideTheDataArea() async throws {
        let start = 50
        let points = depth(from: start, full: 49, count: 655, last: 5)
        let text = try fixtureLabel(points, start: start, equals: "max: 49x  mean: 44.1x")
        let fixture = try await makeDetachedViewer(windowStart: start, depth: points, reads: [])
        let rep = try render(fixture.view)
        try assertLabelInsideTheDataArea(rep, stripTop: fixture.view.readTrackY, text: text)
    }

    /// The bundle path paints the right band over the strip after the label, so the band hides ink
    /// instead of showing it. A label that ends inside the data area leaves clear columns before the band.
    func testBundleCoverageLabelStopsShortOfTheRightBand() async throws {
        let start = 1_000
        let points = depth(from: start, full: 66, count: 691, last: 34)
        _ = try fixtureLabel(points, start: start, equals: "max: 66x  mean: 62.7x")
        let fixture = try await makeBundleViewer(windowStart: start, depth: points, reads: [])
        let rep = try render(fixture.view)
        let stripTop = fixture.view.readTrackY
        let rows = (stripTop + 1)..<(stripTop + 15)
        let background = pixel(rep, x: 400, y: stripTop + 6)
        XCTAssertNil(
            inkExtent(in: rep, viewWidth: viewWidth, xs: (dataRight - 3)..<dataRight, ys: rows, background: background),
            "the label's ink runs to the band's left edge, so the band covers the end of the label"
        )
        XCTAssertNotNil(
            inkExtent(in: rep, viewWidth: viewWidth, xs: (dataRight - 30)..<(dataRight - 3), ys: rows, background: background),
            "the label must still be drawn left of the band"
        )
    }

    // MARK: - Item 2, the reads

    /// A read that starts 20 bases before the window lies 20 pt left of the data area's left edge, so it
    /// reaches into the gutter unless the read clip begins at the gutter's edge. The fill must begin
    /// there and the read must still end at its true position, so the clip crops and never shifts it.
    func testBundleReadStartingBeforeTheWindowDrawsNothingInTheGutter() async throws {
        let start = 1_000
        let reads = [read("left", chromosome: bundleChromosome, position: start - 20)]
        let fixture = try await makeBundleViewer(windowStart: start, depth: [], reads: reads)
        let rep = try render(fixture.view)
        let extent = try XCTUnwrap(readInkExtent(rep, view: fixture.view, xs: 0..<dataRight), "no read was drawn")
        XCTAssertEqual(extent.minX, leadingInset, accuracy: 1, "the read's fill must begin at the gutter's edge")
        XCTAssertEqual(extent.maxX, leadingInset + 80, accuracy: 1.5, "the read must still end at its true position")
    }

    func testDetachedReadStartingBeforeTheWindowDrawsNothingInTheGutter() async throws {
        let start = 50
        let reads = [read("left", chromosome: "chr1", position: start - 20)]
        let fixture = try await makeDetachedViewer(windowStart: start, depth: [], reads: reads)
        let rep = try render(fixture.view)
        let extent = try XCTUnwrap(readInkExtent(rep, view: fixture.view, xs: 0..<viewWidth), "no read was drawn")
        XCTAssertEqual(extent.minX, leadingInset, accuracy: 1, "the read's fill must begin at the gutter's edge")
        XCTAssertEqual(extent.maxX, leadingInset + 80, accuracy: 1.5, "the read must still end at its true position")
    }

    /// The bundle path hides a read's overflow under the right band, but the detached path paints no
    /// band, so only its own clip keeps a read that runs 72 bases past the window out of the margin.
    func testDetachedReadRunningPastTheWindowDrawsNothingInTheRightBand() async throws {
        let start = 50
        let reads = [read("right", chromosome: "chr1", position: start + 700)]
        let fixture = try await makeDetachedViewer(windowStart: start, depth: [], reads: reads)
        let rep = try render(fixture.view)
        let extent = try XCTUnwrap(readInkExtent(rep, view: fixture.view, xs: 400..<viewWidth), "no read was drawn")
        XCTAssertEqual(extent.minX, leadingInset + 700, accuracy: 1.5, "the read must still begin at its true position")
        XCTAssertLessThanOrEqual(extent.maxX, dataRight + 1, "no read pixel may sit in the 12 pt right band")
    }

    // MARK: - The graphic export stays as it is

    /// The graphic export draws the same strip with no right band after it, and its label prints whole
    /// (a run of `lungfish-cli bundle export-graphic` on the demo bundle, passed on by the coordinator).
    /// So the fix changes the live view's call and never the shared function's default. This pin holds
    /// the export's label 4 pt inside the figure's right edge, even with a 12 pt trailing inset on the
    /// figure frame, which is where a fix inside `drawCoverage` that read `frame.trailingInset` would move it.
    func testTheGraphicExportKeepsItsCoverageLabelWhereItIs() throws {
        let width = 900
        let height = 40
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let context = graphics.cgContext
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let frame = ViewerFigureFrame(
            chromosome: "chr1", start: 0, end: Double(windowBases), pixelWidth: width, sequenceLength: 5_000,
            leadingInset: leadingInset, trailingInset: trailingInset
        )
        ReadTrackRenderer.drawCoverage(
            depthPoints: depth(from: 0, full: 66, count: 691, last: 34), regionStart: 0, regionEnd: windowBases,
            frame: frame, context: context, figureTheme: ViewerFigureTheme(appearance: .light),
            rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        )
        graphics.flushGraphics()
        let extent = try XCTUnwrap(
            inkExtent(in: rep, viewWidth: CGFloat(width), xs: 450..<CGFloat(width), ys: 1..<15, background: .clear),
            "the export's strip drew no label"
        )
        XCTAssertEqual(extent.maxX, CGFloat(width) - 4, accuracy: 1.5, "the export's label must keep its place")
    }

    // MARK: - A click outside the data area

    /// The read clips keep reads out of the gutter and the right band, so a click, a hover and a
    /// right-click there must find no read. A click on the drawn part of the same read still finds it.
    func testAClickOutsideTheDataAreaSelectsNoRead() async throws {
        let start = 50
        let cases: [(name: String, position: Int, outside: CGFloat, inside: CGFloat)] = [
            (name: "left", position: start - 20, outside: leadingInset - 10, inside: leadingInset + 20),
            (name: "right", position: start + 700, outside: dataRight + 4, inside: dataRight - 20),
        ]
        for item in cases {
            let fixture = try await makeDetachedViewer(
                windowStart: start, depth: [], reads: [read(item.name, chromosome: "chr1", position: item.position)]
            )
            _ = try render(fixture.view)
            let y = fixture.view.testLastRenderedReadY + 2
            XCTAssertEqual(
                fixture.view.testReadAtPoint(NSPoint(x: item.inside, y: y))?.name, item.name,
                "a click on the drawn part of the \(item.name) read must select it"
            )
            XCTAssertNil(
                fixture.view.testReadAtPoint(NSPoint(x: item.outside, y: y)),
                "a click at x \(item.outside) lies outside the data area, so it must select no read"
            )
        }
    }

    /// The x extent of the read ink in the first read row. `xs` stops at the data area's right edge for
    /// the bundle path, where the right band paints pixels of its own.
    private func readInkExtent(
        _ rep: NSBitmapImageRep, view: SequenceViewerView, xs: Range<CGFloat>
    ) -> (minX: CGFloat, maxX: CGFloat)? {
        let readY = view.testLastRenderedReadY
        let rowHeight = ReadTrackRenderer
            .layoutMetrics(verticalCompress: view.verticallyCompressContigSetting).packedReadHeight
        let background = pixel(rep, x: 650, y: readY + rowHeight / 2)
        return inkExtent(in: rep, viewWidth: viewWidth, xs: xs, ys: readY..<(readY + rowHeight), background: background)
    }

    // MARK: - Fixtures

    /// Depth points whose mean over the 728-base window is `(full * count + last) / 728`.
    private func depth(from start: Int, full: Int, count: Int, last: Int) -> [ReadTrackRenderer.CoveragePoint] {
        var points = (0..<count).map { ReadTrackRenderer.CoveragePoint(position: start + $0, depth: full) }
        points.append(ReadTrackRenderer.CoveragePoint(position: start + count, depth: last))
        return points
    }

    /// The label the strip must draw, built from the numbers `summarizeCoverage` gives for the same
    /// points, so the drawn mean and maximum are tied to that function's value. The fixture must give
    /// the label the test is about, or the test would pass for the wrong text.
    private func fixtureLabel(
        _ points: [ReadTrackRenderer.CoveragePoint], start: Int, equals expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let stats = ReadTrackRenderer.summarizeCoverage(
            depthPoints: points, regionStart: start, regionEnd: start + windowBases
        )
        let text = "max: \(stats.maxDepth)x  mean: \(String(format: "%.1f", stats.meanDepth))x"
        XCTAssertEqual(text, expected, "the fixture's depth gives another label", file: file, line: line)
        return text
    }

    private func read(_ name: String, chromosome: String, position: Int) -> AlignedRead {
        AlignedRead(
            name: name, flag: 0, chromosome: chromosome, position: position, mapq: 60,
            cigar: [CIGAROperation(op: .match, length: 100)],
            sequence: String(repeating: "ACGT", count: 25),
            qualities: Array(repeating: UInt8(30), count: 100)
        )
    }

    /// A reference bundle viewer drawn through the real `draw(_:)`, with the gutter overlay and the
    /// right band the bundle path paints. With reads, the first draw hands the pack to its background
    /// task and the wait lets it land, so the draw the test measures paints the rows.
    private func makeBundleViewer(
        windowStart: Int, depth: [ReadTrackRenderer.CoveragePoint], reads: [AlignedRead]
    ) async throws -> Fixture {
        let chromLength = 20_000
        let bundleURL = try makeMinimalReferenceBundle(chromosome: bundleChromosome, length: chromLength)
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let controller = ViewerViewController()
        controller.loadView()
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: viewWidth, height: 500))
        viewer.viewController = controller
        viewer.setReferenceBundle(bundle)
        let frame = ReferenceFrame(
            chromosome: bundleChromosome, start: Double(windowStart), end: Double(windowStart + windowBases),
            pixelWidth: Int(viewWidth), sequenceLength: chromLength
        )
        frame.leadingInset = leadingInset
        frame.trailingInset = trailingInset
        controller.referenceFrame = frame
        let whole = GenomicRegion(chromosome: bundleChromosome, start: 0, end: chromLength)
        viewer.cachedAnnotationRegion = whole
        viewer.cachedBundleAnnotations = []
        viewer.cachedVariantRegion = whole
        viewer.cachedVariantAnnotations = []
        viewer.cachedDepthRegion = whole
        viewer.cachedDepthPoints = depth
        viewer.cachedReadRegion = whole
        viewer.alignmentDataProviders = [(
            trackId: "tvalign-track",
            provider: AlignmentDataProvider(
                alignmentPath: bundleURL.appendingPathComponent("tvalign.bam").path,
                indexPath: bundleURL.appendingPathComponent("tvalign.bam.bai").path
            )
        )]
        viewer.cachedAlignedReads = reads
        viewer.layoutSubtreeIfNeeded()
        if !reads.isEmpty {
            _ = try render(viewer)
            await waitUntil(budget: .lookup) {
                viewer.inFlightPackKey == nil && viewer.cachedPackedReadLayout != nil
            }
        }
        return Fixture(controller: controller, view: viewer)
    }

    /// A detached (classifier evidence) viewer drawn through the real `draw(_:)`. The path paints no
    /// gutter overlay and no right band, so nothing hides what the strip and the reads draw.
    private func makeDetachedViewer(
        windowStart: Int, depth: [ReadTrackRenderer.CoveragePoint], reads: [AlignedRead]
    ) async throws -> Fixture {
        let directory = try TestTempDirectory.make(prefix: "tvalign-detached")
        addTeardownBlock { TestTempDirectory.cleanup(directory) }
        let bam = directory.appendingPathComponent("evidence.bam")
        let source = SequenceViewerView.DetachedAlignmentSource(
            identityURL: bam,
            contig: .init(name: "chr1", length: 5_000),
            provider: AlignmentDataProvider(alignmentPath: bam.path, indexPath: "\(bam.path).bai"),
            referenceSequence: nil
        )
        let controller = ViewerViewController()
        _ = controller.view
        XCTAssertTrue(controller.displayDetachedAlignment(source))
        let view = try XCTUnwrap(controller.viewerView)
        view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: 600)
        let frame = try XCTUnwrap(controller.referenceFrame)
        frame.start = Double(windowStart)
        frame.end = Double(windowStart + windowBases)
        frame.pixelWidth = Int(viewWidth)
        frame.leadingInset = leadingInset
        frame.trailingInset = trailingInset
        await waitUntil(budget: .lookup) { view.detachedEvidenceIsCurrent(source) }
        XCTAssertTrue(view.detachedEvidenceIsCurrent(source), "the evidence monitor never marked the source current")
        let region = GenomicRegion(chromosome: "chr1", start: windowStart, end: windowStart + windowBases)
        view.cachedDepthRegion = region
        view.cachedDepthPoints = depth
        view.testSetCachedAlignedReads(reads)
        view.cachedReadRegion = region
        if !reads.isEmpty {
            _ = view.prepareDetachedReadLayout(region: region, frame: frame)
            await waitUntil(budget: .lookup) {
                view.inFlightPackKey == nil && view.cachedPackedReadLayout != nil
                    && view.cachedPackKey?.readGeneration == view.testCachedReadSetGeneration
            }
        }
        return Fixture(controller: controller, view: view)
    }

    private func makeMinimalReferenceBundle(chromosome: String, length: Int) throws -> URL {
        let directory = try TestTempDirectory.make(prefix: "tvalign-bundle")
        addTeardownBlock { TestTempDirectory.cleanup(directory) }
        let bundleURL = directory.appendingPathComponent("tvalign.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        let sequence = String(repeating: "ACGT", count: length / 4)
        let header = ">\(chromosome)\n"
        try (header + sequence + "\n").write(
            to: genomeDir.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8
        )
        try "\(chromosome)\t\(sequence.count)\t\(header.utf8.count)\t\(sequence.count)\t\(sequence.count + 1)\n"
            .write(to: genomeDir.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "TV-ALIGN Reference",
            identifier: "org.lungfish.tests.tv-align",
            source: SourceInfo(organism: "Test organism", assembly: "tvalign"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [
                    ChromosomeInfo(
                        name: chromosome, length: Int64(length), offset: Int64(header.utf8.count),
                        lineBases: sequence.count, lineWidth: sequence.count + 1
                    )
                ]
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    // MARK: - Reading a drawn bitmap

    /// One call of the view's own `draw(_:)` into a flipped bitmap context at one pixel per point, so a
    /// view y is the bitmap row from the top. The call goes straight to `draw(_:)` because the controller
    /// keeps the detached viewer hidden, and `cacheDisplay` paints nothing for a hidden view.
    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let width = Int(view.bounds.width)
        let height = Int(view.bounds.height)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let base = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        base.cgContext.translateBy(x: 0, y: CGFloat(height))
        base.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: base.cgContext, flipped: true)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func pixel(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / viewWidth
        return rep.colorAt(x: Int(x * scale), y: Int(y * scale)) ?? .clear
    }

    /// The x extent, in view points, of every pixel inside `xs` and `ys` that differs from `background`,
    /// or nil when none does.
    private func inkExtent(
        in rep: NSBitmapImageRep, viewWidth: CGFloat, xs: Range<CGFloat>, ys: Range<CGFloat>, background: NSColor
    ) -> (minX: CGFloat, maxX: CGFloat)? {
        let scale = CGFloat(rep.pixelsWide) / viewWidth
        let columns = max(0, Int((xs.lowerBound * scale).rounded(.down)))..<min(rep.pixelsWide, Int((xs.upperBound * scale).rounded(.up)))
        let rows = max(0, Int((ys.lowerBound * scale).rounded(.down)))..<min(rep.pixelsHigh, Int((ys.upperBound * scale).rounded(.up)))
        guard let reference = background.usingColorSpace(.deviceRGB) else { return nil }
        var first: Int?
        var last: Int?
        for row in rows {
            for column in columns {
                guard let color = rep.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { continue }
                let difference = max(
                    abs(color.redComponent - reference.redComponent),
                    abs(color.greenComponent - reference.greenComponent),
                    abs(color.blueComponent - reference.blueComponent),
                    abs(color.alphaComponent - reference.alphaComponent)
                )
                if difference > 0.08 {
                    first = min(first ?? column, column)
                    last = max(last ?? column, column)
                }
            }
        }
        guard let first, let last else { return nil }
        return (CGFloat(first) / scale, CGFloat(last + 1) / scale)
    }

    /// The label's ink in the strip's text rows, right of the middle so the left legend never counts.
    /// The ink must end left of the data area's right edge, still sit within 8 pt of it, and be as wide
    /// as the text it should read, so no digit or unit is missing.
    private func assertLabelInsideTheDataArea(
        _ rep: NSBitmapImageRep, stripTop: CGFloat, text: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let background = pixel(rep, x: 400, y: stripTop + 6)
        let extent = try XCTUnwrap(
            inkExtent(
                in: rep, viewWidth: viewWidth, xs: 400..<viewWidth,
                ys: (stripTop + 1)..<(stripTop + 15), background: background
            ),
            "the strip drew no label", file: file, line: line
        )
        XCTAssertLessThan(
            extent.maxX, dataRight,
            "the label's ink must end left of the data area's right edge at \(dataRight)", file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(
            extent.maxX, dataRight - 8, "the label must stay within 8 pt of the data area's edge", file: file, line: line
        )
        let font = ViewerFigureTrackText.font(.system, size: 9)
        let expectedWidth = CGFloat(ViewerFigureTrackText.width(text, font: font))
        XCTAssertEqual(
            extent.maxX - extent.minX, expectedWidth, accuracy: 3,
            "the drawn label must be as wide as \"\(text)\"", file: file, line: line
        )
    }
}
