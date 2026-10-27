// AnnotationGFF3Export.swift - The GFF3 export of one source's annotations, shared by the app and its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The GFF3 export of one source's annotations (Phase 2.12 lane 12.39, ARCH ruling on 12.39 R2).
///
/// A reference bundle in the sidebar exports through `bundle export-gff3 <bundle>`, which loads the annotations
/// from the bundle's databases. An open document exports through `bundle export-gff3 --selection <file>`, whose
/// selection holds the document's annotations, since they may hold edits not saved to disk.
public enum AnnotationGFF3Export {
    /// The leaf's path under `lungfish-cli` (ARCH ruling X-1, a sibling of `bundle export`).
    public static let commandPath = ["bundle", "export-gff3"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish bundle export-gff3"
    /// The GFF3 source column every exported feature carries, the undefined value `.`. A bundle's annotation database
    /// holds a feature's attributes and not its source, so the export has no source to name and does not claim that
    /// Lungfish made the feature (Phase 3.0 lane GFF3-FIDELITY, walk GFF3-a).
    public static let featureSource = "."

    /// A bundle's annotations with the files read for them.
    public struct BundleAnnotations: Sendable {
        public let annotations: [SequenceAnnotation]
        /// `manifest.json`, then each annotation database opened, in the manifest's track order.
        public let inputURLs: [URL]
    }

    /// The annotation databases of a bundle's tracks that exist, in the manifest's track order. A track with no
    /// database, or with a database path that leaves the bundle, is skipped, as the app's loader always skipped it.
    public static func annotationDatabaseURLs(bundleURL: URL, manifest: BundleManifest) -> [URL] {
        annotationDatabases(bundleURL: bundleURL, manifest: manifest).map(\.url)
    }

    /// The same databases, each beside the id of the manifest track that holds it. A row's `annotation_db_track_id`
    /// carries that id, which the GFF3 export reads to tell the databases of a bundle apart.
    public static func annotationDatabases(bundleURL: URL, manifest: BundleManifest) -> [(trackID: String, url: URL)] {
        manifest.annotations.compactMap { track in
            guard let dbPath = track.databasePath,
                  let dbURL = try? BundleManifest.validatedBundleMemberURL(
                      for: dbPath,
                      in: bundleURL,
                      field: "annotations[\(track.id)].databasePath"
                  ),
                  FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
            return (trackID: track.id, url: dbURL)
        }
    }

    /// The files an export of a bundle's annotations reads, `manifest.json` and the annotation databases.
    public static func bundleInputURLs(bundleURL: URL) throws -> [URL] {
        let manifest = try BundleManifest.load(from: bundleURL)
        return [bundleURL.appendingPathComponent("manifest.json")]
            + annotationDatabaseURLs(bundleURL: bundleURL, manifest: manifest)
    }

    /// Loads every annotation of a bundle's annotation databases, reading only the manifest and the databases, never
    /// the genome (the app's GFF3 export and `bundle export-gff3` share it).
    public static func loadBundleAnnotations(bundleURL: URL) throws -> BundleAnnotations {
        try loadBundleAnnotations(bundleURL: bundleURL, manifest: BundleManifest.load(from: bundleURL))
    }

    public static func loadBundleAnnotations(bundleURL: URL, manifest: BundleManifest) throws -> BundleAnnotations {
        let databases = annotationDatabases(bundleURL: bundleURL, manifest: manifest)
        var annotations: [SequenceAnnotation] = []
        for database in databases {
            let db = try AnnotationDatabase(url: database.url)
            let records = db.query(limit: Int.max)
            annotations.append(contentsOf: records.map { $0.toAnnotation(trackID: database.trackID) })
        }
        return BundleAnnotations(
            annotations: annotations,
            inputURLs: [bundleURL.appendingPathComponent("manifest.json")] + databases.map(\.url)
        )
    }
}

/// An open document's annotations in the selection file (ARCH ruling on 12.39 R2 item 2). The leaf names the
/// selection file only, since the document is not read.
public struct AnnotationExportDocumentSelection: Codable, Sendable, Equatable {
    /// The document's name, which the export's messages show.
    public var sourceName: String
    /// The document's file, nil for a document never saved.
    public var sourcePath: String?
    /// The annotations as the document held them at the click, in order.
    public var annotations: [SequenceAnnotation]

    public init(sourceName: String, sourcePath: String?, annotations: [SequenceAnnotation]) {
        self.sourceName = sourceName
        self.sourcePath = sourcePath
        self.annotations = annotations
    }

    /// Equal when both write the same selection bytes, since `SequenceAnnotation` is not `Equatable`.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceName == rhs.sourceName && lhs.sourcePath == rhs.sourcePath
            && canonicalBytes(lhs.annotations) == canonicalBytes(rhs.annotations)
    }

    private static func canonicalBytes(_ annotations: [SequenceAnnotation]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(annotations)
    }
}
