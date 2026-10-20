// ViewerFigureContextLayers.swift - The hook between the figure rasterizer and the moved CGContext renderers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import LungfishCore

/// One drawing step that a moved CGContext renderer draws (Phase 2.13 lane 13.30, MD17).
///
/// The four item kinds of a scene cannot call `ReadTrackRenderer` or `VariantTrackRenderer`, which
/// draw straight into a `CGContext`. A layer holds the `Sendable` inputs of one such call. The
/// rasterizer draws it over its own context, in draw order with the items, with the scene's theme
/// and frame, so the renderer stays a synchronous function of `Sendable` values with no global
/// state. A layer encodes its inputs, so a scene golden shows what it draws without any rendered
/// byte. Each case draws exactly what the moved function draws when it is called directly, which
/// `ViewerFigureContextLayerTests` holds pixel for pixel.
public enum ViewerFigureContextLayer: Sendable, Hashable, Codable {
    /// Coverage drawn by `ReadTrackRenderer.drawCoverage(depthPoints:...)`.
    case coverage(ViewerFigureCoverageLayer)
    /// The variant summary bar drawn by `VariantTrackRenderer.drawSummaryBar`.
    case variantSummary(ViewerFigureVariantSummaryLayer)
    /// The genotype rows drawn by `VariantTrackRenderer.drawGenotypeRows`.
    case genotypeRows(ViewerFigureGenotypeRowsLayer)

    /// Draws the layer into `context`, whose origin is the figure's top left in points with y growing
    /// down. The context's state is restored afterwards.
    public func draw(in context: CGContext, frame: ViewerFigureFrame, theme: ViewerFigureTheme) {
        context.saveGState()
        defer { context.restoreGState() }
        switch self {
        case .coverage(let layer):
            layer.draw(in: context, frame: frame, theme: theme)
        case .variantSummary(let layer):
            layer.draw(in: context, frame: frame, theme: theme)
        case .genotypeRows(let layer):
            layer.draw(in: context, frame: frame, theme: theme)
        }
    }
}

/// The inputs of one `ReadTrackRenderer.drawCoverage(depthPoints:...)` call.
public struct ViewerFigureCoverageLayer: Sendable, Hashable, Codable {
    /// One depth at one 0-based position.
    public struct Depth: Sendable, Hashable, Codable {
        public let position: Int
        public let depth: Int

        public init(position: Int, depth: Int) {
            self.position = position
            self.depth = depth
        }
    }

    public let rect: ViewerFigureRect
    public let regionStart: Int
    public let regionEnd: Int
    public let depths: [Depth]
    public let scaleMode: CoverageScaleMode

    public init(rect: ViewerFigureRect, regionStart: Int, regionEnd: Int, depths: [Depth], scaleMode: CoverageScaleMode = .default) {
        self.rect = rect
        self.regionStart = regionStart
        self.regionEnd = regionEnd
        self.depths = depths
        self.scaleMode = scaleMode
    }

    func draw(in context: CGContext, frame: ViewerFigureFrame, theme: ViewerFigureTheme) {
        ReadTrackRenderer.drawCoverage(
            depthPoints: depths.map { ReadTrackRenderer.CoveragePoint(position: $0.position, depth: $0.depth) },
            regionStart: regionStart, regionEnd: regionEnd, frame: frame, context: context,
            figureTheme: theme, rect: rect.cgRect, scaleMode: scaleMode
        )
    }
}

/// The inputs of one `VariantTrackRenderer.drawSummaryBar` call. The bar reads only each variant's
/// bounds and its `variant_type` qualifier, so a layer keeps those and no annotation id.
public struct ViewerFigureVariantSummaryLayer: Sendable, Hashable, Codable {
    /// One variant, 0-based and half-open.
    public struct Mark: Sendable, Hashable, Codable {
        public let start: Int
        public let end: Int
        /// `SNP`, `INS`, `DEL` or another type, as the variant database stores it.
        public let variantType: String

        public init(start: Int, end: Int, variantType: String) {
            self.start = start
            self.end = end
            self.variantType = variantType
        }
    }

    public let yOffset: Double
    public let barHeight: Double
    public let marks: [Mark]
    /// The `VariantColorTheme` name the viewer draws variants with.
    public let colorThemeName: String

    public init(yOffset: Double, barHeight: Double, marks: [Mark], colorThemeName: String = VariantColorTheme.modern.name) {
        self.yOffset = yOffset
        self.barHeight = barHeight
        self.marks = marks
        self.colorThemeName = colorThemeName
    }

    /// The annotations the moved function takes. The id is fixed, since the bar never reads it.
    var annotations: [SequenceAnnotation] {
        marks.map {
            SequenceAnnotation(
                id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), type: .snp, name: $0.variantType,
                start: $0.start, end: $0.end, qualifiers: ["variant_type": AnnotationQualifier($0.variantType)]
            )
        }
    }

    func draw(in context: CGContext, frame: ViewerFigureFrame, theme: ViewerFigureTheme) {
        VariantTrackRenderer.drawSummaryBar(
            variants: annotations, frame: frame, context: context, figureTheme: theme,
            yOffset: CGFloat(yOffset), barHeight: CGFloat(barHeight), theme: VariantColorTheme.named(colorThemeName)
        )
    }
}

/// The inputs of one `VariantTrackRenderer.drawGenotypeRows` call.
public struct ViewerFigureGenotypeRowsLayer: Sendable, Hashable, Codable {
    /// One variant site with its calls, as `VariantSite` holds what the rows draw.
    public struct Site: Sendable, Hashable, Codable {
        public let position: Int
        public let ref: String
        public let alt: String
        public let variantType: String
        /// The `GenotypeDisplayCall` raw value per sample name.
        public let calls: [String: String]
        public let alleleFractions: [String: Double]
        /// The `VariantImpact` raw value, when known.
        public let impact: String?

        public init(
            position: Int, ref: String, alt: String, variantType: String, calls: [String: String],
            alleleFractions: [String: Double] = [:], impact: String? = nil
        ) {
            self.position = position
            self.ref = ref
            self.alt = alt
            self.variantType = variantType
            self.calls = calls
            self.alleleFractions = alleleFractions
            self.impact = impact
        }

        var site: VariantSite {
            VariantSite(
                position: position, ref: ref, alt: alt, variantType: variantType,
                genotypes: calls.compactMapValues { GenotypeDisplayCall(rawValue: $0) },
                sampleAlleleFractions: alleleFractions, impact: impact.flatMap { VariantImpact(rawValue: $0) }
            )
        }
    }

    public let yOffset: Double
    public let availableHeight: Double
    public let sampleNames: [String]
    public let sites: [Site]
    public let state: SampleDisplayState
    public let useHaploidAFShading: Bool
    public let sampleDisplayNames: [String: String]

    public init(
        yOffset: Double, availableHeight: Double, sampleNames: [String], sites: [Site], state: SampleDisplayState,
        useHaploidAFShading: Bool = false, sampleDisplayNames: [String: String] = [:]
    ) {
        self.yOffset = yOffset
        self.availableHeight = availableHeight
        self.sampleNames = sampleNames
        self.sites = sites
        self.state = state
        self.useHaploidAFShading = useHaploidAFShading
        self.sampleDisplayNames = sampleDisplayNames
    }

    /// `SampleDisplayState` is not `Hashable`, so the hash leaves it out and equality keeps it.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(yOffset)
        hasher.combine(availableHeight)
        hasher.combine(sampleNames)
        hasher.combine(sites)
        hasher.combine(useHaploidAFShading)
        hasher.combine(sampleDisplayNames)
    }

    func draw(in context: CGContext, frame: ViewerFigureFrame, theme: ViewerFigureTheme) {
        let data = GenotypeDisplayData(
            sampleNames: sampleNames, sites: sites.map(\.site),
            region: GenomicRegion(chromosome: frame.chromosome, start: Int(frame.start), end: Int(frame.end.rounded(.up)))
        )
        VariantTrackRenderer.drawGenotypeRows(
            genotypeData: data, frame: frame, context: context, figureTheme: theme, yOffset: CGFloat(yOffset),
            state: state, useHaploidAFShading: useHaploidAFShading, sampleDisplayNames: sampleDisplayNames,
            availableHeight: CGFloat(availableHeight), theme: VariantColorTheme.named(state.colorThemeName)
        )
    }
}
