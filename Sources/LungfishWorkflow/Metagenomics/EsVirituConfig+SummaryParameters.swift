// EsVirituConfig+SummaryParameters.swift - Analysis manifest summary parameters
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

extension EsVirituConfig {

    /// Returns key parameters suitable for storage in an analysis manifest entry.
    ///
    /// Includes runtime-relevant parameters only. Paths (inputFiles, outputDirectory,
    /// databasePath) are omitted because they are host-specific and not useful for
    /// reproducibility summaries.
    public func summaryParameters() -> [String: AnalysisParameterValue] {
        [
            "sampleName": .string(sampleName),
            "qualityFilter": .bool(qualityFilter),
            "minReadLength": .int(minReadLength),
            "threads": .int(threads),
            "isPairedEnd": .bool(isPairedEnd),
        ]
    }
}
