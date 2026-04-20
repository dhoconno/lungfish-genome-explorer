// MappingRunRequest+SummaryParameters.swift - Analysis manifest summary parameters
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

public extension MappingRunRequest {
    func summaryParameters() -> [String: AnalysisParameterValue] {
        [
            "tool": .string(tool.rawValue),
            "mode": .string(modeID),
            "sampleName": .string(sampleName),
            "threads": .int(threads),
            "isPairedEnd": .bool(pairedEnd),
            "includeSecondary": .bool(includeSecondary),
            "includeSupplementary": .bool(includeSupplementary),
            "minimumMappingQuality": .int(minimumMappingQuality),
        ]
    }
}
