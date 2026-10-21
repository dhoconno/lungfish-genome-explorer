// AnnotationTableExportRowReader.swift - Rebuilds an annotation table export's rows from a bundle and a selection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Rebuilds the rows of an annotation table export from a reference bundle and the selection file the drawer wrote
/// (Phase 2.12 lane 12.39, ARCH ruling on 12.39 R1 items 2 to 7).
///
/// The rows are read by identity, in the selection's order, from the databases of the tracks the identities name,
/// and go through the drawer's builder (``AnnotationTableExportSnapshot``), so the leaf writes the drawer's bytes. The
/// variant and genotype tabs project iVar FORMAT values as the drawer does, and the derived variant columns read the
/// coding features of the selection's region from the bundle, the call the viewer makes. Both scopes take this one
/// path. The reader names every file it reads, as the drawer names them.
package enum AnnotationTableExportRowReader {
    /// The rebuilt table, with `manifest.json` and then the files of the tab the rows came from. The selection file is
    /// the caller's to name.
    package struct Rows: Sendable {
        package let snapshot: AnnotationTableExportSnapshot
        package let inputURLs: [URL]
    }

    /// A selection the bundle cannot answer, which the leaf refuses before it writes anything. The message names
    /// the fix.
    package struct Refusal: Error, LocalizedError, Equatable {
        package let message: String
        package var errorDescription: String? { message }
    }

    /// The coding features read from the bundle are not the ones the table showed (R1 item 6), a failure.
    package struct FeatureMismatch: Error, LocalizedError, Equatable {
        package var errorDescription: String? {
            "The coding features read from the bundle do not match the ones the table showed."
        }
    }

    private struct Track {
        let id: String
        let name: String
        let url: URL
    }

    private struct RowKey {
        let track: Track
        let rowID: Int64
        var sample = ""
    }

    /// Reads the rows of `tab` that `selection` names from the bundle at `bundleURL`.
    package static func read(
        bundleURL: URL,
        tab: AnnotationTableExport.Tab,
        selection: ViewerExportSelection
    ) async throws -> Rows {
        guard let table = selection.annotationTable else {
            throw Refusal(message: "The selection file holds no annotation table. Export the table again from the app.")
        }
        guard let scope = AnnotationTableExportScope(rawValue: table.scope) else {
            throw Refusal(message: "The selection file names the scope \(table.scope), which this build does not read.")
        }
        // V1-1 item 2. A derived column reads one source, so a file naming both is not one the app wrote.
        if table.codingFeatureRegion != nil, table.bundleCodingFeatureTrackIDs != nil {
            throw Refusal(message: "The selection file names both a coding feature region and the bundle's coding "
                + "feature tracks, which no export of the app writes. Export the table again from the app.")
        }
        var seen = Set<String>()
        if let repeated = selection.identities.first(where: { !seen.insert($0).inserted }) {
            throw Refusal(message: "The selection file names the row \(repeated) twice. Export the table again from the app.")
        }
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let manifest: BundleManifest
        do {
            manifest = try BundleManifest.load(from: bundleURL)
        } catch {
            throw Refusal(message: "No bundle manifest can be read at \(manifestURL.path). Pass a reference bundle (.lungfishref).")
        }
        let bundle = ReferenceBundle(url: bundleURL, manifest: manifest)
        let read: (snapshot: AnnotationTableExportSnapshot, urls: [URL])
        switch tab {
        case .annotations:
            read = try annotations(bundle: bundle, table: table, scope: scope, identities: selection.identities)
        case .variants:
            read = try await variants(bundle: bundle, table: table, scope: scope, identities: selection.identities)
        case .genotypes:
            read = try await genotypes(bundle: bundle, table: table, scope: scope, identities: selection.identities)
        case .samples:
            read = try samples(bundle: bundle, table: table, scope: scope, selection: selection)
        }
        var names = Set<String>()
        let inputs = ([manifestURL] + read.urls).map(\.standardizedFileURL).filter { names.insert($0.path).inserted }
        return Rows(snapshot: read.snapshot, inputURLs: inputs)
    }

    // MARK: - Tabs

    private static func annotations(
        bundle: ReferenceBundle, table: AnnotationTableExportSelection, scope: AnnotationTableExportScope,
        identities: [String]
    ) throws -> (AnnotationTableExportSnapshot, [URL]) {
        let tracks = annotationTracks(bundle)
        let keys = try identities.map { try rowKey($0, tracks: tracks, kind: "annotation") }
        let named = tracks.filter { track in keys.contains { $0.track.id == track.id } }
        var records: [String: [Int64: AnnotationDatabaseRecord]] = [:]
        for track in named {
            try Task.checkCancellation()
            for record in try AnnotationDatabase(url: track.url).annotationsForExport(rowIDs: rowIDs(keys, in: track)) {
                if let rowID = record.rowID { records[track.id, default: [:]][rowID] = record }
            }
        }
        let rows = try zip(identities, keys).map { identity, key -> AnnotationSearchResult in
            guard let record = records[key.track.id]?[key.rowID] else { throw missingRow(identity) }
            return AnnotationSearchResult(
                name: record.name, chromosome: record.chromosome,
                start: record.start, end: record.end, trackId: key.track.id,
                trackName: key.track.name, type: record.type, strand: record.strand,
                attributes: record.attributes.map(AnnotationDatabase.parseAttributes),
                annotationRowId: record.rowID
            )
        }
        let urls = named.map(\.url)
        return (AnnotationTableExportSnapshot.captureAnnotations(
            rows, columns: table.columns, scope: scope, sourceURLs: urls, queryDescription: table.query
        ), urls)
    }

    private static func variants(
        bundle: ReferenceBundle, table: AnnotationTableExportSelection, scope: AnnotationTableExportScope,
        identities: [String]
    ) async throws -> (AnnotationTableExportSnapshot, [URL]) {
        let tracks = variantTracks(bundle)
        let keys = try identities.map { try rowKey($0, tracks: tracks, kind: "variant") }
        let loaded = try await variantResults(bundle: bundle, tracks: tracks, keys: keys)
        let rows = try zip(identities, keys).map { identity, key -> AnnotationSearchResult in
            guard let row = loaded.results[key.track.id]?[key.rowID] else { throw missingRow(identity) }
            return row
        }
        let callerSettings = Dictionary(uniqueKeysWithValues: loaded.named.map {
            ($0.id, VariantCallerSettingsSummary.text(databaseURL: $0.url))
        })
        var resolver = VariantTableExportResolverSnapshot.empty
        var urls = loaded.named.map(\.url) + loaded.overlayURLs
        if let region = table.codingFeatureRegion {
            let features = try codingFeatures(bundle: bundle, region: region)
            if let shown = table.query["derivedVariantFeatureCount"], shown != String(features.count) {
                throw FeatureMismatch()
            }
            resolver = try VariantTableExportResolverSnapshot(
                features: features,
                variantChromosomeAliasMap: table.variantChromosomeAliases,
                referenceChromosomeAliases: VariantTableCodingFeatures.referenceAliases(
                    chromosomes: bundle.manifest.genome?.chromosomes ?? []
                ),
                referenceBundle: bundle
            ).preparingForBackgroundExport(shouldCancel: { Task.isCancelled })
            let featureTracks = annotationTracks(bundle).filter { region.trackIDs.contains($0.id) }
            let genome = try bundle.manifest.genome.map { try bundle.memberURL(for: $0.path, field: "genome.path") }
            urls = featureTracks.map(\.url) + urls + (genome.map { [$0] } ?? [])
        } else if let trackIDs = table.bundleCodingFeatureTrackIDs {
            // BIO ruling on M854 items 6 to 8 and V1-1 item 4. The CDS of the named tracks across the bundle, over the
            // exported rows, through the read the drawer makes. A named track the bundle lacks and a read at its limit
            // fail with 64 before anything is written, and the record states no feature count.
            resolver = try VariantTableBundleCodingFeatures.resolver(
                bundle: bundle, trackIDs: trackIDs, rows: rows,
                variantChromosomeAliasMap: table.variantChromosomeAliases, shouldCancel: { Task.isCancelled }
            )
            let featureTracks = annotationTracks(bundle).filter { trackIDs.contains($0.id) }
            let genome = try bundle.manifest.genome.map { try bundle.memberURL(for: $0.path, field: "genome.path") }
            urls = featureTracks.map(\.url) + urls + (genome.map { [$0] } ?? [])
        }
        return (AnnotationTableExportSnapshot.captureVariants(
            rows, columns: table.columns, scope: scope,
            numericInfoColumnIDs: Set(table.numericColumnIDs), integerInfoColumnIDs: Set(table.integerColumnIDs),
            sourceURLs: urls, queryDescription: table.query,
            resolvedText: AnnotationTableExport.variantResolvedText(
                rows: rows, columns: table.columns, callerSettingsByTrack: callerSettings, resolverSnapshot: resolver
            )
        ), urls)
    }

    private static func genotypes(
        bundle: ReferenceBundle, table: AnnotationTableExportSelection, scope: AnnotationTableExportScope,
        identities: [String]
    ) async throws -> (AnnotationTableExportSnapshot, [URL]) {
        let tracks = variantTracks(bundle)
        let keys = try identities.map { try genotypeKey($0, tracks: tracks) }
        let loaded = try await variantResults(bundle: bundle, tracks: tracks, keys: keys)
        var genotypes: [String: [Int64: [GenotypeRecord]]] = [:]
        for track in loaded.named {
            try Task.checkCancellation()
            genotypes[track.id] = try VariantDatabase(url: track.url).genotypesForExport(variantRowIds: rowIDs(keys, in: track))
        }
        let rows = try zip(identities, keys).map { identity, key -> AnnotationTableGenotypeRow in
            guard let variant = loaded.results[key.track.id]?[key.rowID],
                  let genotype = genotypes[key.track.id]?[key.rowID]?.first(where: { $0.sampleName == key.sample })
            else { throw missingRow(identity) }
            return AnnotationTableGenotypeRow(
                sampleName: genotype.sampleName, variantRowId: key.rowID,
                variantID: variant.name, chromosome: variant.chromosome,
                position: variant.start, ref: variant.ref ?? "", alt: variant.alt ?? "",
                genotype: genotype.genotype ?? "./.",
                zygosity: AnnotationTableGenotypeRow.classify(allele1: genotype.allele1, allele2: genotype.allele2),
                alleleDepths: genotype.alleleDepths ?? "", depth: genotype.depth,
                genotypeQuality: genotype.genotypeQuality,
                alleleBalance: AnnotationTableGenotypeRow.computeAlleleBalance(from: genotype.alleleDepths),
                infoDict: variant.infoDict ?? [:], trackId: key.track.id,
                trackName: variant.trackName ?? key.track.id
            )
        }
        let urls = loaded.named.map(\.url) + loaded.overlayURLs
        return (AnnotationTableExportSnapshot.captureGenotypes(
            rows, columns: table.columns, scope: scope,
            numericInfoColumnIDs: Set(table.numericColumnIDs), integerInfoColumnIDs: Set(table.integerColumnIDs),
            sourceURLs: urls, queryDescription: table.query
        ), urls)
    }

    /// The samples of every variant database, the first database naming a sample and source winning, with the
    /// visible flag and display name the drawer wrote in `editedValues` (R1 item 3).
    private static func samples(
        bundle: ReferenceBundle, table: AnnotationTableExportSelection, scope: AnnotationTableExportScope,
        selection: ViewerExportSelection
    ) throws -> (AnnotationTableExportSnapshot, [URL]) {
        let tracks = variantTracks(bundle)
        var entries: [String: (name: String, sourceFile: String, metadata: [String: String])] = [:]
        for track in tracks {
            try Task.checkCancellation()
            let database = try VariantDatabase(url: track.url)
            let sourceBySample = database.allSourceFiles()
            let stored = database.allSampleMetadata()
            let samples = stored.isEmpty ? database.sampleNames().map { (name: $0, metadata: [String: String]()) } : stored
            for sample in samples {
                let sourceFile = sourceBySample[sample.name] ?? ""
                let rowKey = "\(sample.name)|\(sourceFile)"
                if entries[rowKey] == nil {
                    entries[rowKey] = (sample.name, sourceFile, sample.metadata)
                }
            }
        }
        let rows = try selection.identities.map { identity -> AnnotationTableSampleRow in
            guard let entry = entries[identity] else { throw missingRow(identity) }
            let edited = selection.editedValues[identity] ?? [:]
            return AnnotationTableSampleRow(
                rowKey: identity, name: entry.name, sourceFile: entry.sourceFile,
                isVisible: edited["visible"] != "false", metadata: entry.metadata,
                displayName: edited["displayName"]
            )
        }
        let urls = tracks.map(\.url)
        return (AnnotationTableExportSnapshot.captureSamples(
            rows, columns: table.columns, scope: scope, sourceURLs: urls, queryDescription: table.query
        ), urls)
    }

    // MARK: - Sources

    /// The annotation tracks with a database in the bundle, in the manifest's order.
    private static func annotationTracks(_ bundle: ReferenceBundle) -> [Track] {
        bundle.manifest.annotations.compactMap { track in
            guard let path = track.databasePath,
                  let url = try? bundle.memberURL(for: path, field: "annotations[\(track.id)].databasePath"),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Track(id: track.id, name: track.name, url: url.standardizedFileURL)
        }
    }

    /// The variant tracks with a database in the bundle, in the manifest's order, as `AnnotationSearchIndex` opens
    /// them.
    private static func variantTracks(_ bundle: ReferenceBundle) -> [Track] {
        bundle.variantTrackIds.compactMap { trackID in
            guard let info = bundle.variantTrack(id: trackID), let path = info.databasePath,
                  let url = try? bundle.memberURL(for: path, field: "variants[\(trackID)].databasePath"),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Track(id: trackID, name: info.name, url: url.standardizedFileURL)
        }
    }

    /// Splits `<track>:<row id>` against the bundle's track ids, so a track id that holds a colon still parses.
    private static func rowKey(_ identity: String, tracks: [Track], kind: String) throws -> RowKey {
        for track in tracks where identity.hasPrefix(track.id + ":") {
            if let rowID = Int64(identity.dropFirst(track.id.count + 1)) { return RowKey(track: track, rowID: rowID) }
        }
        throw unknownRow(identity, kind: kind)
    }

    /// Splits `<track>:<variant row id>:<sample>`, the genotype tab's identity.
    private static func genotypeKey(_ identity: String, tracks: [Track]) throws -> RowKey {
        for track in tracks where identity.hasPrefix(track.id + ":") {
            let rest = identity.dropFirst(track.id.count + 1)
            if let colon = rest.firstIndex(of: ":"), let rowID = Int64(rest[..<colon]) {
                return RowKey(track: track, rowID: rowID, sample: String(rest[rest.index(after: colon)...]))
            }
        }
        throw unknownRow(identity, kind: "variant")
    }

    /// The row ids `keys` name in `track`, in order, each once.
    private static func rowIDs(_ keys: [RowKey], in track: Track) -> [Int64] {
        var seen = Set<Int64>()
        return keys.compactMap { $0.track.id == track.id && seen.insert($0.rowID).inserted ? $0.rowID : nil }
    }

    private static func unknownRow(_ identity: String, kind: String) -> Refusal {
        Refusal(message: "The selection names the row \(identity), which no \(kind) track of this bundle holds. "
            + "Pass the bundle the table was exported from.")
    }

    private static func missingRow(_ identity: String) -> Refusal {
        Refusal(message: "The bundle no longer holds the row \(identity) that the selection names. "
            + "Export the table again from the app.")
    }

    /// The variant rows `keys` name, by track and row id, converted as the drawer's query converts them, with
    /// projected INFO and the track's name. `named` are the tracks read, in the manifest's order, and `overlayURLs`
    /// the VCFs the projection read, by sorted track id and then by path, as the drawer names them.
    private static func variantResults(
        bundle: ReferenceBundle, tracks: [Track], keys: [RowKey]
    ) async throws -> (results: [String: [Int64: AnnotationSearchResult]], named: [Track], overlayURLs: [URL]) {
        let named = tracks.filter { track in keys.contains { $0.track.id == track.id } }
        var handles: [(trackId: String, db: VariantDatabase)] = []
        for track in named {
            handles.append((trackId: track.id, db: try VariantDatabase(url: track.url)))
        }
        var aliasMaps = BundleChromosomeAliasMaps()
        aliasMaps.reset(chromosomes: bundle.manifest.genome?.chromosomes ?? [])
        let sources = VariantFormatOverlaySource.iVarSources(bundle: bundle, databases: handles, aliasMaps: &aliasMaps)
        let overlay = await VariantFormatOverlayLoader.load(sources: sources)
        var results: [String: [Int64: AnnotationSearchResult]] = [:]
        for (track, handle) in zip(named, handles) {
            try Task.checkCancellation()
            let records = try handle.db.variantsForExport(rowIDs: rowIDs(keys, in: track))
            let infoByID = try handle.db.batchInfoValuesForExport(variantIds: records.compactMap(\.id))
            for record in records {
                guard let rowID = record.id else { continue }
                let projected = overlay.projectedInfo(trackID: track.id, record: record, existing: infoByID[rowID] ?? [:])
                results[track.id, default: [:]][rowID] = record.toSearchResult(
                    trackId: track.id, infoDict: projected, sourceFile: track.name
                )
            }
        }
        let overlayURLs = Dictionary(grouping: overlay.sourceIdentities, by: \.trackID)
            .sorted { $0.key < $1.key }
            .flatMap { $0.value.map(\.url).sorted { $0.path < $1.path } }
        return (results, named, overlayURLs)
    }

    /// The coding features of the region's tracks over the region, read from the bundle with the call the viewer
    /// makes, in the manifest's track order and with no coding bases cached (R1 items 4 and 5).
    private static func codingFeatures(
        bundle: ReferenceBundle, region: AnnotationTableFeatureRegion
    ) throws -> [VariantTableExportResolverSnapshot.CodingFeature] {
        let genomicRegion = GenomicRegion(chromosome: region.chromosome, start: region.start, end: region.end)
        var annotations: [SequenceAnnotation] = []
        for trackID in bundle.annotationTrackIds where region.trackIDs.contains(trackID) {
            try Task.checkCancellation()
            annotations += try bundle.getAnnotationsSync(trackId: trackID, region: genomicRegion)
        }
        return VariantTableCodingFeatures.features(
            annotations: annotations,
            fallbackChromosome: region.chromosome,
            chromosomeName: { bundle.chromosome(named: $0)?.name ?? $0 },
            context: { _ in nil }
        )
    }
}
