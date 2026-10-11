// MappingProvenance+ReadSetPlan.swift - The run parameters of a mapping record, beside the read set plan it keeps apart
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension MappingProvenance {
    func canonicalParameters() -> [String: ParameterValue] {
        [
            "mapper": .string(mapper.rawValue),
            "modeID": .string(modeID),
            "sampleName": .string(sampleName),
            "pairedEnd": .boolean(pairedEnd),
            "threads": .integer(threads),
            "minimumMappingQuality": .integer(minimumMappingQuality),
            "includeSecondary": .boolean(includeSecondary),
            "includeSupplementary": .boolean(includeSupplementary),
            "advancedArguments": .array(advancedArguments.map(ParameterValue.string)),
            "readClassHints": .array(readClassHints.map(ParameterValue.string)),
            "mapperRuntime": .string(runtimeIdentity["mapper"] ?? ""),
            "samtoolsRuntime": .string(runtimeIdentity["samtools"] ?? "")
        ]
    }
}
