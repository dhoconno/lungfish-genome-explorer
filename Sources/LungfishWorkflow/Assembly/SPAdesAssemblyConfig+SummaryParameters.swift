// SPAdesAssemblyConfig+SummaryParameters.swift - Analysis manifest summary parameters
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

extension SPAdesAssemblyConfig {

    /// Returns key parameters suitable for storage in an analysis manifest entry.
    ///
    /// Includes runtime-relevant parameters only. Paths (forwardReads, reverseReads,
    /// unpairedReads, outputDirectory) and raw customArgs are omitted.
    public func summaryParameters() -> [String: AnalysisParameterValue] {
        [
            "mode": .string(mode.rawValue),
            "threads": .int(threads),
            "memoryGB": .int(memoryGB),
            "minContigLength": .int(minContigLength),
            "careful": .bool(careful),
            "advancedOptions": .string(AdvancedCommandLineOptions.join(customArgs)),
        ]
    }
}
