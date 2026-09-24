// FASTQPairingModeResolver.swift - Decides whether a FASTQ holds interleaved pairs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Resolves whether a FASTQ input holds interleaved read pairs.
///
/// Paired imports are stored as one interleaved file inside a
/// `.lungfishfastq` bundle whose metadata records `pairingMode`. Tools that
/// are handed the bare file path cannot see that metadata and have to guess
/// from read names, which fails when both mates carry the same name. This
/// resolver gives the GUI and the CLI one answer, in this order:
///
/// 1. an explicit pairing the caller already knows (a `--pairing` flag),
/// 2. the pairing recorded by the enclosing bundle (derived manifest first,
///    then the FASTQ's `.lungfish-meta.json` sidecar),
/// 3. a name-based probe that also accepts identical adjacent names.
public enum FASTQPairingModeResolver {
    /// Pairing recorded by the bundle that holds `inputURL`, if any.
    ///
    /// Accepts a FASTQ file inside a bundle, the bundle directory itself, or
    /// a loose FASTQ with a sidecar next to it. Returns `nil` when no
    /// metadata exists, so callers can fall back to name detection.
    public static func bundlePairingMode(for inputURL: URL) -> IngestionMetadata.PairingMode? {
        let standardized = inputURL.standardizedFileURL
        if FASTQBundle.isFASTQFileURL(standardized),
           let sidecar = FASTQMetadataStore.load(for: standardized)?.ingestion?.pairingMode {
            return sidecar
        }
        guard let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: standardized) else {
            return nil
        }
        if let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL),
           let pairingMode = manifest.pairingMode {
            return pairingMode
        }
        if let primaryFASTQ = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
            return FASTQMetadataStore.load(for: primaryFASTQ)?.ingestion?.pairingMode
        }
        return nil
    }

    /// Whether the input must be treated as interleaved pairs.
    ///
    /// - Parameters:
    ///   - inputURL: the FASTQ the operation will read.
    ///   - explicit: a pairing the caller already knows. `true` and `false`
    ///     are final; `nil` consults bundle metadata, then read names.
    public static func isInterleaved(inputURL: URL, explicit: Bool? = nil) async throws -> Bool {
        if let explicit {
            return explicit
        }
        if let recorded = bundlePairingMode(for: inputURL) {
            // `.pairedEnd` means separate R1/R2 files, which a single input
            // path cannot be, so only `.interleaved` turns pair handling on.
            return recorded == .interleaved
        }
        return try await IlluminaAmpliconPairMerger.fastqIsInterleavedPairs(
            at: inputURL,
            acceptingIdenticalNames: true
        )
    }
}
