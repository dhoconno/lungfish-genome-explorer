// ReferenceBundleMergeService+Sources.swift - Reading, checking and re-exporting the source bundles of a reference merge
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension ReferenceBundleMergeService {

    // MARK: - Source inspection

    /// A source bundle resolved into everything the merge needs from it.
    struct SourceBundle {
        let bundleURL: URL
        let displayName: String
        /// The rich bundle manifest, or `nil` for a legacy `ReferenceSequenceFolder` bundle.
        ///
        /// Legacy bundles carry a `ReferenceSequenceManifest` instead: a copied FASTA and
        /// nothing else. They are sequence-only by construction, so a missing rich manifest
        /// here is a known-safe shape, not an unknown one.
        let manifest: BundleManifest?
        /// Display name for the merged bundle's `SourceInfo`, from whichever manifest applies.
        let sourceName: String
        let fastaURL: URL
        /// Sequence names this bundle contributes to the merged FASTA.
        let sequenceNames: [String]
        /// Identifier stem used to namespace this bundle's annotation tracks in the output.
        let namespaceSlug: String

        var annotations: [AnnotationTrackInfo] { manifest?.annotations ?? [] }
    }

    static func inspectSourceBundles(_ bundleURLs: [URL]) async throws -> [SourceBundle] {
        var sources: [SourceBundle] = []
        var usedSlugs: Set<String> = []
        for bundleURL in bundleURLs {
            let displayName = bundleURL.deletingPathExtension().lastPathComponent
            let fastaURL = try resolveFASTAURL(in: bundleURL)

            var manifest: BundleManifest?
            var sourceName = displayName
            var sequenceNames: [String] = []

            if FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent(BundleManifest.filename).path
            ) {
                if let loaded = try? BundleManifest.load(from: bundleURL) {
                    manifest = loaded
                    sourceName = loaded.name.isEmpty ? displayName : loaded.name
                    sequenceNames = (loaded.genome?.chromosomes ?? []).map(\.name)
                } else if let legacyName = legacyReferenceManifestName(in: bundleURL) {
                    // Legacy `ReferenceSequenceFolder` bundle: a different manifest schema,
                    // sequence-only by construction. Read names straight from its FASTA.
                    sourceName = legacyName
                    sequenceNames = try await readSequenceNames(in: fastaURL)
                } else {
                    // Fail closed. A manifest we cannot read under either schema may declare
                    // variants, alignments, or annotations the merge would silently drop.
                    throw ReferenceBundleMergeServiceError.unreadableManifest(
                        bundleName: displayName,
                        underlying: "manifest.json did not decode as a Lungfish bundle manifest"
                    )
                }
            } else {
                sequenceNames = try await readSequenceNames(in: fastaURL)
            }

            var slug = slugify(sourceName)
            if !usedSlugs.insert(slug).inserted {
                var counter = 2
                while !usedSlugs.insert("\(slug)_\(counter)").inserted {
                    counter += 1
                }
                slug = "\(slug)_\(counter)"
            }
            sources.append(
                SourceBundle(
                    bundleURL: bundleURL,
                    displayName: displayName,
                    manifest: manifest,
                    sourceName: sourceName,
                    fastaURL: fastaURL,
                    sequenceNames: sequenceNames,
                    namespaceSlug: slug
                )
            )
        }
        return sources
    }

    static let legacyManifestDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func legacyReferenceManifestName(in bundleURL: URL) -> String? {
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        guard let data = try? Data(contentsOf: manifestURL),
              let legacy = try? Self.legacyManifestDecoder.decode(
                  ReferenceSequenceManifest.self,
                  from: data
              ) else {
            return nil
        }
        return legacy.name
    }

    /// Reads record names out of a FASTA without loading its sequence bases.
    static func readSequenceNames(in fastaURL: URL) async throws -> [String] {
        var names: [String] = []
        for try await line in fastaURL.linesAutoDecompressing() where line.hasPrefix(">") {
            let header = line.dropFirst().trimmingCharacters(in: .whitespaces)
            let name = header.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if !name.isEmpty { names.append(name) }
        }
        return names
    }

    static func validateNoUnsupportedPayloads(in sources: [SourceBundle]) throws {
        var offenders: [UnsupportedPayloadReport] = []
        for source in sources {
            guard let manifest = source.manifest else { continue }
            var payloads: [String] = []
            if manifest.genome == nil {
                payloads.append("no genome sequence")
            }
            if !manifest.variants.isEmpty {
                payloads.append("variant tracks")
            }
            if !manifest.tracks.isEmpty {
                payloads.append("signal tracks")
            }
            if !manifest.alignments.isEmpty {
                payloads.append("alignments")
            }
            if !payloads.isEmpty {
                offenders.append(
                    UnsupportedPayloadReport(bundleName: source.displayName, payloads: payloads)
                )
            }
        }
        guard offenders.isEmpty else {
            throw ReferenceBundleMergeServiceError.unsupportedPayloads(offenders: offenders)
        }
    }

    /// Rejects duplicate sequence names before any bytes are written.
    ///
    /// Without this, `appendFASTAContents` concatenates blindly and `samtools faidx` fails
    /// on the duplicate record, after which `NativeBundleBuilder` silently falls back to a
    /// manual index. The output would carry an ambiguous `.fai` and annotations would bind
    /// to whichever duplicate the index happened to keep.
    static func validateNoSequenceNameCollisions(in sources: [SourceBundle]) throws {
        var bundlesBySequenceName: [String: [String]] = [:]
        for source in sources {
            for name in source.sequenceNames {
                bundlesBySequenceName[name, default: []].append(source.displayName)
            }
        }
        let collisions = bundlesBySequenceName
            .filter { $0.value.count > 1 }
            .map { SequenceNameCollision(sequenceName: $0.key, bundleNames: $0.value) }
            .sorted { $0.sequenceName < $1.sequenceName }
        guard collisions.isEmpty else {
            throw ReferenceBundleMergeServiceError.duplicateSequenceNames(collisions: collisions)
        }
    }

    // MARK: - Annotation preservation

    /// The outcome of re-exporting source annotation tracks for the merged build.
    struct AnnotationExport {
        let inputs: [AnnotationInput]
        /// A warning to persist in the merged manifest when tracks had to be skipped.
        let warning: BundleWarning?
    }

    /// Re-exports every source annotation track as a GFF3 the builder can reconsume.
    ///
    /// GenBank imports keep no copy of their original `.gb` inside the bundle, so the
    /// annotation SQLite database is the durable representation. Exporting it back to GFF3
    /// round-trips through a format `NativeBundleBuilder` already ingests, and keeps each
    /// track's records bound to their original sequence names.
    ///
    /// A track can be un-re-readable for three reasons: it predates `databasePath` (legacy
    /// or placeholder artifact), its declared path fails bundle-member validation, or the
    /// file is simply gone. None of those should abort a merge that can otherwise succeed,
    /// so such tracks are skipped -- but every skip is accumulated into a returned
    /// `BundleWarning` and reported at `.warning` level, so the loss is recorded in the
    /// merged manifest and visible in the Operations log rather than silent.
    static func exportAnnotationInputs(
        from sources: [SourceBundle],
        into tempDirectory: URL,
        reporter: ProgressReporter
    ) async throws -> AnnotationExport {
        let exportDirectory = tempDirectory.appendingPathComponent("annotations", isDirectory: true)
        var inputs: [AnnotationInput] = []
        var skipped: [String] = []
        var didCreateDirectory = false
        // `namespaceSlug` (assigned in `inspectSourceBundles`) is already deduped PER SOURCE
        // BUNDLE, but does nothing to protect against two different `track.id` values within
        // the SAME bundle slugifying to the same string (e.g. "Genes v1" and "Genes-v1" both
        // collapse to "genes_v1" under `slugify`). Without this set, the second track's export
        // would silently overwrite the first's GFF3 file on disk (same `exportURL`, derived
        // directly from `trackID`) and both `AnnotationInput`s would carry the same `id`.
        // Mirrors the `usedSlugs` dedup in `inspectSourceBundles` exactly: on collision, append
        // a numeric suffix until the candidate is unique.
        var usedTrackIDs: Set<String> = []

        for source in sources {
            for track in source.annotations {
                let label = "\"\(track.name)\" in \(source.displayName)"

                guard let databasePath = track.databasePath else {
                    skipped.append("\(label) (no annotation database; predates indexed annotations)")
                    continue
                }
                let databaseURL: URL
                do {
                    databaseURL = try BundleManifest.validatedBundleMemberURL(
                        for: databasePath,
                        in: source.bundleURL,
                        field: "annotations.database_path"
                    )
                } catch {
                    skipped.append("\(label) (declared path '\(databasePath)' is not a valid bundle member)")
                    continue
                }
                guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                    skipped.append("\(label) (annotation database file '\(databasePath)' is missing)")
                    continue
                }

                if !didCreateDirectory {
                    try FileManager.default.createDirectory(
                        at: exportDirectory,
                        withIntermediateDirectories: true
                    )
                    didCreateDirectory = true
                }

                var trackID = "\(source.namespaceSlug)_\(slugify(track.id))"
                if !usedTrackIDs.insert(trackID).inserted {
                    var counter = 2
                    while !usedTrackIDs.insert("\(trackID)_\(counter)").inserted {
                        counter += 1
                    }
                    trackID = "\(trackID)_\(counter)"
                }
                let exportURL = exportDirectory.appendingPathComponent("\(trackID).gff3")
                let database = try AnnotationDatabase(url: databaseURL)
                try AnnotationDatabaseGFFExporter.export(database: database, to: exportURL)
                await reporter.report(0.3, "Exported \(track.name) from \(source.displayName)", nil)

                inputs.append(
                    AnnotationInput(
                        url: exportURL,
                        name: "\(track.name) (\(source.sourceName))",
                        description: track.description
                            ?? "Merged from \(source.displayName)",
                        id: trackID,
                        annotationType: track.annotationType
                    )
                )
            }
        }

        let warning = skipped.isEmpty ? nil : BundleWarning(
            category: "merge.annotations",
            code: "annotation_track_dropped",
            message: """
                \(skipped.count) annotation \(skipped.count == 1 ? "track was" : "tracks were") \
                not carried into the merged bundle because \
                \(skipped.count == 1 ? "it" : "they") could not be re-read: \
                \(skipped.joined(separator: "; ")).
                """
        )
        return AnnotationExport(inputs: inputs, warning: warning)
    }

    /// The outcome of trying to carry GenBank record stores across a merge.
    struct MergedRecordStore {
        /// The unioned store, or `nil` when no store could be carried across.
        let url: URL?
        /// A warning to persist in the merged manifest when a store was dropped.
        let warning: BundleWarning?
    }

    /// Unions the GenBank record stores of every source that has one.
    ///
    /// Returns an empty result when no source carries a store, which keeps FASTA-only
    /// merges byte identical to their previous behaviour.
    static func mergeRecordStores(
        from sources: [SourceBundle],
        into tempDirectory: URL
    ) throws -> MergedRecordStore {
        #if DEBUG
        recordStoreThreadingProbe?()
        #endif
        var storeURLs: [URL] = []
        var sourcesWithoutStore: [String] = []
        for source in sources {
            guard let recordStore = source.manifest?.recordStore,
                  recordStore.format == ReferenceRecordStoreInfo.supportedFormat,
                  recordStore.schemaVersion == GenBankRecordDatabase.schemaVersion,
                  let storeURL = try? BundleManifest.validatedBundleMemberURL(
                      for: recordStore.databasePath,
                      in: source.bundleURL,
                      field: "record_store.database_path"
                  ),
                  FileManager.default.fileExists(atPath: storeURL.path) else {
                sourcesWithoutStore.append(source.displayName)
                continue
            }
            storeURLs.append(storeURL)
        }
        guard !storeURLs.isEmpty else {
            return MergedRecordStore(url: nil, warning: nil)
        }

        // `NativeBundleBuilder.embedReferenceRecordStore` validates the store row-for-row
        // against the merged FASTA, so a store covering only some sequences would fail the
        // build outright. Carry the store across only when every source contributes one, and
        // record a warning when we cannot, so the loss is visible in the merged manifest
        // rather than silent.
        guard sourcesWithoutStore.isEmpty else {
            return MergedRecordStore(
                url: nil,
                warning: BundleWarning(
                    category: "merge.record-store",
                    code: "partial_record_store_dropped",
                    message: """
                        GenBank record metadata (LOCUS, DEFINITION, ACCESSION, and so on) was \
                        dropped because \(sourcesWithoutStore.joined(separator: ", ")) \
                        \(sourcesWithoutStore.count == 1 ? "does" : "do") not carry a record \
                        store. A record store must cover every merged sequence.
                        """
                )
            )
        }

        let mergedStoreURL = tempDirectory.appendingPathComponent("genbank_records.sqlite")
        try GenBankRecordDatabase.createByMerging(sourceURLs: storeURLs, at: mergedStoreURL)
        return MergedRecordStore(url: mergedStoreURL, warning: nil)
    }

}
