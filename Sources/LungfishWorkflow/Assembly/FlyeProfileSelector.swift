// FlyeProfileSelector.swift - Chooses the Flye read profile from measured read quality
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The Flye profile chosen for an input, together with the measurement that
/// justified it. Shared by the assembly sheet (caption under the Profile
/// picker), the CLI (`--profile` default) and provenance (`profile_basis`).
public struct FlyeProfileSelection: Sendable, Equatable, Codable {
    /// Where the read-quality figure came from.
    public enum Basis: String, Sendable, Codable {
        /// The bundle's persisted statistics (quality histogram or seqkit mean).
        case bundleStatistics
        /// The first reads of the FASTQ, measured on demand.
        case sampledReads
        /// No quality could be measured, so the catalog default applies.
        case unavailable
    }

    public let profileID: String
    /// Read quality in Phred units, averaged in error-probability space.
    public let readQuality: Double?
    public let basis: Basis
    /// Number of reads measured when `basis` is `.sampledReads`.
    public let sampledReadCount: Int?

    public init(profileID: String, readQuality: Double?, basis: Basis, sampledReadCount: Int? = nil) {
        self.profileID = profileID
        self.readQuality = readQuality
        self.basis = basis
        self.sampledReadCount = sampledReadCount
    }

    public var profileTitle: String {
        FlyeProfileSelector.profileTitle(for: profileID)
    }

    /// Rounded Phred figure for captions, such as "Q8".
    public var readQualityLabel: String? {
        readQuality.map { "Q\(Int($0.rounded()))" }
    }

    /// Short sentence for the caption under the sheet's Profile picker.
    public var caption: String {
        "\(profileTitle) preselected: \(measurementDescription)."
    }

    /// One-line basis recorded in provenance for the profile that actually ran.
    /// When the user overrode the preselection, both profiles are recorded.
    public func provenanceBasis(appliedProfileID: String?) -> String {
        let applied = appliedProfileID ?? profileID
        if applied == profileID {
            return "\(profileID) preselected from \(measurementDescription)"
        }
        return "\(applied) chosen by the user; \(profileID) was preselected from \(measurementDescription)"
    }

    private var measurementDescription: String {
        switch basis {
        case .bundleStatistics:
            return "read quality \(readQualityLabel ?? "unknown") from the bundle's statistics"
        case .sampledReads:
            let count = sampledReadCount.map { "\($0)" } ?? "the first"
            return "median read quality \(readQualityLabel ?? "unknown") from the first \(count) reads"
        case .unavailable:
            return "read quality could not be measured"
        }
    }
}

/// Picks `nano-raw` or `nano-hq` for Flye from the input's read quality.
///
/// Quality is averaged in error-probability space, the convention seqkit,
/// NanoPlot and ONT's own reports use for "mean read quality". Older or
/// fast-mode basecalls sit well under Q10 by that measure and belong to Flye's
/// `--nano-raw` mode. Recent high-accuracy basecalls sit above it and belong
/// to `--nano-hq`. Arithmetic means of Phred values are not comparable and
/// are never used here.
public enum FlyeProfileSelector {
    /// Inputs whose read quality is below this Phred value are preselected as Nano Raw.
    public static let rawQualityThreshold: Double = 10
    /// Reads measured when the bundle carries no usable statistics.
    public static let sampleReadLimit = 500
    /// The catalog default when nothing can be measured.
    public static let fallbackProfileID = "nano-hq"

    public static let nanoRawProfileID = "nano-raw"
    public static let nanoHQProfileID = "nano-hq"

    // MARK: - Pure selection

    /// The profile for a measured read quality.
    public static func profileID(forReadQuality readQuality: Double) -> String {
        readQuality < rawQualityThreshold ? nanoRawProfileID : nanoHQProfileID
    }

    /// Builds a selection from an optional measurement and its basis.
    public static func selection(
        readQuality: Double?,
        basis: FlyeProfileSelection.Basis,
        sampledReadCount: Int? = nil
    ) -> FlyeProfileSelection {
        guard let readQuality, readQuality.isFinite else {
            return FlyeProfileSelection(profileID: fallbackProfileID, readQuality: nil, basis: .unavailable)
        }
        return FlyeProfileSelection(
            profileID: profileID(forReadQuality: readQuality),
            readQuality: readQuality,
            basis: basis,
            sampledReadCount: sampledReadCount
        )
    }

    public static func profileTitle(for profileID: String) -> String {
        switch profileID {
        case nanoRawProfileID: return "Nano Raw"
        case nanoHQProfileID: return "Nano HQ"
        case "nano-corr": return "Nano Corrected"
        default: return profileID
        }
    }

    // MARK: - Measurements

    /// Phred quality whose error probability is the mean error probability of
    /// every base in the histogram.
    public static func readQuality(fromQualityHistogram histogram: [UInt8: Int]) -> Double? {
        var total = 0
        var errorSum = 0.0
        for (quality, count) in histogram where count > 0 {
            total += count
            errorSum += Double(count) * pow(10, -Double(quality) / 10)
        }
        guard total > 0 else { return nil }
        return phred(fromMeanErrorProbability: errorSum / Double(total))
    }

    /// Read quality from persisted dataset statistics. The sampled histogram
    /// is preferred; the seqkit mean (already in error-probability space) is
    /// the fallback for bundles whose histogram was never collected.
    public static func readQuality(fromStatistics statistics: FASTQDatasetStatistics) -> Double? {
        if let fromHistogram = readQuality(fromQualityHistogram: statistics.qualityScoreHistogram) {
            return fromHistogram
        }
        if statistics.meanQuality > 0 {
            return statistics.meanQuality
        }
        return nil
    }

    /// Read quality from a bundle's metadata sidecar, when it holds one.
    public static func readQuality(fromMetadata metadata: PersistedFASTQMetadata) -> Double? {
        if let statistics = metadata.computedStatistics,
           let quality = readQuality(fromStatistics: statistics) {
            return quality
        }
        if let seqkit = metadata.seqkitStats, seqkit.averageQuality > 0 {
            return seqkit.averageQuality
        }
        return nil
    }

    /// One read's quality: its mean base error probability, back in Phred units.
    public static func readQuality(of quality: QualityScore) -> Double? {
        guard quality.count > 0 else { return nil }
        let values = quality.qualitiesIn(0..<quality.count)
        let errorSum = values.reduce(0.0) { $0 + pow(10, -Double($1) / 10) }
        return phred(fromMeanErrorProbability: errorSum / Double(values.count))
    }

    /// Median per-read quality over the first `readLimit` reads of a FASTQ
    /// (plain or gzipped). Runs wherever it is awaited, never on the main actor.
    public static func sampledReadQuality(
        from fastqURL: URL,
        readLimit: Int = sampleReadLimit
    ) async throws -> (readQuality: Double, readCount: Int)? {
        guard readLimit > 0 else { return nil }
        var qualities: [Double] = []
        qualities.reserveCapacity(readLimit)
        let reader = FASTQReader(validateSequence: false)
        for try await record in reader.records(from: fastqURL) {
            if let quality = readQuality(of: record.quality) {
                qualities.append(quality)
            }
            if qualities.count >= readLimit { break }
        }
        guard !qualities.isEmpty else { return nil }
        let sorted = qualities.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
        return (median, sorted.count)
    }

    // MARK: - Input resolution

    /// Selects the profile for an app or CLI assembly input: a raw FASTQ, a
    /// `.lungfishfastq` bundle, or a file inside one. Uses the bundle's
    /// persisted statistics when present and samples the first reads
    /// otherwise. Never throws: an unreadable input yields the catalog default.
    public static func select(forInputURL inputURL: URL) async -> FlyeProfileSelection {
        guard let fastqURL = AssemblyReadType.resolveFASTQURL(forInputURL: inputURL) else {
            return selection(readQuality: nil, basis: .unavailable)
        }

        if let metadata = FASTQMetadataStore.load(for: fastqURL),
           let quality = readQuality(fromMetadata: metadata) {
            return selection(readQuality: quality, basis: .bundleStatistics)
        }

        if let sampled = try? await sampledReadQuality(from: fastqURL) {
            return selection(
                readQuality: sampled.readQuality,
                basis: .sampledReads,
                sampledReadCount: sampled.readCount
            )
        }

        return selection(readQuality: nil, basis: .unavailable)
    }

    private static func phred(fromMeanErrorProbability probability: Double) -> Double {
        guard probability > 0 else { return 93 }
        return -10 * log10(probability)
    }
}
