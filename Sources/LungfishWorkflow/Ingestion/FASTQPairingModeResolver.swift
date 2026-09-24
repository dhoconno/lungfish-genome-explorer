// FASTQPairingModeResolver.swift - Decides whether a FASTQ operation may pair records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// What a FASTQ operation does with the records of its single input, and why.
///
/// `pairAware` is the switch the operation flips (`interleaved=t`, a
/// positional R1/R2 split, a by-name re-extraction). It is on only when the
/// resolved layout is one the operation can pair without mis-pairing:
/// strictly interleaved input always, mixed input only when the operation
/// pairs by name. Everything else runs as single reads (owner contract,
/// `FASTQInputLayout.swift`).
public struct FASTQPairingDecision: Sendable, Equatable {
    /// Whether the operation runs in its pair-aware mode.
    public let pairAware: Bool
    /// The resolved layout and the evidence behind it, for provenance.
    public let resolution: FASTQInputLayoutResolution
    /// Set when the caller asked for pairs and the input cannot be paired
    /// safely, so the operation can say why it fell back to single reads.
    public let warning: String?

    public init(pairAware: Bool, resolution: FASTQInputLayoutResolution, warning: String? = nil) {
        self.pairAware = pairAware
        self.resolution = resolution
        self.warning = warning
    }

    public var layout: FASTQInputLayout { resolution.layout }
}

/// Resolves whether a FASTQ operation may treat its input as interleaved pairs.
///
/// Paired imports are stored as one interleaved file inside a
/// `.lungfishfastq` bundle whose metadata records `pairingMode`. Some of
/// those bundles are MIXED: merged single reads and unmerged pairs in one
/// file (VSP2, Illumina amplicon merge). A tool told `interleaved=t` pairs
/// such a file by position and mis-pairs it. So every answer here goes
/// through ``FASTQInputLayoutResolver``, which reads the bundle metadata and
/// then scans the records:
///
/// 1. an explicit `single` from the caller is final and reads nothing,
/// 2. an explicit `interleaved` is a request that is still checked against
///    the records: the GUI passes it from the bundle's `pairingMode`, and a
///    VSP2 bundle records `interleaved` while holding merged reads,
/// 3. `auto` resolves the layout from metadata and records alike.
///
/// Mates named identically, with `/1` `/2` suffixes, or with Casava
/// descriptions are all recognised by the scan.
public enum FASTQPairingModeResolver {
    /// Pairing recorded by the bundle that holds `inputURL`, if any.
    ///
    /// Accepts a FASTQ file inside a bundle, the bundle directory itself, or
    /// a loose FASTQ with a sidecar next to it. Returns `nil` when no
    /// metadata exists. This is a hint for command display (`--pairing`);
    /// the operation itself decides through ``resolvePairing(inputURL:explicit:pairsByName:metadataFrom:recordLimit:)``.
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

    /// Decides whether an operation may run pair-aware on `inputURL`.
    ///
    /// - Parameters:
    ///   - inputURL: the FASTQ the operation will read.
    ///   - explicit: the caller's `--pairing`: `false` is final (single
    ///     reads, nothing is read), `true` asks for pairs and is verified
    ///     against the records, `nil` resolves from metadata and records.
    ///   - pairsByName: whether the operation pairs records by fragment name
    ///     (a `seqkit grep` re-extraction, a by-name split). Such an operation
    ///     may run pair-aware on mixed input, because merged reads simply stay
    ///     single. A positional tool must pass `false`.
    ///   - hintURL: the bundle (or the file inside it) whose metadata describes
    ///     `inputURL` when the input is a materialized scratch copy.
    public static func resolvePairing(
        inputURL: URL,
        explicit: Bool? = nil,
        pairsByName: Bool = false,
        metadataFrom hintURL: URL? = nil,
        recordLimit: Int = FASTQReadLayoutClassifier.defaultRecordLimit
    ) -> FASTQPairingDecision {
        if explicit == false {
            return FASTQPairingDecision(
                pairAware: false,
                resolution: FASTQInputLayoutResolution(
                    layout: .singleEnd,
                    source: .explicit,
                    reason: "The caller asked for every record to be treated as a single read."
                )
            )
        }
        let resolution = FASTQInputLayoutResolver.resolve(
            fastqURL: inputURL,
            metadataFrom: hintURL,
            recordLimit: recordLimit
        )
        switch resolution.layout {
        case .strictlyInterleaved:
            return FASTQPairingDecision(pairAware: true, resolution: resolution)
        case .mixedMergedAndPairs:
            if pairsByName {
                return FASTQPairingDecision(pairAware: true, resolution: resolution)
            }
            return FASTQPairingDecision(
                pairAware: false,
                resolution: resolution,
                warning: "\(inputURL.lastPathComponent) holds merged reads and pairs (\(resolution.reason)) "
                    + "Every record is treated as a single read so that mates are not paired by position."
            )
        case .singleEnd, .pairedFiles:
            let warning = explicit == true
                ? "\(inputURL.lastPathComponent) was declared interleaved, but \(resolution.reason) "
                    + "Every record is treated as a single read."
                : nil
            return FASTQPairingDecision(pairAware: false, resolution: resolution, warning: warning)
        }
    }
}
