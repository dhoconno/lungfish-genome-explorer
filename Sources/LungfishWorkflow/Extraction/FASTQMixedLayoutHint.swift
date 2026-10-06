// FASTQMixedLayoutHint.swift - The sidecar that marks one FASTQ file as mixing single reads with pairs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The read roles of one FASTQ file that holds adjacent mate pairs and single
/// reads (merged reads or orphans), written to the file's metadata sidecar.
///
/// The layout scan reads the first 100,000 records. A file that holds every
/// pair before its single reads (a materialized merge bundle, a trim of a
/// mixed file) looks strictly interleaved to it when it holds more pair
/// records than that, and a positional pair tool then pairs the single reads
/// with each other. The sidecar's read roles are merge evidence, so the scan
/// says mixed (D2 and D10, Phase 1.5 lane A7). The roles take the form an
/// import with a merge recipe writes: every role names the one file, and the
/// R1 and R2 entries each count the pairs. A file that holds only pairs gets
/// the same form with no single role (``pairsOnlyClassification(pairs:singles:filename:)``).
public enum FASTQMixedLayoutHint {

    /// The number of adjacent mate pairs and of single records in a FASTQ
    /// file, by the pairing rule of the layout scan
    /// (``FASTQReadLayoutClassifier/areMates(_:_:)``), read in one streaming
    /// pass over the headers.
    public static func countPairsAndSingles(in fastqURL: URL) throws -> (pairs: Int, singles: Int) {
        var pairs = 0
        var singles = 0
        var pending: String?
        var lineIndex = 0
        try fastqURL.forEachLineAutoDecompressing { line in
            defer { lineIndex += 1 }
            guard lineIndex % 4 == 0, line.hasPrefix("@") else { return }
            let header = String(line.dropFirst())
            if let previous = pending {
                if FASTQReadLayoutClassifier.areMates(previous, header) {
                    pairs += 1
                    pending = nil
                } else {
                    singles += 1
                    pending = header
                }
            } else {
                pending = header
            }
        }
        if pending != nil { singles += 1 }
        return (pairs, singles)
    }

    /// The roles of a file holding `pairs` pairs and `singles` single reads
    /// of `singleRole`, every role naming `filename`. Nil when the file holds
    /// no single read or no pair, which needs no hint.
    public static func classification(
        pairs: Int,
        singles: Int,
        singleRole: ReadClassification.FileRole,
        filename: String
    ) -> ReadClassification? {
        classification(
            pairs: pairs,
            merged: singleRole == .merged ? singles : 0,
            unpaired: singleRole == .merged ? 0 : singles,
            filename: filename
        )
    }

    /// The roles of a file holding `pairs` pairs, `merged` merged reads and
    /// `unpaired` reads without a mate, every role naming `filename`. Nil when
    /// the file holds no single read or no pair, which needs no hint.
    public static func classification(
        pairs: Int,
        merged: Int,
        unpaired: Int,
        filename: String
    ) -> ReadClassification? {
        guard pairs > 0, merged + unpaired > 0 else { return nil }
        var files: [ReadClassification.FileEntry] = [
            .init(filename: filename, role: .pairedR1, readCount: pairs),
            .init(filename: filename, role: .pairedR2, readCount: pairs),
        ]
        if merged > 0 { files.append(.init(filename: filename, role: .merged, readCount: merged)) }
        if unpaired > 0 { files.append(.init(filename: filename, role: .unpaired, readCount: unpaired)) }
        return ReadClassification(files: files)
    }

    /// The pairing to record beside a file whose whole-file roles are
    /// `roles`. It is interleaved when they count pairs and no single read,
    /// and single-end when they count a single read.
    ///
    /// The label follows the count in both directions, as
    /// `TaxonomyExtractionPipeline.extractedLayout` sets it. A file that holds
    /// pairs and single reads is labelled single-end, the contract default
    /// for a file a positional tool must not pair, whatever a bounded scan of
    /// its first records saw (re-review F8-N1, Phase 2.1 lane L3).
    public static func pairingMode(recordedBeside roles: ReadClassification) -> IngestionMetadata.PairingMode {
        pairingMode(pairs: roles.pairedReadCount / 2, singles: roles.mergedReadCount + roles.unpairedReadCount)
    }

    /// The pairing to record beside a file that holds `pairs` adjacent mate
    /// pairs and `singles` single reads by its whole-file count, interleaved
    /// for pairs alone and single-end otherwise.
    public static func pairingMode(pairs: Int, singles: Int) -> IngestionMetadata.PairingMode {
        pairs > 0 && singles == 0 ? .interleaved : .singleEnd
    }

    /// The read roles a source bundle, or a file inside one, records for its
    /// reads. They are its derived manifest's, else the roles of a mixed
    /// payload's files, else its primary FASTQ sidecar's. A loose file's are
    /// its own sidecar's.
    public static func recordedRoles(of sourceURL: URL) -> ReadClassification? {
        let bundleURL = FASTQBundle.isBundleURL(sourceURL)
            ? sourceURL
            : SequenceInputResolver.enclosingFASTQBundleURL(for: sourceURL)
        if let bundleURL, let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
            if let roles = manifest.readClassification { return roles }
            if case .fullMixed(let roles) = manifest.payload { return roles }
        }
        return FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL ?? sourceURL)
            .flatMap { FASTQMetadataStore.load(for: $0)?.readClassification }
    }

    /// The roles of a file holding `pairs` pairs and no single read, every
    /// role naming `filename`. The R1 and R2 entries each count the pairs and
    /// no role names a single read. Nil when the file holds a single read,
    /// which ``classification(pairs:singles:singleRole:filename:)`` records,
    /// or no pair, which needs no hint.
    ///
    /// The operations dialog's import records this for an output of a merge
    /// bundle that kept only the unmerged pairs. The output inherits the merge
    /// in its lineage, which the layout scan reads as proof of single reads, so
    /// these counts are what show the read-set resolver that the file holds
    /// none (Phase 1.5 lane F6, re-review SHOULD-FIX 2).
    public static func pairsOnlyClassification(
        pairs: Int,
        singles: Int,
        filename: String
    ) -> ReadClassification? {
        guard pairs > 0, singles == 0 else { return nil }
        return ReadClassification(files: [
            .init(filename: filename, role: .pairedR1, readCount: pairs),
            .init(filename: filename, role: .pairedR2, readCount: pairs),
        ])
    }

    /// Records `classification` in the metadata sidecar of `fastqURL`,
    /// keeping whatever else the sidecar holds.
    public static func write(_ classification: ReadClassification, beside fastqURL: URL) {
        var metadata = FASTQMetadataStore.load(for: fastqURL) ?? PersistedFASTQMetadata()
        metadata.readClassification = classification
        FASTQMetadataStore.save(metadata, for: fastqURL)
    }

    /// The role of the single reads of a bundle or file whose recorded roles
    /// are `classification`: merged when it lists merged reads, else unpaired.
    public static func singleRole(of classification: ReadClassification?) -> ReadClassification.FileRole {
        (classification?.mergedReadCount ?? 0) > 0 ? .merged : .unpaired
    }
}
