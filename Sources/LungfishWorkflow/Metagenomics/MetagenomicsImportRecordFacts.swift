// MetagenomicsImportRecordFacts.swift - The sample names and the source digest a classifier result import records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishIO

/// What the record of a classifier result import (Kraken2, EsViritu, TaxTriage, NAO-MGS or NVD) names about its
/// source (Phase 2.12 lane 12.04, BIO 5 and 6), merged into the record's resolved defaults.
///
/// - `sampleNames`, the sample ids as the result's own file names spell them, dots kept: the kreport's name
///   without its extension, the `<sample>.detected_virus.info.tsv` files of EsViritu, and the per-sample reports
///   and maps of TaxTriage. The combined multi-sample report `all.odr.txt` of TaxTriage names no sample, and a
///   result whose files name none has no `sampleNames`, which the record reads as Not recorded.
/// - `sourceDigest`, the SHA-256 of the source result. A file's digest is its own. A folder's is the SHA-256 of
///   one `<relative path>\t<SHA-256>` line for each of its files in path order, made from the digests the
///   record's inputs already carry, so each file is read once.
///
/// NAO-MGS and NVD records name their samples where the service parsed them, the sample ids of the table and of the CSV,
/// and get the digest here (Phase 2.12 lane 12.05).
enum MetagenomicsImportRecordFacts {
    static func resolvedDefaults(
        kind: MetagenomicsImportKind,
        sourceURLs: [URL],
        inputs: [ProvenanceFileDescriptor]
    ) -> [String: ParameterValue] {
        guard let source = sourceURLs.first else { return [:] }
        var facts: [String: ParameterValue] = [:]
        if [.kraken2, .esviritu, .taxtriage].contains(kind) {
            let names = sampleNames(kind: kind, source: source, inputs: inputs)
            if !names.isEmpty {
                facts["sampleNames"] = .array(names.map(ParameterValue.string))
            }
        }
        if let digest = sourceDigest(source: source, inputs: inputs) {
            facts["sourceDigest"] = .string(digest)
        }
        return facts
    }

    /// The per-sample file name endings of each kind, before which the sample id stands. The organism reports of
    /// TaxTriage are not listed. Their id comes from `TaxTriageOrganismReport`, which knows that the combined
    /// report `all.odr.txt` is no sample (review of lane 12.04, Fix 4).
    private static func sampleSuffixes(_ kind: MetagenomicsImportKind) -> [String] {
        switch kind {
        case .esviritu: return [".detected_virus.info.tsv"]
        case .taxtriage: return [".top_report.tsv", ".combined.gcfmap.tsv"]
        default: return []
        }
    }

    static func sampleNames(kind: MetagenomicsImportKind, source: URL, inputs: [ProvenanceFileDescriptor]) -> [String] {
        if kind == .kraken2 {
            return [source.deletingPathExtension().lastPathComponent]
        }
        let suffixes = sampleSuffixes(kind)
        let names = inputs.compactMap { descriptor -> String? in
            let url = URL(fileURLWithPath: descriptor.path)
            if kind == .taxtriage, TaxTriageOrganismReport.isOrganismReportFile(url) {
                return TaxTriageOrganismReport.sampleID(fromReportFile: url)
            }
            let name = url.lastPathComponent
            guard let suffix = suffixes.first(where: { name.hasSuffix($0) }), name.count > suffix.count else { return nil }
            return String(name.dropLast(suffix.count))
        }
        return Array(Set(names)).sorted()
    }

    static func sourceDigest(source: URL, inputs: [ProvenanceFileDescriptor]) -> String? {
        let root = source.resolvingSymlinksInPath().path
        if let own = inputs.first(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == root })?.checksumSHA256 {
            return own
        }
        // A file can be an input twice, once from the folder and once by its own path, so each path counts once.
        var checksums: [String: String] = [:]
        for descriptor in inputs {
            let path = URL(fileURLWithPath: descriptor.path).resolvingSymlinksInPath().path
            guard let checksum = descriptor.checksumSHA256, path.hasPrefix(root + "/") else { continue }
            checksums[String(path.dropFirst(root.count + 1))] = checksum
        }
        let lines = checksums.map { "\($0.key)\t\($0.value)\n" }.sorted()
        guard !lines.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(lines.joined().utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
