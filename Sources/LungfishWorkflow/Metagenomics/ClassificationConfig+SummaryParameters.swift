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
        var parameters: [String: AnalysisParameterValue] = [
            "goal": .string(goal.rawValue),
            "databaseName": .string(databaseName),
            "confidence": .double(confidence),
            "minimumHitGroups": .int(minimumHitGroups),
            "threads": .int(threads),
            "memoryMapping": .bool(memoryMapping),
            "extraArgs": .string(AdvancedCommandLineOptions.join(extraArguments)),
        ]

        if let databaseCatalogID {
            parameters["databaseCatalogID"] = .string(databaseCatalogID)
        }
        if let databaseInstallationRecipe {
            parameters["databaseInstallationRecipe"] = .string(
                databaseInstallationRecipe.provenanceValue
            )
        }
        if goal == .profile {
            let request = brackenProfileRequest ?? .automaticDefault
            parameters["brackenRankRequest"] = .string(request.rank.provenanceValue)
            parameters["brackenReadLength"] = .int(request.readLength)
            parameters["brackenThreshold"] = .int(request.threshold)
        }

        return parameters
    }
}
