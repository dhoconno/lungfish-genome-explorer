// MappingProvenance+ReadSetPlan.swift - The run parameters of a mapping record, beside the read set plan it keeps apart
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension MappingProvenance {
    /// The run parameters of the record, which the canonical envelope holds as its explicit options
    /// and as the parameters of the run nested in it. The read set plan is not one of them. The
    /// record keeps the plan once, in ``readSetPlan``, and ``canonicalEnvelope(sourceDirectory:)``
    /// writes it to the resolved defaults, its one home (E13). A copy here would be found a second
    /// time, at the nested run's parameters.
    func canonicalParameters() -> [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
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
        if let limit = AnalysisTimeLimit.current {
            parameters[AnalysisTimeLimit.recordKey] = .integer(limit.minutes)
        }
        return parameters
    }
}
