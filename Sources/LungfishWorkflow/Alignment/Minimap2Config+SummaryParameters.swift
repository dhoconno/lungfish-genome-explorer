// Minimap2Config+SummaryParameters.swift - Analysis manifest summary parameters
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

extension Minimap2Config {

    /// Returns key parameters suitable for storage in an analysis manifest entry.
    ///
    /// Includes runtime-relevant parameters only. Paths (inputFiles, referenceURL,
    /// outputDirectory) are omitted.
    public func summaryParameters() -> [String: AnalysisParameterValue] {
        [
            "preset": .string(preset.rawValue),
            "sampleName": .string(sampleName),
            "threads": .int(threads),
            "isPairedEnd": .bool(isPairedEnd),
            "advancedOptions": .string(AdvancedCommandLineOptions.join(advancedArguments)),
        ]
    }
}
