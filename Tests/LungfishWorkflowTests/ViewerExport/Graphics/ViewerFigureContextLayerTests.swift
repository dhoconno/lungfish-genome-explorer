// ViewerFigureContextLayerTests.swift - A layer draws what the moved renderer draws
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.30 (GFX-2, MD17). Each layer of `ViewerFigureContextLayers.swift`, drawn by the
// rasterizer, must give the pixels of the moved function called directly into a context in the
// rasterizer's state.

import CoreGraphics
import Foundation
import ImageIO
import LungfishCore
import XCTest
@testable import LungfishWorkflow

final class ViewerFigureContextLayerTests: XCTestCase {
    private let frame = ViewerFigureFrame(chromosome: "chr1", start: 0, end: 200, pixelWidth: 260, sequenceLength: 1_000, leadingInset: 60)
    private let theme = ViewerFigureTheme(appearance: .light)

    private var coverage: ViewerFigureCoverageLayer {
        ViewerFigureCoverageLayer(
            rect: ViewerFigureRect(x: 60, y: 4, width: 200, height: 40), regionStart: 0, regionEnd: 200,
            depths: (0..<200).map { ViewerFigureCoverageLayer.Depth(position: $0, depth: ($0 * 7) % 31) }
        )
    }

    private var summary: ViewerFigureVariantSummaryLayer {
        ViewerFigureVariantSummaryLayer(yOffset: 4, barHeight: 20, marks: [
            .init(start: 10, end: 11, variantType: "SNP"), .init(start: 10, end: 11, variantType: "SNP"),
            .init(start: 50, end: 53, variantType: "DEL"), .init(start: 120, end: 121, variantType: "INS"),
            .init(start: 180, end: 182, variantType: "MNP"),
        ])
    }

    private var genotypes: ViewerFigureGenotypeRowsLayer {
        ViewerFigureGenotypeRowsLayer(
            yOffset: 4, availableHeight: 60, sampleNames: ["sampleA", "sampleB", "sampleC"],
            sites: [
                .init(position: 10, ref: "A", alt: "G", variantType: "SNP", calls: ["sampleA": "HET", "sampleB": "HOM_ALT"]),
                .init(position: 50, ref: "ACT", alt: "A", variantType: "DEL", calls: ["sampleA": "HOM_REF", "sampleC": "NO_CALL"]),
                .init(position: 120, ref: "C", alt: "CT", variantType: "INS", calls: ["sampleB": "HET", "sampleC": "HOM_ALT"]),
            ],
            state: SampleDisplayState()
        )
    }

    func testACoverageLayerDrawsWhatTheMovedFunctionDraws() throws {
        let layer = coverage
        try assertLayer(.coverage(layer)) { context in
            ReadTrackRenderer.drawCoverage(
                depthPoints: layer.depths.map { ReadTrackRenderer.CoveragePoint(position: $0.position, depth: $0.depth) },
                regionStart: 0, regionEnd: 200, frame: self.frame, context: context, figureTheme: self.theme,
                rect: CGRect(x: 60, y: 4, width: 200, height: 40)
            )
        }
    }

    func testASummaryBarLayerDrawsWhatTheMovedFunctionDraws() throws {
        let layer = summary
        try assertLayer(.variantSummary(layer)) { context in
            VariantTrackRenderer.drawSummaryBar(
                variants: layer.annotations, frame: self.frame, context: context, figureTheme: self.theme, yOffset: 4, barHeight: 20
            )
        }
    }

    func testAGenotypeRowsLayerDrawsWhatTheMovedFunctionDraws() throws {
        let layer = genotypes
        try assertLayer(.genotypeRows(layer)) { context in
            let data = GenotypeDisplayData(
                sampleNames: layer.sampleNames, sites: layer.sites.map(\.site),
                region: GenomicRegion(chromosome: "chr1", start: 0, end: 200)
            )
            VariantTrackRenderer.drawGenotypeRows(
                genotypeData: data, frame: self.frame, context: context, figureTheme: self.theme, yOffset: 4,
                state: SampleDisplayState(), availableHeight: 60
            )
        }
    }

    func testASceneGoldenShowsALayersInputsAndTheOtherItemsKeepTheirForm() throws {
        let scene = scene(with: .variantSummary(summary))
        let json = try XCTUnwrap(String(data: try scene.goldenJSON(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"variantSummary\""))
        XCTAssertTrue(json.contains("\"variantType\" : \"DEL\""))
        XCTAssertTrue(json.contains("\"fill\""))
        let decoded = try JSONDecoder().decode(ViewerFigureScene.self, from: try scene.goldenJSON())
        XCTAssertEqual(decoded, scene)
    }

    func testALayerInASceneWithNoFrameIsRefused() {
        let scene = ViewerFigureScene(
            width: 260, height: 70, appearance: .light, background: ViewerFigurePaint(.textBackground), frame: nil,
            fonts: [], items: [.layer(.coverage(coverage))]
        )
        XCTAssertThrowsError(try ViewerFigureRasterizer.render(scene, format: .png)) {
            XCTAssertEqual($0 as? ViewerFigureRasterizerError, .layerWithoutFrame)
        }
    }

    // MARK: - Support

    private func scene(with layer: ViewerFigureContextLayer) -> ViewerFigureScene {
        ViewerFigureScene(
            width: 260, height: 70, appearance: .light, background: ViewerFigurePaint(.textBackground), frame: frame,
            fonts: [], items: [.fill(rect: ViewerFigureRect(x: 0, y: 0, width: 260, height: 2), paint: ViewerFigurePaint(.separator)), .layer(layer)]
        )
    }

    /// Renders the layer through the rasterizer and draws `direct` into a context in the rasterizer's
    /// state, then compares every pixel.
    private func assertLayer(
        _ layer: ViewerFigureContextLayer, file: StaticString = #filePath, line: UInt = #line,
        direct: (CGContext) -> Void
    ) throws {
        let scene = scene(with: layer)
        let scale = 2.0
        let rendered = try image(ViewerFigureRasterizer.render(scene, format: .png, pixelScale: scale))
        let width = Int(scene.width * scale)
        let height = Int(scene.height * scale)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ViewerFigureRasterizer.configure(context)
        context.setFillColor(scene.background.color(in: theme).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
        context.setFillColor(ViewerFigurePaint(.separator).color(in: theme).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 260, height: 2))
        context.saveGState()
        direct(context)
        context.restoreGState()
        let expected = try XCTUnwrap(context.makeImage())
        let renderedPixels = rgba(rendered)
        let expectedPixels = rgba(expected)
        XCTAssertEqual(renderedPixels.count, expectedPixels.count, file: file, line: line)
        let differing = zip(renderedPixels, expectedPixels).filter { $0 != $1 }.count
        XCTAssertEqual(differing, 0, "channel values that differ", file: file, line: line)
        let background = Array(rgba(try image(ViewerFigureRasterizer.render(
            ViewerFigureScene(width: 260, height: 70, appearance: .light, background: scene.background, frame: frame, fonts: [], items: []),
            format: .png, pixelScale: scale
        ))))
        XCTAssertNotEqual(renderedPixels, background, "the layer drew nothing", file: file, line: line)
    }

    private func image(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
