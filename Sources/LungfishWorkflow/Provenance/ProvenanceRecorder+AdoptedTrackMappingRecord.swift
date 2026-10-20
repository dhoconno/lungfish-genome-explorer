// ProvenanceRecorder+AdoptedTrackMappingRecord.swift - The mapping record of an adopted alignment track, in the reader order of lane 13.16
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension ProvenanceRecorder {
    /// The extension of the adopt record `<bam stem>.adopt-mapping-provenance.json`, which `bam adopt-mapping`
    /// writes beside each BAM it adopts.
    public static let adoptRecordExtension = "adopt-mapping-provenance.json"

    /// The typed mapping record of the adopted track whose BAM is `bamURL`, or nil when the bundle keeps none for it.
    ///
    /// The reader looks in this order (2.13 lane 13.16, BIO ruling item 3).
    /// 1. The file the track's adopt record names in `sourceMappingProvenancePath`, when that is not the shared
    ///    `mapping-provenance.json` of the track's folder.
    /// 2. The track's own `<bam stem>.mapping-provenance.json`.
    /// 3. For a bundle written before 2.13, the shared `mapping-provenance.json` of the track's folder, only when the
    ///    track's adopt record names that file and gave it, as an output, the SHA-256 the file has now. Every adopt
    ///    rewrote that file, so a record whose digest differs is a later track's and is never shown as this one's.
    ///
    /// A read never rewrites an older bundle.
    public static func adoptedTrackMappingRecord(
        forAlignmentAt bamURL: URL
    ) -> (sidecarURL: URL, reading: ProvenanceEnvelopeReader.Reading)? {
        let sharedURL = bamURL.deletingLastPathComponent()
            .appendingPathComponent(MappingProvenance.filename)
            .standardizedFileURL
        let named = mappingRecordNamedByAdoptRecord(forAlignmentAt: bamURL)
        if let named, named.url.path != sharedURL.path,
           let found = mappingProvenanceCandidate(atFile: named.url) {
            return found
        }
        if let found = mappingProvenanceCandidate(atFile: MappingProvenance.trackRecordURL(forAlignmentAt: bamURL)) {
            return found
        }
        guard let named, named.url.path == sharedURL.path,
              let recordedDigest = named.sha256,
              sha256(of: sharedURL) == recordedDigest else {
            return nil
        }
        return mappingProvenanceCandidate(atFile: sharedURL)
    }

    /// The mapping record the track's adopt record names in `sourceMappingProvenancePath`, resolved in the bundle the
    /// adopt record sits in, with the SHA-256 the adopt record gave that file as an output. Both paths the record
    /// names are bundle-relative, so the bundle is the adopt record's own path less `adoptMappingProvenancePath`.
    private static func mappingRecordNamedByAdoptRecord(forAlignmentAt bamURL: URL) -> (url: URL, sha256: String?)? {
        let adoptRecordURL = bamURL.deletingPathExtension().appendingPathExtension(adoptRecordExtension)
        guard let run = loadEnvelope(fromSidecar: adoptRecordURL)?.legacyWorkflowRun(),
              let named = run.parameters["sourceMappingProvenancePath"]?.stringValue,
              let adoptPath = run.parameters["adoptMappingProvenancePath"]?.stringValue else {
            return nil
        }
        var bundleURL = adoptRecordURL
        for _ in adoptPath.split(separator: "/") {
            bundleURL.deleteLastPathComponent()
        }
        let url = (named.hasPrefix("/") ? URL(fileURLWithPath: named) : bundleURL.appendingPathComponent(named))
            .standardizedFileURL
        // A named path that leaves the bundle, through `..` or as an absolute path, is never read (SWIFT 6).
        guard url.path.hasPrefix(bundleURL.standardizedFileURL.path + "/") else {
            return nil
        }
        let output = run.allOutputFiles.first { record in
            URL(fileURLWithPath: record.path).standardizedFileURL.path == url.path || record.path.hasSuffix("/\(named)")
        }
        return (url, output?.sha256)
    }
}
