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
            "readGroupID": .string(readGroup.id),
            "readGroupSampleName": .string(readGroup.sampleName),
            "readGroupLibrary": .string(readGroup.library),
            "readGroupPlatform": .string(readGroup.platform),
            "readGroupPlatformUnit": .string(readGroup.platformUnit),
            "threads": .int(threads),
            "isPairedEnd": .bool(pairedEnd),
            "includeSecondary": .bool(includeSecondary),
            "includeSupplementary": .bool(includeSupplementary),
            "minimumMappingQuality": .int(minimumMappingQuality),
            "advancedOptions": .string(AdvancedCommandLineOptions.join(advancedArguments)),
        ]
        return parameters
    }
}
