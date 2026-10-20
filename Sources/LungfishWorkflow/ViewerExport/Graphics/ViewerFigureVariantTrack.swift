// ViewerFigureVariantTrack.swift - The variant track of a viewer figure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import LungfishCore
import LungfishIO

/// The variant track as the live viewer draws it below the annotations, the summary bar of every variant in the window
/// and one genotype row for each visible sample, drawn by the moved `VariantTrackRenderer` functions through the
/// `.variantSummary` and `.genotypeRows` layers (Phase 2.13 lane 13.30, MD17 and MD23 item 1).
///
/// `load` reads one variant database over the window off the main actor, as the live variant and genotype fetches
/// read it, and the track then only adds its layers. Over 5,000 variants the live view draws no genotype rows and a
/// line that asks to zoom in, and the figure draws the same line and records an `annotationLimit` omission. Sample
/// rows past the track's height are recorded as `readRowCap` omissions (BIO 4).
public struct ViewerFigureVariantTrack: ViewerFigureTrackBuilding {
    /// The live view draws no genotype rows when the window holds more variants than this.
    public static let genotypeDisplayCap = 5_000
    /// The record limit of the live summary query, `VariantDatabase.query`'s default.
    public static let variantQueryLimit = 50_000
    /// The face of the zoom-in line. The live line uses the system font, so the figure names Helvetica Neue.
    public static let fontNames = ViewerFigureAnnotationTrack.fontNames

    /// What the track read from its database over the window.
    public struct Content: Sendable, Hashable {
        public var marks: [ViewerFigureVariantSummaryLayer.Mark] = []
        public var sites: [ViewerFigureGenotypeRowsLayer.Site] = []
        /// The visible samples in the viewer's order.
        public var sampleNames: [String] = []
        public var sampleDisplayNames: [String: String] = [:]
        /// True when the summary query stopped at `variantQueryLimit`.
        public var hitQueryLimit = false

        public init() {}
    }

    public let trackID: String
    public let content: Content
    public let state: SampleDisplayState
    public let height: Double

    public init(trackID: String, content: Content, state: SampleDisplayState = SampleDisplayState(), height: Double? = nil) {
        self.trackID = trackID
        self.content = content
        self.state = state
        self.height = height ?? Self.contentHeight(sampleCount: content.sampleNames.count, state: state)
    }

    /// The live view's height of the track, the summary bar, its gap and every sample row.
    public static func contentHeight(sampleCount: Int, state: SampleDisplayState) -> Double {
        Double(VariantTrackRenderer.totalHeight(sampleCount: sampleCount, state: state))
    }

    /// Reads the variants of `start..<end` from the database at `databaseURL`. The chromosome is the manifest's name,
    /// then each alias the manifest lists, then a name that differs only in its `chr` prefix or case, as the live
    /// lookup orders them.
    nonisolated public static func load(
        trackID: String, databaseURL: URL, chromosome: String, aliases: [String], start: Int, end: Int,
        state: SampleDisplayState = SampleDisplayState(), height: Double? = nil
    ) throws -> ViewerFigureVariantTrack {
        let database = try VariantDatabase(url: databaseURL)
        let available = Set(database.allChromosomes())
        let queryChromosome = candidates(chromosome, aliases: aliases, available: available).first ?? chromosome
        var content = Content()
        let records = database.query(chromosome: queryChromosome, start: start, end: end, limit: variantQueryLimit)
        content.hitQueryLimit = records.count >= variantQueryLimit
        content.marks = records.map { .init(start: $0.position, end: $0.end, variantType: $0.variantType) }
        let scoped = database.sampleNames(chromosome: queryChromosome)
        let samples = scoped.isEmpty ? database.sampleNames() : scoped
        let sampleSet = Set(samples)
        var metadata: [String: [String: String]] = [:]
        for entry in database.allSampleMetadata() where sampleSet.contains(entry.name) {
            metadata[entry.name, default: [:]].merge(entry.metadata) { current, _ in current }
        }
        content.sampleNames = state.visibleSamples(from: samples, metadata: metadata)
        content.sampleDisplayNames = displayNames(database: database, visible: content.sampleNames, metadata: metadata, state: state)
        if records.count <= genotypeDisplayCap, !content.sampleNames.isEmpty {
            content.sites = sites(database: database, chromosome: queryChromosome, start: start, end: end)
        }
        return ViewerFigureVariantTrack(trackID: trackID, content: content, state: state, height: height)
    }

    public func build(into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect) async throws {
        try draw(into: &canvas, area: area)
    }

    /// Adds the layers inside `area`, as the live view stacks them.
    public func draw(into canvas: inout ViewerFigureCanvas, area: ViewerFigureRect) throws(ViewerFigureFontError) {
        if content.hitQueryLimit {
            omit(.annotationLimit, "variant query limit \(Self.variantQueryLimit) records", nil, into: &canvas)
        }
        guard !content.marks.isEmpty else { return }
        let overCap = content.marks.count > Self.genotypeDisplayCap
        // The live view turns the summary bar on when the window holds too many variants for genotype rows.
        let showsBar = state.showSummaryBar || overCap
        let barHeight = showsBar ? Double(state.summaryBarHeight) : 0
        if showsBar {
            canvas.layer(.variantSummary(.init(
                yOffset: area.y, barHeight: barHeight, marks: content.marks, colorThemeName: state.colorThemeName
            )))
        }
        if overCap {
            let font = try canvas.font(Self.fontNames, size: 10)
            try canvas.text(
                "Zoom in to display genotypes (\(content.marks.count) variants visible)", fontNames: Self.fontNames,
                size: 10, at: ViewerFigurePoint(x: area.x + 4, y: area.y + barHeight + 4 + Double(CTFontGetAscent(font))),
                anchor: .baselineStart, ViewerFigurePaint(.secondaryLabel)
            )
            if !content.sampleNames.isEmpty, state.showGenotypeRows {
                omit(.annotationLimit, "genotype rows above \(Self.genotypeDisplayCap) variants", content.sampleNames.count, into: &canvas)
            }
            return
        }
        guard state.showGenotypeRows, !content.sampleNames.isEmpty, !content.sites.isEmpty, state.rowHeight > 0 else { return }
        let gap = state.showSummaryBar ? Double(VariantTrackRenderer.summaryToRowGap) : 0
        let top = area.y + barHeight + gap
        let available = max(0, area.y + area.height - top)
        canvas.layer(.genotypeRows(.init(
            yOffset: top, availableHeight: available, sampleNames: content.sampleNames, sites: content.sites,
            state: state, useHaploidAFShading: state.useHaploidAFShading, sampleDisplayNames: content.sampleDisplayNames
        )))
        let fitting = Int((available / Double(state.rowHeight)).rounded(.down))
        let hidden = content.sampleNames.count - fitting
        if hidden > 0 {
            omit(.readRowCap, "sample rows past the track height of \(ViewerFigureReadTrack.points(area.height)) points", hidden, into: &canvas)
        }
    }

    private func omit(_ kind: ViewerFigureOmissionKind, _ reason: String, _ count: Int?, into canvas: inout ViewerFigureCanvas) {
        canvas.omit(ViewerFigureOmission(trackID: trackID, kind: kind, reason: reason, count: count))
    }

    /// The live lookup order, the name, then each alias, then a name with the same canonical key, then the name.
    static func candidates(_ chromosome: String, aliases: [String], available: Set<String>) -> [String] {
        guard !available.isEmpty else { return [chromosome] }
        var ordered = ([chromosome] + aliases).filter { available.contains($0) }
        let key = canonicalVariantChromosomeLookupKey(chromosome)
        ordered += available.sorted().filter { canonicalVariantChromosomeLookupKey($0) == key }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0).inserted }
    }

    /// The sites with their calls, allele fractions and impact, as the live genotype fetch builds them.
    static func sites(database: VariantDatabase, chromosome: String, start: Int, end: Int) -> [ViewerFigureGenotypeRowsLayer.Site] {
        let rows = database.genotypesInRegion(chromosome: chromosome, start: start, end: end, limit: genotypeDisplayCap)
        let info = database.batchInfoValues(variantIds: rows.compactMap(\.variant.id))
        return rows.map { variant, genotypes in
            var calls: [String: String] = [:]
            var fractions: [String: Double] = [:]
            for genotype in genotypes {
                calls[genotype.sampleName] = GenotypeDisplayCall.classify(
                    genotype: genotype.genotype, allele1: genotype.allele1, allele2: genotype.allele2
                ).rawValue
                if let fraction = alleleFraction(genotype.alleleDepths) {
                    fractions[genotype.sampleName] = fraction
                }
            }
            return .init(
                position: variant.position, ref: variant.ref, alt: variant.alt, variantType: variant.variantType,
                calls: calls, alleleFractions: fractions, impact: variant.id.flatMap { info[$0] }.flatMap(Self.impact)?.rawValue
            )
        }
    }

    /// The impact the live view reads from CSQ, ANN or plain INFO keys, or nil when none is present.
    static func impact(_ info: [String: String]) -> VariantImpact? {
        let consequence = info["CSQ_Consequence"] ?? info["ANN_Consequence"] ?? info["Consequence"]
        let impact = info["CSQ_IMPACT"] ?? info["ANN_IMPACT"] ?? info["IMPACT"] ?? info["impact"]
        guard consequence != nil || impact != nil else { return nil }
        return VariantImpact.fromCSQ(impact: impact, consequence: consequence)
    }

    /// The alternate allele fraction of a VCF `AD` value, as the live view reads it.
    static func alleleFraction(_ alleleDepths: String?) -> Double? {
        guard let alleleDepths else { return nil }
        let depths = alleleDepths.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard depths.count >= 2 else { return nil }
        let total = depths.reduce(0, +)
        guard total > 0 else { return nil }
        return min(1.0, max(0.0, Double(depths.dropFirst().reduce(0, +)) / Double(total)))
    }

    /// The live view's three layers of sample names, the database's, then a metadata field, then the overrides.
    static func displayNames(
        database: VariantDatabase, visible: [String], metadata: [String: [String: String]], state: SampleDisplayState
    ) -> [String: String] {
        var names = database.allDisplayNames()
        if let field = state.displayNameField?.trimmingCharacters(in: .whitespacesAndNewlines), !field.isEmpty {
            for sample in visible {
                if let label = metadata[sample]?[field]?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                    names[sample] = label
                }
            }
        }
        names.merge(state.sampleDisplayNameOverrides) { _, override in override }
        return names
    }
}
