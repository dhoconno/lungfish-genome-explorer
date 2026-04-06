// ClassificationConfig+SummaryParameters.swift - Analysis manifest summary parameters
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

extension ClassificationConfig {

    /// Returns key parameters suitable for storage in an analysis manifest entry.
    ///
    /// Includes runtime-relevant parameters only. Paths (inputFiles, outputDirectory,
    /// databasePath) and transient fields (databaseVersion, originalInputFiles,
    /// sampleDisplayName) are omitted.
    public func summaryParameters() -> [String: AnalysisParameterValue] {
        [
            "goal": .string(goal.rawValue),
            "databaseName": .string(databaseName),
            "confidence": .double(confidence),
            "minimumHitGroups": .int(minimumHitGroups),
            "threads": .int(threads),
            "memoryMapping": .bool(memoryMapping),
        ]
    }
}
