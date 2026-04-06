// TaxTriageConfig+SummaryParameters.swift - Analysis manifest summary parameters
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

extension TaxTriageConfig {

    /// Returns key parameters suitable for storage in an analysis manifest entry.
    ///
    /// Includes runtime-relevant parameters only. Paths (outputDirectory,
    /// kraken2DatabasePath, sourceBundleURLs, and per-sample FASTQ paths) are omitted.
    public func summaryParameters() -> [String: AnalysisParameterValue] {
        [
            "platform": .string(platform.rawValue),
            "classifiers": .string(classifiers.joined(separator: ",")),
            "topHitsCount": .int(topHitsCount),
            "k2Confidence": .double(k2Confidence),
            "rank": .string(rank),
            "skipAssembly": .bool(skipAssembly),
            "maxCpus": .int(maxCpus),
        ]
    }
}
