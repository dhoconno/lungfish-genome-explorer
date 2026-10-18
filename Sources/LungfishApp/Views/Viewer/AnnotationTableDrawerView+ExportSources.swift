// AnnotationTableDrawerView+ExportSources.swift - What an annotation table export reads, per tab
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishOperations
import LungfishWorkflow

/// The files an annotation table export may read, captured at the click (Phase 2.12 lane 12.39, ARCH ruling on
/// 12.39 R1, "What the record names", settled answers G3 and M4). The record names the bundle's manifest, then per
/// tab the files the exported rows came from, each with its digest, and no file the rows did not come from.
struct AnnotationTableExportSources: Sendable {
    struct Track: Sendable, Equatable {
        let trackID: String
        let url: URL
    }

    /// The bundle's `manifest.json`, nil when the viewer shows no reference bundle.
    var manifestURL: URL?
    /// The bundle's genome, which the derived variant columns read.
    var genomeURL: URL?
    var annotationDatabases: [Track]
    var variantDatabases: [Track]
    /// The VCFs whose FORMAT values each variant track projects, by track.
    var overlayURLsByTrack: [String: [URL]]
    /// The annotation tracks of the coding features the viewer cached, when the export writes a derived variant
    /// column (coding feature, consequence or amino-acid change), else nil.
    var codingFeatureTrackIDs: [String]?

    /// The inputs of an export of `tab` whose rows come from the tracks `trackIDs`, the manifest first.
    ///
    /// - annotations: the annotation databases of the tracks named.
    /// - variants: the variant databases of the tracks named with their overlay VCFs, and, when a derived column is
    ///   written, the annotation databases of the cached coding features' tracks and the genome.
    /// - genotypes: the variant databases of the tracks named with their overlay VCFs.
    /// - samples: every variant database.
    func urls(tab: String, trackIDs: Set<String>) throws -> [URL] {
        func databases(_ tracks: [Track], in ids: Set<String>) -> [URL] {
            tracks.filter { ids.contains($0.trackID) }.map(\.url)
        }
        let overlays = trackIDs.sorted().flatMap { overlayURLsByTrack[$0] ?? [] }
        var tabURLs: [URL]
        switch tab {
        case "annotations":
            tabURLs = databases(annotationDatabases, in: trackIDs)
        case "variants":
            tabURLs = databases(variantDatabases, in: trackIDs) + overlays
            if let codingFeatureTrackIDs {
                tabURLs = databases(annotationDatabases, in: Set(codingFeatureTrackIDs)) + tabURLs
                    + (genomeURL.map { [$0] } ?? [])
            }
        case "genotypes":
            tabURLs = databases(variantDatabases, in: trackIDs) + overlays
        default:
            // The samples tab lists the samples of every variant database.
            tabURLs = variantDatabases.map(\.url)
        }
        return try validatedScientificTableExportSourceURLs(
            annotationDatabaseURLs: [],
            variantDatabaseURLs: [],
            overlaySourceURLs: [],
            additionalURLs: (manifestURL.map { [$0] } ?? []) + tabURLs
        )
    }
}

extension AnnotationTableDrawerView {
    /// The export's possible sources as the drawer and the viewer hold them at the click. `columns` are the columns
    /// the export writes, which say whether a derived variant column is among them.
    func scientificTableExportSources(columns: [ScientificTableColumn]) throws -> AnnotationTableExportSources {
        guard let index = searchIndex else { throw AnnotationTableExportServiceError.noScientificSources }
        // The viewer gives the bundle's manifest and, when it has one, the genome.
        let bundleFiles = try delegate?.annotationDrawerAdditionalExportSources(self) ?? []
        let derivedColumnIDs = [Self.codingFeatureColumn, Self.consequenceColumn, Self.aaChangeColumn].map(\.rawValue)
        let writesDerivedColumn = activeTab == .variants && columns.contains { derivedColumnIDs.contains($0.id) }
        return AnnotationTableExportSources(
            manifestURL: bundleFiles.first { $0.lastPathComponent == BundleManifest.filename },
            genomeURL: bundleFiles.first { $0.lastPathComponent != BundleManifest.filename },
            annotationDatabases: index.annotationDatabaseHandles.map { .init(trackID: $0.trackId, url: $0.db.databaseURL) },
            variantDatabases: index.variantDatabaseHandles.map { .init(trackID: $0.trackId, url: $0.db.databaseURL) },
            overlayURLsByTrack: Dictionary(grouping: index.variantFormatOverlaySnapshot.sourceIdentities, by: \.trackID)
                .mapValues { identities in identities.map(\.url).sorted { $0.path < $1.path } },
            codingFeatureTrackIDs: writesDerivedColumn
                ? (delegate?.annotationDrawerVariantExportResolverSnapshot(self) ?? .empty).codingFeatureTrackIDs
                : nil
        )
    }
}
