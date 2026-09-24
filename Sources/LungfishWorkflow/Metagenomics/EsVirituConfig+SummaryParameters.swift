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
            // WFL-10: "minReadLength" intentionally omitted. EsViritu has no
            // minimum-read-length option in its own CLI (verified against
            // upstream cmmr/EsViritu's argparse definitions) and its fastp
            // invocation is not parameterized with one either, so this value
            // was never applied -- recording it in the reproducibility
            // summary would contradict the actual computation.
            "threads": .int(threads),
            "isPairedEnd": .bool(isPairedEnd),
            "extraArgs": .string(AdvancedCommandLineOptions.join(extraArguments)),
        ]
    }
}
