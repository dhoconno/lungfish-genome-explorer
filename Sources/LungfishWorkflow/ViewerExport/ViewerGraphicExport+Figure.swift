// ViewerGraphicExport+Figure.swift - A viewer figure built from a bundle's files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// A figure the export refuses to draw, before it writes anything. Its message names the fix.
public struct ViewerGraphicRefusal: Error, LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// A region of one contig as the manifest names it, 0-based and half-open, checked against the contig's length.
public struct ViewerGraphicRegion: Sendable, Equatable {
    public let contig: String
    public let start: Int
    public let end: Int
    public let contigLength: Int

    /// `<contig>:<start>-<end>` in the record's convention, 1-based and closed, with no commas.
    public var display: String { "\(contig):\(start + 1)-\(end)" }
    /// The bases drawn, `end - start + 1` in the 1-based closed convention.
    public var length: Int { end - start }
}

/// One drawn track as the record states it.
public struct ViewerGraphicTrackFact: Sendable, Equatable {
    public let id: String
    public let kind: String
    public let displayMode: String
    public let height: Double
}

/// A figure built from a bundle, with the files it read and what it left out.
public struct ViewerGraphicFigure: Sendable {
    public let scene: ViewerFigureScene
    /// The manifest first, then each file a drawn track opened in drawn order, then the view-state file, no repeats.
    public let inputURLs: [URL]
    public let tracks: [ViewerGraphicTrackFact]
    /// The read row cap when an alignment track was drawn.
    public let readRowCap: Int?
    public var drawsAlignment: Bool { readRowCap != nil }
}

/// An opened bundle, its manifest read once for every figure the command draws.
public struct ViewerGraphicBundle: Sendable {
    public let url: URL
    public let manifestURL: URL
    public let manifest: BundleManifest

    /// Reads the manifest, or refuses a folder that holds none.
    public init(url: URL) throws {
        self.url = url.standardizedFileURL
        self.manifestURL = self.url.appendingPathComponent(BundleManifest.filename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ViewerGraphicRefusal("No bundle manifest at \(manifestURL.path). Pass a reference bundle folder.")
        }
        do {
            manifest = try BundleManifest.load(from: self.url)
        } catch {
            throw ViewerGraphicRefusal("The bundle manifest at \(manifestURL.path) cannot be read. \(error.localizedDescription)")
        }
    }

    /// The track ids a figure draws when the command names none, in the viewer's stack order.
    public var defaultTrackIDs: [String] {
        (manifest.genome == nil ? [] : [ViewerFigureSequenceTrack.trackID])
            + manifest.annotations.map(\.id) + manifest.variants.map(\.id)
            + manifest.alignments.map(\.id) + manifest.tracks.map(\.id)
    }

    /// The region `start..<end` of `contig`, the manifest's name or an alias it lists for exactly one contig.
    /// Refuses an unknown contig and an end past the contig's length, and never clamps.
    public func region(contig: String, start: Int, end: Int) throws -> ViewerGraphicRegion {
        let chromosomes = manifest.genome?.chromosomes ?? []
        let named = chromosomes.first { $0.name == contig }
        let aliased = chromosomes.filter { $0.aliases.contains(contig) }
        guard let chromosome = named ?? (aliased.count == 1 ? aliased[0] : nil) else {
            throw ViewerGraphicRefusal("The bundle has no contig named \(contig). Name a contig its manifest lists.")
        }
        let length = Int(chromosome.length)
        guard end <= length else {
            throw ViewerGraphicRefusal(
                "The region ends at \(end), past the end of \(chromosome.name) at \(length). Choose a region inside the contig."
            )
        }
        return ViewerGraphicRegion(contig: chromosome.name, start: start, end: end, contigLength: length)
    }

    func resolved(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.appendingPathComponent(path)
    }

    /// The other names an annotation database may hold `contig` under, as `ReferenceBundle.annotationQueryChromosomes`
    /// collects them. They are the contig's manifest name, its aliases, then the database's names that
    /// `mapVCFChromosomes` maps to it, sorted, since the live query takes them in dictionary order.
    public func annotationChromosomeNames(contig: String, databaseURL: URL) throws -> [String] {
        let chromosomes = manifest.genome?.chromosomes ?? []
        guard let chromosome = chromosomes.first(where: { $0.name == contig }) else { return [] }
        let held = try AnnotationDatabase(url: databaseURL).allChromosomes()
        let mapped = mapVCFChromosomes(held, toBundleChromosomes: chromosomes)
            .filter { $0.value == chromosome.name }.map(\.key).sorted()
        return [chromosome.name] + chromosome.aliases + mapped
    }

    /// The live view's map from a manifest contig name to the name the alignments hold it under, built as
    /// `SequenceViewerView.buildAlignmentChromosomeAliasMap` builds it. Every alignment track's metadata database
    /// gives its contig lengths, and a manifest contig no alignment names takes the first unused alignment name of
    /// the same length, in sorted order where the live view takes set order. `opened` lists each database read,
    /// for the record.
    public func alignmentChromosomeAliases() -> (map: [String: String], opened: [URL]) {
        let chromosomes = manifest.genome?.chromosomes ?? []
        var lengths: [String: Int64] = [:]
        var opened: [URL] = []
        for track in manifest.alignments {
            guard let path = track.metadataDBPath else { continue }
            let databaseURL = resolved(path)
            guard let database = try? AlignmentMetadataDatabase(url: databaseURL) else { continue }
            opened.append(databaseURL)
            for stat in database.chromosomeStats() {
                lengths[stat.chromosome] = stat.length
            }
        }
        let unmatched = Set(lengths.keys).subtracting(chromosomes.map(\.name)).sorted()
        guard !unmatched.isEmpty else { return ([:], opened) }
        var map: [String: String] = [:]
        var used = Set<String>()
        for chromosome in chromosomes where lengths[chromosome.name] == nil {
            if let match = unmatched.first(where: { !used.contains($0) && lengths[$0] == chromosome.length }) {
                map[chromosome.name] = match
                used.insert(match)
            }
        }
        return (map, opened)
    }
}

extension ViewerGraphicExport {
    /// The heights a command line draws a track at when no view-state names one.
    public static let defaultAnnotationHeight = 60.0
    public static let defaultReadHeight = 200.0
    /// The reads a command line leaves out by default, unmapped (0x4), secondary (0x100) and supplementary (0x800). The live
    /// view's own default is 0xD04, which also leaves out duplicates (0x400), and the app passes the view's value.
    public static let defaultExcludeFlags: UInt16 = 0x904
    /// The live view's default read row cap.
    public static let defaultReadRowCap = 75
    /// The reason of a `trackNotDrawn` entry for a kind the renderer cannot draw yet (BIO ruling Q-G3, item 7).
    public static let noBuilderReason = "no figure builder"

    /// Refuses a `--track` id the bundle does not hold.
    public static func trackIDs(_ requested: [String], in bundle: ViewerGraphicBundle) throws -> [String] {
        guard !requested.isEmpty else { return bundle.defaultTrackIDs }
        let known = Set(bundle.defaultTrackIDs)
        if let unknown = requested.first(where: { !known.contains($0) }) {
            throw ViewerGraphicRefusal(
                "The bundle has no track \(unknown). Name one of \(bundle.defaultTrackIDs.joined(separator: ", "))."
            )
        }
        return requested
    }

    /// Builds the figure of `region` off the main actor. A track kind with no builder is left out and recorded as
    /// `trackNotDrawn`, and the rest is drawn.
    nonisolated public static func figure(
        bundle: ViewerGraphicBundle, region: ViewerGraphicRegion, trackIDs: [String], settings: Settings,
        viewState: ViewerGraphicViewState?, viewStateURL: URL?
    ) async throws -> ViewerGraphicFigure {
        let manifest = bundle.manifest
        var builders: [any ViewerFigureTrackBuilding] = []
        var facts: [ViewerGraphicTrackFact] = []
        var inputs = [bundle.manifestURL]
        var notDrawn: [ViewerFigureOmission] = []
        var readRowCap: Int?
        var alignmentAliases: (map: [String: String], opened: [URL])?
        let frame = ViewerFigureFrame(
            chromosome: region.contig, start: Double(region.start), end: Double(region.end),
            pixelWidth: Int((settings.width ?? defaultWidth).rounded()), sequenceLength: region.contigLength,
            trailingInset: ViewerFigureFrame.defaultTrailingInset
        )
        if settings.includeRuler {
            builders.append(ViewerFigureRulerTrack())
        }
        for id in trackIDs {
            let height = viewState?.height(for: id)
            if id == ViewerFigureSequenceTrack.trackID, let genome = manifest.genome {
                let track = ViewerFigureSequenceTrack(
                    fastaURL: bundle.resolved(genome.path), indexURL: bundle.resolved(genome.indexPath),
                    gzipIndexURL: genome.gzipIndexPath.map { bundle.resolved($0) },
                    height: height ?? ViewerFigureSequenceTrack.defaultHeight
                )
                builders.append(track)
                inputs += track.inputFiles
                facts.append(ViewerGraphicTrackFact(id: id, kind: "sequence", displayMode: "automatic", height: track.height))
            } else if let info = manifest.annotations.first(where: { $0.id == id }) {
                guard let databasePath = info.databasePath else {
                    notDrawn.append(ViewerFigureOmission(trackID: id, kind: .trackNotDrawn, reason: "no annotation database", count: nil))
                    continue
                }
                let databaseURL = bundle.resolved(databasePath)
                let names = try bundle.annotationChromosomeNames(contig: region.contig, databaseURL: databaseURL)
                let track = ViewerFigureAnnotationTrack(
                    trackID: id,
                    sources: [.init(id: id, name: info.name, databaseURL: databaseURL, chromosomeNames: names)],
                    height: height ?? defaultAnnotationHeight
                )
                builders.append(track)
                inputs.append(databaseURL)
                facts.append(ViewerGraphicTrackFact(id: id, kind: "annotation", displayMode: "automatic", height: track.height))
            } else if let info = manifest.alignments.first(where: { $0.id == id }) {
                var options = ViewerFigureReadTrack.Options()
                options.excludeFlags = settings.excludeFlags ?? defaultExcludeFlags
                options.maxRows = viewState?.readRowCap ?? defaultReadRowCap
                readRowCap = options.maxRows
                let alignmentURL = bundle.resolved(info.sourcePath)
                let indexURL = bundle.resolved(info.indexPath)
                let referenceURL = info.format == .cram ? manifest.genome.map { bundle.resolved($0.path) } : nil
                let aliases = alignmentAliases ?? bundle.alignmentChromosomeAliases()
                alignmentAliases = aliases
                let track = ViewerFigureReadTrack(
                    trackID: id,
                    source: .init(
                        alignmentPath: alignmentURL.path, indexPath: indexURL.path, format: info.format,
                        referenceFastaPath: referenceURL?.path, chromosomeAliases: aliases.map
                    ),
                    height: height ?? defaultReadHeight, options: options
                )
                builders.append(track)
                inputs += [alignmentURL, indexURL] + (referenceURL.map { [$0] } ?? []) + aliases.opened
                facts.append(ViewerGraphicTrackFact(id: id, kind: "alignment", displayMode: "packed", height: track.height))
            } else if let info = manifest.variants.first(where: { $0.id == id }) {
                guard let databasePath = info.databasePath else {
                    notDrawn.append(ViewerFigureOmission(trackID: id, kind: .trackNotDrawn, reason: "no variant database", count: nil))
                    continue
                }
                let databaseURL = bundle.resolved(databasePath)
                let state = viewState?.sampleDisplay ?? SampleDisplayState()
                let aliases = manifest.genome?.chromosomes.first { $0.name == region.contig }?.aliases ?? []
                let track = try ViewerFigureVariantTrack.load(
                    trackID: id, databaseURL: databaseURL, chromosome: region.contig, aliases: aliases,
                    start: region.start, end: region.end, state: state, height: height
                )
                builders.append(track)
                inputs.append(databaseURL)
                facts.append(ViewerGraphicTrackFact(id: id, kind: "variant", displayMode: variantDisplayMode(state), height: track.height))
            } else {
                notDrawn.append(ViewerFigureOmission(trackID: id, kind: .trackNotDrawn, reason: noBuilderReason, count: nil))
            }
        }
        if let viewStateURL {
            inputs.append(viewStateURL)
        }
        let built = try await ViewerFigureSceneBuilder.build(
            frame: frame, appearance: (settings.theme ?? .light).appearance, tracks: builders
        )
        let scene = ViewerFigureScene(
            width: built.width, height: built.height, appearance: built.appearance, background: built.background,
            frame: built.frame, fonts: built.fonts, items: built.items, omissions: built.omissions + notDrawn
        )
        var seen = Set<String>()
        let unique = inputs.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        return ViewerGraphicFigure(scene: scene, inputURLs: unique, tracks: facts, readRowCap: readRowCap)
    }

    /// The variant track's display mode as the record states it, from what its sample display state shows.
    static func variantDisplayMode(_ state: SampleDisplayState) -> String {
        switch (state.showSummaryBar, state.showGenotypeRows) {
        case (true, true): return "summaryAndGenotypes"
        case (true, false): return "summary"
        case (false, true): return "genotypes"
        case (false, false): return "hidden"
        }
    }

    /// Every fact the record's `resolved.degraded` lists, the scene's omissions and one `fontFallback` entry for
    /// each font that fell back, once each (BIO ruling Q-G3, item 7).
    public static func degradedFacts(of scene: ViewerFigureScene) -> [ViewerFigureOmission] {
        var facts = scene.omissions
        for font in scene.fonts where font.fallback {
            let reason = "\(font.requested) fell back to \(font.resolved) at \(number(font.size)) points"
            if !facts.contains(where: { $0.kind == .fontFallback && $0.reason == reason }) {
                facts.append(ViewerFigureOmission(trackID: "figure", kind: .fontFallback, reason: reason, count: nil))
            }
        }
        return facts.sorted()
    }
}
