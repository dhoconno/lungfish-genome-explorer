// VariantTrackRendererTests.swift - Tests for variant summary bar and genotype row rendering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

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

    /// Creates a bitmap context for rendering tests.
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

    // MARK: - Layout Height Tests

    func testTotalHeightSummaryBarOnly() {
        let state = SampleDisplayState()
        let height = VariantTrackRenderer.totalHeight(sampleCount: 0, scale: 100.0, state: state)
        XCTAssertEqual(height, VariantTrackRenderer.summaryBarHeight)
    }

    func testTotalHeightWithSamplesExpanded() {
        let state = SampleDisplayState(showGenotypeRows: true, rowHeightMode: .expanded)
        let height = VariantTrackRenderer.totalHeight(sampleCount: 5, scale: 100.0, state: state)
        let expected = VariantTrackRenderer.summaryBarHeight
            + VariantTrackRenderer.summaryToRowGap
            + CGFloat(5) * VariantTrackRenderer.expandedRowHeight
        XCTAssertEqual(height, expected)
    }

    func testTotalHeightWithSamplesSquished() {
        let state = SampleDisplayState(showGenotypeRows: true, rowHeightMode: .squished)
        let height = VariantTrackRenderer.totalHeight(sampleCount: 10, scale: 100.0, state: state)
        let expected = VariantTrackRenderer.summaryBarHeight
            + VariantTrackRenderer.summaryToRowGap
            + CGFloat(10) * VariantTrackRenderer.squishedRowHeight
        XCTAssertEqual(height, expected)
    }

    func testTotalHeightGenotypeRowsHidden() {
        let state = SampleDisplayState(showGenotypeRows: false)
        let height = VariantTrackRenderer.totalHeight(sampleCount: 10, scale: 100.0, state: state)
        XCTAssertEqual(height, VariantTrackRenderer.summaryBarHeight)
    }

    func testRowHeightAutomatic_DensityMode() {
        let state = SampleDisplayState(rowHeightMode: .automatic)
        let height = VariantTrackRenderer.rowHeight(sampleCount: 5, scale: 60_000, state: state)
        XCTAssertEqual(height, 0, "Density mode (>50k bp/px) should have 0 row height")
    }

    func testRowHeightAutomatic_SquishedMode() {
        let state = SampleDisplayState(rowHeightMode: .automatic)
        let height = VariantTrackRenderer.rowHeight(sampleCount: 5, scale: 1000, state: state)
        XCTAssertEqual(height, VariantTrackRenderer.squishedRowHeight)
    }

    func testRowHeightAutomatic_SquishedWithManySamples() {
        let state = SampleDisplayState(rowHeightMode: .automatic)
        let height = VariantTrackRenderer.rowHeight(sampleCount: 25, scale: 100, state: state)
        XCTAssertEqual(height, VariantTrackRenderer.squishedRowHeight)
    }

    func testRowHeightAutomatic_ExpandedMode() {
        let state = SampleDisplayState(rowHeightMode: .automatic)
        let height = VariantTrackRenderer.rowHeight(sampleCount: 5, scale: 100, state: state)
        XCTAssertEqual(height, VariantTrackRenderer.expandedRowHeight)
    }

    func testRowHeightForced_Squished() {
        let state = SampleDisplayState(rowHeightMode: .squished)
        let height = VariantTrackRenderer.rowHeight(sampleCount: 5, scale: 100, state: state)
        XCTAssertEqual(height, VariantTrackRenderer.squishedRowHeight)
    }

    func testRowHeightForced_Expanded() {
        let state = SampleDisplayState(rowHeightMode: .expanded)
        let height = VariantTrackRenderer.rowHeight(sampleCount: 50, scale: 10000, state: state)
        XCTAssertEqual(height, VariantTrackRenderer.expandedRowHeight)
    }

    func testMaxSampleRowsCapped() {
        let state = SampleDisplayState(showGenotypeRows: true, rowHeightMode: .squished)
        let height = VariantTrackRenderer.totalHeight(sampleCount: 200, scale: 100.0, state: state)
        let expected = VariantTrackRenderer.summaryBarHeight
            + VariantTrackRenderer.summaryToRowGap
            + CGFloat(VariantTrackRenderer.maxSampleRows) * VariantTrackRenderer.squishedRowHeight
        XCTAssertEqual(height, expected)
    }

    // MARK: - Summary Bar Rendering Tests

    func testDrawSummaryBarWithEmptyVariants() {
        let frame = makeFrame()
        let ctx = makeBitmapContext()
        VariantTrackRenderer.drawSummaryBar(variants: [], frame: frame, context: ctx, yOffset: 0)
    }

    func testDrawSummaryBarWithSingleSNP() {
        let frame = makeFrame()
        let ctx = makeBitmapContext()
        let variant = makeVariantAnnotation(start: 500, end: 501, variantType: "SNP")
        VariantTrackRenderer.drawSummaryBar(variants: [variant], frame: frame, context: ctx, yOffset: 0)
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
        let state = SampleDisplayState(showGenotypeRows: true, rowHeightMode: .expanded)
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
    }

    func testDrawGenotypeRowsDensityModeSkips() {
        let frame = makeFrame(start: 0, end: 50_000_000)
        let ctx = makeBitmapContext()
        let state = SampleDisplayState(rowHeightMode: .automatic)
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
        XCTAssertGreaterThan(VariantTrackRenderer.summaryBarHeight, 0)
        XCTAssertGreaterThan(VariantTrackRenderer.squishedRowHeight, 0)
        XCTAssertGreaterThan(VariantTrackRenderer.expandedRowHeight, 0)
        XCTAssertGreaterThanOrEqual(VariantTrackRenderer.summaryToRowGap, 0)
        XCTAssertGreaterThan(VariantTrackRenderer.maxSampleRows, 0)
    }

    func testExpandedIsLargerThanSquished() {
        XCTAssertGreaterThan(VariantTrackRenderer.expandedRowHeight, VariantTrackRenderer.squishedRowHeight)
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
        let state = SampleDisplayState(showGenotypeRows: true, rowHeightMode: .squished)
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

    // MARK: - Helper for genotype classification

    /// Reproduces the classification logic from the free function for testing.
    private func classifyGenotypeForTesting(genotype: String?, a1: Int, a2: Int) -> GenotypeDisplayCall {
        guard let gtStr = genotype else { return .noCall }
        let trimmed = gtStr.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." || trimmed == "./." || trimmed == ".|." {
            return .noCall
        }
        if a1 < 0 && a2 < 0 { return .noCall }
        if a1 == 0 && a2 == 0 { return .homRef }
        if a1 == a2 { return .homAlt }
        return .het
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
        let state = SampleDisplayState(showGenotypeRows: true, rowHeightMode: .expanded)
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

    func testTotalHeightWithZeroScale() {
        let state = SampleDisplayState(showGenotypeRows: true, rowHeightMode: .automatic)
        let height = VariantTrackRenderer.totalHeight(sampleCount: 3, scale: 0, state: state)
        let expected = VariantTrackRenderer.summaryBarHeight
            + VariantTrackRenderer.summaryToRowGap
            + 3 * VariantTrackRenderer.expandedRowHeight
        XCTAssertEqual(height, expected)
    }

    func testTotalHeightAt50KBoundary() {
        let state = SampleDisplayState(showGenotypeRows: true, rowHeightMode: .automatic)
        let height50k = VariantTrackRenderer.rowHeight(sampleCount: 5, scale: 50_000, state: state)
        XCTAssertEqual(height50k, VariantTrackRenderer.squishedRowHeight, "At 50k bp/px should be squished, not density")

        let height50k1 = VariantTrackRenderer.rowHeight(sampleCount: 5, scale: 50_001, state: state)
        XCTAssertEqual(height50k1, 0, "Above 50k bp/px should be density (0 height)")
    }

    func testTotalHeightAt500BPBoundary() {
        let state = SampleDisplayState(showGenotypeRows: true, rowHeightMode: .automatic)
        let h500 = VariantTrackRenderer.rowHeight(sampleCount: 5, scale: 500, state: state)
        XCTAssertEqual(h500, VariantTrackRenderer.expandedRowHeight, "At 500 bp/px should be expanded")

        let h501 = VariantTrackRenderer.rowHeight(sampleCount: 5, scale: 501, state: state)
        XCTAssertEqual(h501, VariantTrackRenderer.squishedRowHeight, "Above 500 bp/px should be squished")
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
        let state = SampleDisplayState(showGenotypeRows: true, rowHeightMode: .expanded)
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
