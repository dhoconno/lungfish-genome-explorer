// Kraken2TaxonomyTableExport+ReferenceDatabases.swift - The reference database each sample of a Kraken2 table was classified against
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension Kraken2TaxonomyTableExport {
    /// The Kraken2 reference database one sample of the table was classified against, as that sample's classification
    /// result records it (Phase 2.13 lane 13.35, R8 of BIO-Q-A2). The leaf never opens the database, so its record
    /// names the database through these values and never lists it as an input.
    public struct ReferenceDatabase: Equatable, Sendable {
        /// What a field reads when the result does not record it.
        public static let unknown = "unknown"
        /// The reason of an unknown digest when the sample's result records none.
        public static let noDigestReason = "The sample's classification result records no digest for its database."
        /// The reason of an unknown digest when no readable result is found for the sample.
        public static let noResultReason = "No readable classification-result.json was found for the sample, "
            + "so its database digest is not recorded."

        public let sampleId: String
        public let name: String
        public let version: String
        /// Nil when the result records none.
        public let digest: String?
        /// Why the digest is unknown, nil when it is known.
        public let digestReason: String?

        /// The entry as the record's `referenceDatabases` array holds it. The digest reads `unknown` with a `reason`
        /// when the result records none.
        public var parameterValue: ParameterValue {
            var fields: [String: ParameterValue] = [
                "sample": .string(sampleId),
                "name": .string(name),
                "version": .string(version),
                "digest": .string(digest ?? Self.unknown),
            ]
            if let digestReason {
                fields["reason"] = .string(digestReason)
            }
            return .dictionary(fields)
        }
    }

    /// The reference database of each sample the table holds, in the order given, with the files the leaf read to
    /// learn it, which the record must name as inputs beside the file the table is read from.
    ///
    /// The sidecar form reads the sidecar the leaf already names as an input, so it adds no file. The database form
    /// reads the batch manifest, which gives each sample's result folder, and one `classification-result.json` for
    /// each picked sample. With no manifest, a database that holds one sample reads the sidecar beside it. A database
    /// that holds several samples and has no manifest has no run beside it, so it reads no sidecar, however few of
    /// its samples are picked. That rule counts `knownSampleIds`, every sample the database holds, and never the
    /// picked `sampleIds`. A caller keeps only the files that exist. A sample whose result cannot be read keeps the
    /// name and version of the batch manifest when the folder has one and gets an unknown digest with its reason.
    /// Only the configuration of each sidecar is decoded, so no report is read.
    public static func referenceDatabases(
        source: Source,
        sampleIds: [String],
        knownSampleIds: [String]
    ) -> (entries: [ReferenceDatabase], inputs: [URL]) {
        switch source {
        case .sidecar(let sidecarURL):
            let config = classificationConfig(at: sidecarURL)
            return (sampleIds.map { referenceDatabase(sampleId: $0, config: config, manifest: nil) }, [])
        case .database(let databaseURL):
            let folder = databaseURL.deletingLastPathComponent()
            let manifest = MetagenomicsBatchResultStore.loadClassification(from: folder)
            var inputs = [folder.appendingPathComponent(ClassificationBatchResultManifest.filename)]
            var entries: [ReferenceDatabase] = []
            for sampleId in sampleIds {
                var config: ClassificationConfig?
                if let record = manifest?.samples.first(where: { $0.sampleId == sampleId }) {
                    let sidecarURL = folder
                        .appendingPathComponent(record.resultDirectory, isDirectory: true)
                        .appendingPathComponent(sidecarFileName)
                    inputs.append(sidecarURL)
                    config = classificationConfig(at: sidecarURL)
                } else if manifest == nil, knownSampleIds.count == 1 {
                    // A database built for one run sits beside that run's sidecar, and the viewer reads it there
                    // (ViewerViewController+Taxonomy.swift:432-438). A database of several samples sits beside no
                    // run, so a file of that name there belongs to none of the picked samples.
                    let sidecarURL = folder.appendingPathComponent(sidecarFileName)
                    inputs.append(sidecarURL)
                    config = classificationConfig(at: sidecarURL)
                }
                entries.append(referenceDatabase(sampleId: sampleId, config: config, manifest: manifest))
            }
            return (entries, inputs)
        }
    }

    private static func referenceDatabase(
        sampleId: String,
        config: ClassificationConfig?,
        manifest: ClassificationBatchResultManifest?
    ) -> ReferenceDatabase {
        guard let config else {
            return ReferenceDatabase(
                sampleId: sampleId,
                name: known(manifest?.databaseName),
                version: known(manifest?.databaseVersion),
                digest: nil,
                digestReason: ReferenceDatabase.noResultReason
            )
        }
        let digest = config.databaseDigest.flatMap { $0.isEmpty ? nil : $0 }
        return ReferenceDatabase(
            sampleId: sampleId,
            name: known(config.databaseName),
            version: known(config.databaseVersion),
            digest: digest,
            digestReason: digest == nil ? ReferenceDatabase.noDigestReason : nil
        )
    }

    /// The text, or `unknown` when the result records none.
    private static func known(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return ReferenceDatabase.unknown }
        return text
    }

    /// The configuration a classification sidecar holds. Nil for a sidecar that is missing or cannot be decoded.
    private static func classificationConfig(at sidecarURL: URL) -> ClassificationConfig? {
        guard let data = try? Data(contentsOf: sidecarURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SidecarConfiguration.self, from: data))?.config
    }

    /// The part of `classification-result.json` the reference database comes from.
    private struct SidecarConfiguration: Decodable {
        let config: ClassificationConfig
    }
}
