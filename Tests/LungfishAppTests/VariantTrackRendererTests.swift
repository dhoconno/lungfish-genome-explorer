// VariantTrackRendererTests.swift - Tests for variant summary bar and genotype row rendering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

// MARK: - VariantTrackRendererTests

@MainActor
final class VariantTrackRendererTests: XCTestCase {

    // MARK: - Helper Methods

    /// Creates a test ReferenceFrame with the given parameters.
    private func makeFrame(
        chromosome: String = "chr1",
        start: Double = 0,
        end: Double = 1000,
        pixelWidth: Int = 800
    ) -> ReferenceFrame {
        ReferenceFrame(chromosome: chromosome, start: start, end: end, pixelWidth: pixelWidth)
    }

    /// Creates a test SequenceAnnotation representing a variant.
    private func makeVariantAnnotation(
        name: String = "rs123",
        chromosome: String = "chr1",
        start: Int = 100,
        end: Int = 101,
        variantType: String = "SNP"
    ) -> SequenceAnnotation {
        SequenceAnnotation(
            type: .gene,
            name: name,
            chromosome: chromosome,
            start: start,
            end: end,
            strand: .unknown,
            qualifiers: ["variant_type": AnnotationQualifier(variantType)]
        )
    }

    /// Creates a bitmap context for rendering tests with CPU-accessible pixel data.
    /// Backing rep for the current test bitmap, retained so pixel data stays valid.
    private var bitmapRep: NSBitmapImageRep?

    /// Creates a bitmap context for rendering tests via NSBitmapImageRep.
    /// AppKit-managed bitmaps work reliably in XCTest even without a display server.
    private func makeBitmapContext(width: Int = 800, height: Int = 100) -> CGContext {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        )!
        bitmapRep = rep
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        return ctx
    }

    /// Reads the RGBA pixel at (x, y) from a bitmap context backed by NSBitmapImageRep.
    /// Returns (r, g, b, a) as UInt8 values.
    /// NSBitmapImageRep uses top-left origin; CG drawing uses bottom-left origin.
    private func pixelColor(at x: Int, y: Int, in ctx: CGContext) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard let rep = bitmapRep, let data = rep.bitmapData else { return (0, 0, 0, 0) }
        // Convert from CG bottom-left y to NSBitmapImageRep top-left y
        let flippedY = rep.pixelsHigh - 1 - y
        let bytesPerRow = rep.bytesPerRow
        let offset = flippedY * bytesPerRow + x * 4
        let r = data[offset]
        let g = data[offset + 1]
        let b = data[offset + 2]
        let a = data[offset + 3]
        return (r, g, b, a)
    }

    /// Checks whether a pixel has been drawn (is not all-zero).
    private func isNonBlack(at x: Int, y: Int, in ctx: CGContext) -> Bool {
        let (r, g, b, _) = pixelColor(at: x, y: y, in: ctx)
        return r > 0 || g > 0 || b > 0
    }

    // MARK: - Layout Height Tests

    func testTotalHeightSummaryBarOnly() {
        let state = SampleDisplayState(showSummaryBar: true)
        let height = VariantTrackRenderer.totalHeight(sampleCount: 0, state: state)
        XCTAssertEqual(height, state.summaryBarHeight)
    }

    func testTotalHeightWithSamplesExpanded() {
        let state = SampleDisplayState(showGenotypeRows: true, showSummaryBar: true, rowHeight: 10)
        let height = VariantTrackRenderer.totalHeight(sampleCount: 5, state: state)
        let expected = state.summaryBarHeight
            + VariantTrackRenderer.summaryToRowGap
            + CGFloat(5) * 10
        XCTAssertEqual(height, expected)
    }

    func testTotalHeightWithSamplesSquished() {
        let state = SampleDisplayState(showGenotypeRows: true, showSummaryBar: true, rowHeight: 2)
        let height = VariantTrackRenderer.totalHeight(sampleCount: 10, state: state)
        let expected = state.summaryBarHeight
            + VariantTrackRenderer.summaryToRowGap
            + CGFloat(10) * 2
        XCTAssertEqual(height, expected)
    }

    func testTotalHeightGenotypeRowsHidden() {
        let state = SampleDisplayState(showGenotypeRows: false, showSummaryBar: true)
        let height = VariantTrackRenderer.totalHeight(sampleCount: 10, state: state)
        XCTAssertEqual(height, state.summaryBarHeight)
    }

    func testRowHeightFromState() {
        let state2 = SampleDisplayState(rowHeight: 2)
        XCTAssertEqual(state2.rowHeight, 2)

        let state12 = SampleDisplayState(rowHeight: 12)
        XCTAssertEqual(state12.rowHeight, 12)

        let state30 = SampleDisplayState(rowHeight: 30)
        XCTAssertEqual(state30.rowHeight, 30)
    }

    func testDefaultRowHeight() {
        let state = SampleDisplayState()
        XCTAssertEqual(state.rowHeight, 12)
    }

    func testAllSampleRowsIncluded() {
        let state = SampleDisplayState(showGenotypeRows: true, showSummaryBar: true, rowHeight: 2)
        let height = VariantTrackRenderer.totalHeight(sampleCount: 200, state: state)
        let expected = state.summaryBarHeight
            + VariantTrackRenderer.summaryToRowGap
            + CGFloat(200) * 2
        XCTAssertEqual(height, expected)
    }

    // MARK: - Summary Bar Rendering Tests

    func testDrawSummaryBarWithEmptyVariants() {
        let frame = makeFrame()
        let ctx = makeBitmapContext()
        VariantTrackRenderer.drawSummaryBar(variants: [], frame: frame, context: ctx, yOffset: 0)

        // Empty variants should draw nothing — center pixel should be black/transparent
        let (r, g, b, _) = pixelColor(at: 400, y: 10, in: ctx)
        XCTAssertEqual(r, 0, "Empty summary bar should not draw at center")
        XCTAssertEqual(g, 0)
        XCTAssertEqual(b, 0)
    }

    func testDrawSummaryBarWithSingleSNP() {
        let frame = makeFrame()
        let ctx = makeBitmapContext()
        let variant = makeVariantAnnotation(start: 500, end: 501, variantType: "SNP")
        VariantTrackRenderer.drawSummaryBar(variants: [variant], frame: frame, context: ctx, yOffset: 0)

        // SNP at position 500 in range 0-1000 with 800px width → pixel ~400
        let snpPx = Int(frame.screenPosition(for: 500))

        let (r, g, b, _) = pixelColor(at: snpPx, y: 10, in: ctx)
        // SNP color is green (0, 0.6, 0.2) → green channel should dominate
        XCTAssertGreaterThan(g, r, "SNP pixel should have green > red")
        XCTAssertGreaterThan(g, 100, "SNP pixel green channel should be significant")
    }

    func testDrawSummaryBarWithMultipleTypes() {
        let frame = makeFrame()
        let ctx = makeBitmapContext()
        let variants = [
            makeVariantAnnotation(name: "rs1", start: 100, end: 101, variantType: "SNP"),
            makeVariantAnnotation(name: "rs2", start: 200, end: 210, variantType: "DEL"),
            makeVariantAnnotation(name: "rs3", start: 300, end: 301, variantType: "INS"),
            makeVariantAnnotation(name: "rs4", start: 400, end: 402, variantType: "MNP"),
            makeVariantAnnotation(name: "rs5", start: 500, end: 503, variantType: "COMPLEX"),
        ]
        VariantTrackRenderer.drawSummaryBar(variants: variants, frame: frame, context: ctx, yOffset: 10)

        // Each variant type should render a colored bar at its pixel position
        let snpPx = Int(frame.screenPosition(for: 100))
        let delPx = Int(frame.screenPosition(for: 200))
        let insPx = Int(frame.screenPosition(for: 300))

        // All three positions should have non-zero pixels at mid-bar height (y=20)
        XCTAssertTrue(isNonBlack(at: snpPx, y: 20, in: ctx), "SNP position should have rendered pixels")
        XCTAssertTrue(isNonBlack(at: delPx, y: 20, in: ctx), "DEL position should have rendered pixels")
        XCTAssertTrue(isNonBlack(at: insPx, y: 20, in: ctx), "INS position should have rendered pixels")
    }

    func testDrawSummaryBarWithOverlappingVariants() {
        let frame = makeFrame()
        let ctx = makeBitmapContext()
        let variants = (0..<20).map { i in
            makeVariantAnnotation(name: "rs\(i)", start: 500, end: 501, variantType: "SNP")
        }
        VariantTrackRenderer.drawSummaryBar(variants: variants, frame: frame, context: ctx, yOffset: 0)
    }

    func testDrawSummaryBarWithZeroPixelWidth() {
        let frame = makeFrame(pixelWidth: 0)
        let ctx = makeBitmapContext()
        let variant = makeVariantAnnotation()
        VariantTrackRenderer.drawSummaryBar(variants: [variant], frame: frame, context: ctx, yOffset: 0)
    }

    func testDrawSummaryBarWithCustomHeight() {
        let frame = makeFrame()
        let ctx = makeBitmapContext(height: 200)
        let variant = makeVariantAnnotation(start: 500, end: 501, variantType: "SNP")
        VariantTrackRenderer.drawSummaryBar(variants: [variant], frame: frame, context: ctx, yOffset: 0, barHeight: 40)

        // Should render at custom height — check pixel at y=20 (within 40px bar)
        let snpPx = Int(frame.screenPosition(for: 500))
        XCTAssertTrue(isNonBlack(at: snpPx, y: 20, in: ctx), "Custom bar height should render")
    }

    // MARK: - Genotype Row Rendering Tests

    func testDrawGenotypeRowsWithEmptyData() {
        let frame = makeFrame()
        let ctx = makeBitmapContext()
        let state = SampleDisplayState()
        let data = GenotypeDisplayData(
            sampleNames: [],
            sites: [],
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 1000)
        )
        VariantTrackRenderer.drawGenotypeRows(
            genotypeData: data, frame: frame, context: ctx, yOffset: 30, state: state
        )
    }

    func testDrawGenotypeRowsWithSamples() {
        let frame = makeFrame(start: 0, end: 1000)
        let ctx = makeBitmapContext(width: 800, height: 200)
        let state = SampleDisplayState(showGenotypeRows: true, rowHeight: 10)
        let sites = [
            VariantSite(position: 100, ref: "A", alt: "G", variantType: "SNP",
                       genotypes: ["S1": .homRef, "S2": .het, "S3": .homAlt]),
            VariantSite(position: 300, ref: "AT", alt: "A", variantType: "DEL",
                       genotypes: ["S1": .het, "S2": .noCall, "S3": .homRef]),
        ]
        let data = GenotypeDisplayData(
            sampleNames: ["S1", "S2", "S3"],
            sites: sites,
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 1000)
        )
        VariantTrackRenderer.drawGenotypeRows(
            genotypeData: data, frame: frame, context: ctx, yOffset: 30, state: state
        )

        // Row height is 10px. yOffset=30.
        // S1 at y=30, S2 at y=40, S3 at y=50.
        // Site 1 at position 100 → pixel ~80, Site 2 at position 300 → pixel ~240.
        let site1Px = Int(frame.screenPosition(for: 100))

        // S2 het at site 1 (y=40+5=45 center): het color = dark blue (34, 12, 253)
        let (r2, _, b2, _) = pixelColor(at: site1Px, y: 45, in: ctx)
        XCTAssertGreaterThan(b2, r2, "Het pixel should have dominant blue channel")
        XCTAssertGreaterThan(b2, 200, "Het pixel should have strong blue")

        // S3 homAlt at site 1 (y=50+5=55 center): modern theme homAlt = deep indigo (0x5B4BA8)
        let (r3, _, b3, _) = pixelColor(at: site1Px, y: 55, in: ctx)
        XCTAssertGreaterThan(b3, r3, "HomAlt pixel should have blue > red (indigo)")
    }

    func testDrawGenotypeRowsHaploidAFColorRamp() {
        func rgb(_ af: Double) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            NSColor(cgColor: VariantTrackRenderer.haploidAFColor(af))?.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (r, g, b)
        }

        let low = rgb(0.05)
        let mid = rgb(0.50)
        let high = rgb(1.00)

        // AF=1.0 should be near black.
        XCTAssertLessThan(max(high.r, max(high.g, high.b)), 0.15)
        // Low AF should be much lighter than high AF.
        XCTAssertGreaterThan(low.r, high.r)
        XCTAssertGreaterThan(low.g, high.g)
        XCTAssertGreaterThan(low.b, high.b)
        // Mid AF should sit in the blue/purple range.
        XCTAssertGreaterThan(mid.b, mid.r)
        XCTAssertGreaterThan(mid.b, mid.g)
    }

    func testHaploidAFColorAtZeroBoundary() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(cgColor: VariantTrackRenderer.haploidAFColor(0.0))?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertGreaterThan(r, 0.90, "AF=0.0 should be near-white")
        XCTAssertGreaterThan(g, 0.90)
        XCTAssertGreaterThan(b, 0.90)
    }

    func testHaploidAFColorNegativeClamped() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(cgColor: VariantTrackRenderer.haploidAFColor(-0.5))?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertGreaterThan(r, 0.90, "Negative AF should clamp to near-white")
    }

    func testHaploidAFColorOverOneClamped() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(cgColor: VariantTrackRenderer.haploidAFColor(2.5))?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertLessThan(r, 0.15, "AF>1.0 should clamp to near-black")
    }

    func testHaploidAFColorMonotonicallyDarkens() {
        func luminance(_ af: Double) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            NSColor(cgColor: VariantTrackRenderer.haploidAFColor(af))?.getRed(&r, green: &g, blue: &b, alpha: &a)
            return 0.299 * r + 0.587 * g + 0.114 * b
        }
        var prevLum = luminance(0.0)
        for i in 1...10 {
            let af = Double(i) / 10.0
            let lum = luminance(af)
            XCTAssertLessThanOrEqual(lum, prevLum + 0.01,
                "Luminance should decrease as AF increases: AF=\(af)")
            prevLum = lum
        }
    }

    func testHaploidAFColorAtStopBoundaries() {
        func rgb(_ af: Double) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            NSColor(cgColor: VariantTrackRenderer.haploidAFColor(af))?.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (r, g, b)
        }
        // Stop at 0.15: light blue (0.80, 0.86, 1.00)
        let s015 = rgb(0.15)
        XCTAssertEqual(s015.r, 0.80, accuracy: 0.05)
        XCTAssertEqual(s015.g, 0.86, accuracy: 0.05)
        XCTAssertEqual(s015.b, 1.00, accuracy: 0.05)

        // Stop at 0.45: purple-blue (0.57, 0.50, 0.94)
        let s045 = rgb(0.45)
        XCTAssertEqual(s045.r, 0.57, accuracy: 0.05)
        XCTAssertEqual(s045.g, 0.50, accuracy: 0.05)
        XCTAssertEqual(s045.b, 0.94, accuracy: 0.05)

        // Stop at 0.75: deep purple (0.35, 0.29, 0.73)
        let s075 = rgb(0.75)
        XCTAssertEqual(s075.r, 0.35, accuracy: 0.05)
        XCTAssertEqual(s075.g, 0.29, accuracy: 0.05)
        XCTAssertEqual(s075.b, 0.73, accuracy: 0.05)
    }

    func testDrawGenotypeRowsWithSmallRowHeight() {
        let frame = makeFrame(start: 0, end: 50_000_000)
        let ctx = makeBitmapContext()
        let state = SampleDisplayState(rowHeight: 2)
        let data = GenotypeDisplayData(
            sampleNames: ["S1"],
            sites: [VariantSite(position: 100, ref: "A", alt: "G", variantType: "SNP",
                               genotypes: ["S1": .het])],
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 50_000_000)
        )
        VariantTrackRenderer.drawGenotypeRows(
            genotypeData: data, frame: frame, context: ctx, yOffset: 30, state: state
        )
    }

    // MARK: - Color Mapping Tests

    func testColorForVariantType_SNP() {
        let color = VariantTrackRenderer.colorForVariantType("SNP")
        XCTAssertNotNil(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(cgColor: color)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertGreaterThan(g, r, "SNP color should have more green than red")
    }

    func testColorForVariantType_DEL() {
        let color = VariantTrackRenderer.colorForVariantType("DEL")
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(cgColor: color)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertGreaterThan(r, g, "DEL color should have more red than green")
    }

    func testColorForVariantType_INS() {
        let color = VariantTrackRenderer.colorForVariantType("INS")
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(cgColor: color)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertGreaterThan(b, g, "INS color should have more blue than green")
    }

    func testColorForVariantType_MNP() {
        let color = VariantTrackRenderer.colorForVariantType("MNP")
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(cgColor: color)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertGreaterThan(r, b, "MNP color should have more red than blue (orange)")
    }

    func testColorForVariantType_Unknown() {
        let color = VariantTrackRenderer.colorForVariantType("UNKNOWN")
        XCTAssertNotNil(color)
    }

    func testColorForVariantType_AllDistinct() {
        let types = ["SNP", "INS", "DEL", "MNP"]
        var colors: [CGColor] = []
        for t in types {
            let c = VariantTrackRenderer.colorForVariantType(t)
            // Each should be distinct from prior
            for existing in colors {
                XCTAssertNotEqual(c, existing, "Color for \(t) should be distinct")
            }
            colors.append(c)
        }
    }

    // MARK: - GenotypeDisplayCall Tests

    func testGenotypeDisplayCallAllCases() {
        let cases: [GenotypeDisplayCall] = [.homRef, .het, .homAlt, .noCall]
        XCTAssertEqual(cases.count, 4)
    }

    func testGenotypeDisplayCallEquatable() {
        XCTAssertEqual(GenotypeDisplayCall.homRef, GenotypeDisplayCall.homRef)
        XCTAssertNotEqual(GenotypeDisplayCall.het, GenotypeDisplayCall.homAlt)
    }

    // MARK: - VariantSite Tests

    func testVariantSiteCreation() {
        let site = VariantSite(
            position: 1000, ref: "A", alt: "G", variantType: "SNP",
            genotypes: ["sample1": .het, "sample2": .homRef]
        )
        XCTAssertEqual(site.position, 1000)
        XCTAssertEqual(site.ref, "A")
        XCTAssertEqual(site.alt, "G")
        XCTAssertEqual(site.variantType, "SNP")
        XCTAssertEqual(site.genotypes.count, 2)
        XCTAssertEqual(site.genotypes["sample1"], .het)
        XCTAssertEqual(site.genotypes["sample2"], .homRef)
    }

    // MARK: - GenotypeDisplayData Tests

    func testGenotypeDisplayDataCreation() {
        let data = GenotypeDisplayData(
            sampleNames: ["S1", "S2"],
            sites: [VariantSite(position: 100, ref: "A", alt: "G", variantType: "SNP",
                               genotypes: ["S1": .het, "S2": .homAlt])],
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 1000)
        )
        XCTAssertEqual(data.sampleNames.count, 2)
        XCTAssertEqual(data.sites.count, 1)
        XCTAssertEqual(data.region.chromosome, "chr1")
    }

    func testGenotypeDisplayDataEmpty() {
        let data = GenotypeDisplayData(
            sampleNames: [],
            sites: [],
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 1000)
        )
        XCTAssertTrue(data.sampleNames.isEmpty)
        XCTAssertTrue(data.sites.isEmpty)
    }

    // MARK: - Layout Constants Sanity

    func testLayoutConstantsArePositive() {
        XCTAssertGreaterThan(VariantTrackRenderer.defaultSummaryBarHeight, 0)
        XCTAssertGreaterThanOrEqual(VariantTrackRenderer.summaryToRowGap, 0)
        XCTAssertGreaterThan(VariantTrackRenderer.minPixelsPerVariant, 0)
    }

    func testDefaultRowHeightIsReasonable() {
        let state = SampleDisplayState()
        XCTAssertEqual(state.rowHeight, 12)
        XCTAssertEqual(state.summaryBarHeight, 20)
    }

    // MARK: - Large Data Rendering

    func testDrawSummaryBarWithManyVariants() {
        let frame = makeFrame(start: 0, end: 10000, pixelWidth: 1000)
        let ctx = makeBitmapContext(width: 1000, height: 100)
        let types = ["SNP", "INS", "DEL", "MNP"]
        let variants = (0..<500).map { i -> SequenceAnnotation in
            makeVariantAnnotation(name: "rs\(i)", start: i * 20, end: i * 20 + 1, variantType: types[i % types.count])
        }
        VariantTrackRenderer.drawSummaryBar(variants: variants, frame: frame, context: ctx, yOffset: 0)
    }

    func testDrawGenotypeRowsWithManySamples() {
        let frame = makeFrame(start: 0, end: 1000)
        let ctx = makeBitmapContext(width: 800, height: 500)
        let state = SampleDisplayState(showGenotypeRows: true, rowHeight: 2)
        let sampleNames = (0..<150).map { "sample_\($0)" }
        let calls: [GenotypeDisplayCall] = [.homRef, .het, .homAlt, .noCall]
        let sites = [
            VariantSite(
                position: 500, ref: "A", alt: "G", variantType: "SNP",
                genotypes: Dictionary(uniqueKeysWithValues: sampleNames.enumerated().map { (i, name) in
                    (name, calls[i % calls.count])
                })
            )
        ]
        let data = GenotypeDisplayData(
            sampleNames: sampleNames,
            sites: sites,
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 1000)
        )
        VariantTrackRenderer.drawGenotypeRows(
            genotypeData: data, frame: frame, context: ctx, yOffset: 30, state: state
        )
    }

    // MARK: - Genotype Classification Tests

    func testGenotypeClassification_HomRef() {
        let call = classifyGenotypeForTesting(genotype: "0/0", a1: 0, a2: 0)
        XCTAssertEqual(call, .homRef)
    }

    func testGenotypeClassification_Het() {
        let call = classifyGenotypeForTesting(genotype: "0/1", a1: 0, a2: 1)
        XCTAssertEqual(call, .het)
    }

    func testGenotypeClassification_HomAlt() {
        let call = classifyGenotypeForTesting(genotype: "1/1", a1: 1, a2: 1)
        XCTAssertEqual(call, .homAlt)
    }

    func testGenotypeClassification_NoCall_Missing() {
        let call = classifyGenotypeForTesting(genotype: "./.", a1: -1, a2: -1)
        XCTAssertEqual(call, .noCall)
    }

    func testGenotypeClassification_NoCall_NilGenotype() {
        let call = classifyGenotypeForTesting(genotype: nil, a1: -1, a2: -1)
        XCTAssertEqual(call, .noCall)
    }

    func testGenotypeClassification_NoCall_Dot() {
        let call = classifyGenotypeForTesting(genotype: ".", a1: -1, a2: -1)
        XCTAssertEqual(call, .noCall)
    }

    func testGenotypeClassification_NoCall_PhasedMissing() {
        let call = classifyGenotypeForTesting(genotype: ".|.", a1: -1, a2: -1)
        XCTAssertEqual(call, .noCall)
    }

    func testGenotypeClassification_PhasedHet() {
        let call = classifyGenotypeForTesting(genotype: "0|1", a1: 0, a2: 1)
        XCTAssertEqual(call, .het)
    }

    func testGenotypeClassification_MultiAllelicHomAlt() {
        let call = classifyGenotypeForTesting(genotype: "2/2", a1: 2, a2: 2)
        XCTAssertEqual(call, .homAlt)
    }

    func testGenotypeClassification_MultiAllelicHet() {
        let call = classifyGenotypeForTesting(genotype: "1/2", a1: 1, a2: 2)
        XCTAssertEqual(call, .het)
    }

    func testGenotypeClassification_NoCall_EmptyString() {
        let call = classifyGenotypeForTesting(genotype: "", a1: -1, a2: -1)
        XCTAssertEqual(call, .noCall)
    }

    func testGenotypeClassification_NoCall_BothAllelesMissing() {
        // genotype string is "0/1" but alleles are both -1 → noCall
        let call = classifyGenotypeForTesting(genotype: "0/1", a1: -1, a2: -1)
        XCTAssertEqual(call, .noCall)
    }

    func testGenotypeClassification_NoCall_OneAlleleMissing() {
        // genotype string is "0/1" but allele2 is -1 → noCall (partial missing)
        let call = classifyGenotypeForTesting(genotype: "0/1", a1: 0, a2: -1)
        XCTAssertEqual(call, .noCall)
    }

    func testGenotypeClassification_ClassifyStaticMethod() {
        // Directly test the static method on GenotypeDisplayCall
        XCTAssertEqual(GenotypeDisplayCall.classify(genotype: "0/0", allele1: 0, allele2: 0), .homRef)
        XCTAssertEqual(GenotypeDisplayCall.classify(genotype: "0/1", allele1: 0, allele2: 1), .het)
        XCTAssertEqual(GenotypeDisplayCall.classify(genotype: "1/1", allele1: 1, allele2: 1), .homAlt)
        XCTAssertEqual(GenotypeDisplayCall.classify(genotype: nil, allele1: -1, allele2: -1), .noCall)
        XCTAssertEqual(GenotypeDisplayCall.classify(genotype: "0/1", allele1: -1, allele2: 1), .noCall)
    }

    // MARK: - Helper for genotype classification

    /// Reproduces the classification logic from the free function for testing.
    private func classifyGenotypeForTesting(genotype: String?, a1: Int, a2: Int) -> GenotypeDisplayCall {
        GenotypeDisplayCall.classify(genotype: genotype, allele1: a1, allele2: a2)
    }
}

// MARK: - VariantTrackRendererEdgeCaseTests

@MainActor
final class VariantTrackRendererEdgeCaseTests: XCTestCase {

    private func makeFrame(start: Double = 0, end: Double = 1000, pixelWidth: Int = 800) -> ReferenceFrame {
        ReferenceFrame(chromosome: "chr1", start: start, end: end, pixelWidth: pixelWidth)
    }

    private func makeBitmapContext(width: Int = 800, height: Int = 100) -> CGContext {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
    }

    func testSummaryBarWithVariantsOutsideVisibleRange() {
        let frame = makeFrame(start: 0, end: 1000)
        let ctx = makeBitmapContext()
        let ann = SequenceAnnotation(
            type: .gene,
            name: "rs_far",
            chromosome: "chr1",
            start: 5000,
            end: 5001,
            strand: .unknown,
            qualifiers: ["variant_type": AnnotationQualifier("SNP")]
        )
        VariantTrackRenderer.drawSummaryBar(variants: [ann], frame: frame, context: ctx, yOffset: 0)
    }

    func testSummaryBarWithDeletionSpanningEntireView() {
        let frame = makeFrame(start: 0, end: 1000)
        let ctx = makeBitmapContext()
        let ann = SequenceAnnotation(
            type: .gene,
            name: "del_large",
            chromosome: "chr1",
            start: 0,
            end: 1000,
            strand: .unknown,
            qualifiers: ["variant_type": AnnotationQualifier("DEL")]
        )
        VariantTrackRenderer.drawSummaryBar(variants: [ann], frame: frame, context: ctx, yOffset: 0)
    }

    func testGenotypeRowsWithMissingSampleInGenotypes() {
        let frame = makeFrame()
        let ctx = makeBitmapContext(height: 200)
        let state = SampleDisplayState(showGenotypeRows: true, rowHeight: 10)
        let sites = [
            VariantSite(position: 500, ref: "A", alt: "G", variantType: "SNP",
                       genotypes: ["S1": .het])  // S2 not present
        ]
        let data = GenotypeDisplayData(
            sampleNames: ["S1", "S2"],
            sites: sites,
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 1000)
        )
        VariantTrackRenderer.drawGenotypeRows(
            genotypeData: data, frame: frame, context: ctx, yOffset: 30, state: state
        )
    }

    func testGenotypeRowsWithUnboundedHeightAndScroll() {
        let frame = makeFrame()
        let ctx = makeBitmapContext(height: 200)
        let state = SampleDisplayState(showGenotypeRows: true, rowHeight: 8)
        let sites = [
            VariantSite(position: 500, ref: "A", alt: "G", variantType: "SNP",
                       genotypes: ["S1": .het, "S2": .homAlt])
        ]
        let data = GenotypeDisplayData(
            sampleNames: ["S1", "S2"],
            sites: sites,
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 1000)
        )

        VariantTrackRenderer.drawGenotypeRows(
            genotypeData: data,
            frame: frame,
            context: ctx,
            yOffset: 30,
            state: state,
            scrollOffset: .infinity,
            availableHeight: .greatestFiniteMagnitude
        )
    }

    func testTotalHeightWithDefaultState() {
        let state = SampleDisplayState(showGenotypeRows: true)
        let height = VariantTrackRenderer.totalHeight(sampleCount: 3, state: state)
        let expected = state.summaryBarHeight
            + VariantTrackRenderer.summaryToRowGap
            + 3 * state.rowHeight
        XCTAssertEqual(height, expected)
    }

    func testTotalGenotypeHeightWithSmallRows() {
        let state = SampleDisplayState(showGenotypeRows: true, rowHeight: 2)
        let height = VariantTrackRenderer.totalGenotypeHeight(sampleCount: 5, state: state)
        XCTAssertEqual(height, 10)
    }

    func testTotalGenotypeHeightWithLargeRows() {
        let state = SampleDisplayState(showGenotypeRows: true, rowHeight: 30)
        let height = VariantTrackRenderer.totalGenotypeHeight(sampleCount: 5, state: state)
        XCTAssertEqual(height, 150)
    }

    func testCustomSummaryBarHeight() {
        let state = SampleDisplayState(summaryBarHeight: 40)
        let height = VariantTrackRenderer.totalHeight(sampleCount: 0, state: state)
        XCTAssertEqual(height, 40)
    }

    func testDrawSummaryBarWithNegativeYOffset() {
        let frame = makeFrame()
        let ctx = makeBitmapContext()
        let variant = SequenceAnnotation(
            type: .gene, name: "rs1", chromosome: "chr1",
            start: 500, end: 501, strand: .unknown,
            qualifiers: ["variant_type": AnnotationQualifier("SNP")]
        )
        // Negative offset should not crash
        VariantTrackRenderer.drawSummaryBar(variants: [variant], frame: frame, context: ctx, yOffset: -10)
    }

    func testDrawGenotypeRowsNoSitesButHasSamples() {
        let frame = makeFrame()
        let ctx = makeBitmapContext(height: 200)
        let state = SampleDisplayState(showGenotypeRows: true, rowHeight: 10)
        let data = GenotypeDisplayData(
            sampleNames: ["S1", "S2"],
            sites: [],  // No variant sites
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 1000)
        )
        // Should return early without crash (sites is empty)
        VariantTrackRenderer.drawGenotypeRows(
            genotypeData: data, frame: frame, context: ctx, yOffset: 30, state: state
        )
    }

    func testSummaryBarWithSinglePixelWidth() {
        let frame = makeFrame(pixelWidth: 1)
        let ctx = makeBitmapContext(width: 1, height: 100)
        let variant = SequenceAnnotation(
            type: .gene, name: "rs1", chromosome: "chr1",
            start: 500, end: 501, strand: .unknown,
            qualifiers: ["variant_type": AnnotationQualifier("SNP")]
        )
        VariantTrackRenderer.drawSummaryBar(variants: [variant], frame: frame, context: ctx, yOffset: 0)
    }
}
