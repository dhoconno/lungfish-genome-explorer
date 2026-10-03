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
/// R1 and R2 entries each count the pairs.
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
        guard pairs > 0, singles > 0 else { return nil }
        return ReadClassification(files: [
            .init(filename: filename, role: .pairedR1, readCount: pairs),
            .init(filename: filename, role: .pairedR2, readCount: pairs),
            .init(filename: filename, role: singleRole, readCount: singles),
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
