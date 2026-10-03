// PlatformInference+Defaults.swift - Read-length evidence for reads whose platform is unknown
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension PlatformInference {

    /// The note shown wherever a default was chosen without a known platform.
    public static let untunedDefaultsNote =
        "The sequencing platform is not known, so these defaults are not tuned to a platform. Settings you choose are used as given."

    /// The read-length shape of a FASTQ file: the cached statistics in its
    /// sidecar when they exist, otherwise a bounded sample of its reads.
    ///
    /// The cached statistics hold no per-read spread, so that path uses the
    /// longest read only (over 1,000 bases long, up to 600 short). The sampled
    /// path in ``PlatformInference/lengthProfile(of:)`` also calls a sample
    /// long when its mean is over 500 with a coefficient of variation over 0.3.
    ///
    /// Unknown-platform reads take long-read defaults for a long profile and
    /// short-read defaults for a short one. The platform only chooses defaults
    /// and never blocks a run.
    public static func lengthProfile(
        forFASTQ url: URL,
        metadata: PersistedFASTQMetadata? = nil
    ) -> LengthProfile? {
        let metadata = metadata ?? FASTQMetadataStore.load(for: url)
        if let statistics = metadata?.computedStatistics, statistics.maxReadLength > 0 {
            if statistics.maxReadLength > 1_000 { return .long }
            if statistics.maxReadLength <= 600 { return .short }
            return .intermediate
        }
        if let maxLength = metadata?.seqkitStats?.maxLen, maxLength > 0 {
            if maxLength > 1_000 { return .long }
            if maxLength <= 600 { return .short }
            return .intermediate
        }
        return infer(fromFASTQ: url).lengthProfile
    }

    /// The read type that reads of an unknown platform default to: ONT reads
    /// for a long profile, short reads for a short one, nil otherwise.
    public static func defaultReadType(forLengthProfile profile: LengthProfile?) -> FASTQAssemblyReadType? {
        switch profile {
        case .long?: return .ontReads
        case .short?: return .illuminaShortReads
        case .intermediate?, nil: return nil
        }
    }
}
