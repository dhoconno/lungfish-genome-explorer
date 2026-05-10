// MappingRunRequest+SummaryParameters.swift - Analysis manifest summary parameters
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

public extension MappingRunRequest {
    func summaryParameters() -> [String: AnalysisParameterValue] {
        let readGroup = self.resolvedReadGroup()
        let parameters: [String: AnalysisParameterValue] = [
            "tool": .string(tool.rawValue),
            "mode": .string(modeID),
            "sampleName": .string(sampleName),
            "readGroup.id": .string(readGroup.id),
            "readGroup.sm": .string(readGroup.sampleName),
            "readGroup.lb": .string(readGroup.library),
            "readGroup.pl": .string(readGroup.platform),
            "readGroup.pu": .string(readGroup.platformUnit),
            "threads": .int(threads),
            "isPairedEnd": .bool(pairedEnd),
            "includeSecondary": .bool(includeSecondary),
            "includeSupplementary": .bool(includeSupplementary),
            "minimumMappingQuality": .int(minimumMappingQuality),
            "extraArgs": .string(AdvancedCommandLineOptions.join(advancedArguments)),
        ]
        return parameters
    }
}
