// EsVirituPipeline+RunFacts.swift - The facts of an EsViritu run that no user chose
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension EsVirituPipeline {
    /// The facts of a run that its record files among the resolved defaults, never among the explicit options (Phase
    /// 2.13 lane 13.15, SW26 note 1, `BIO-13.15-SW26` item 1). They are the paired-end flag the resolved read format
    /// gives, the build's EsViritu release (as 2.7 E12 files a release a pin chose), the read format the run was asked
    /// for when the run changed it, and the layout scan of the input when the classifier made one.
    ///
    /// The run begins with them among its parameters, so a record with no step still names the release
    /// (`ProvenanceRunBuilder+Recorded.swift`). The save also files them among the resolved defaults
    /// (``resolvedRunOptions(for:adding:)``), and the recorder's merge then leaves each one out of the explicit
    /// options, since a resolved default holds the same value (the merge of run parameters in
    /// `ProvenanceEnvelope+Copy.swift`). A saved record's legacy view lists only its explicit options
    /// (`ProvenanceEnvelope.legacyWorkflowRun()`), so it no longer lists them.
    static func runFacts(
        for config: EsVirituConfig,
        requestedReadFormat: EsVirituReadFormat
    ) -> [String: ParameterValue] {
        var facts: [String: ParameterValue] = [
            "pairedEnd": .boolean(config.isPairedEnd),
            "github_release_version": .string(esVirituGithubReleaseVersion),
        ]
        if requestedReadFormat != config.readFormat {
            facts["requestedReadFormat"] = .string(requestedReadFormat.rawValue)
        }
        if let layout = config.inputLayout {
            facts["inputReadLayout"] = .string(layout.layout.rawValue)
            facts["inputReadLayoutScannedRecords"] = .integer(layout.scannedRecords)
            facts["inputReadLayoutMatePairs"] = .integer(layout.matePairs)
            facts["inputReadLayoutUnpairedRecords"] = .integer(layout.unpairedRecords)
            facts["inputReadLayoutReason"] = .string(layout.reason)
        }
        return facts
    }

    /// The options a save of the run passes, ``resolvedRunOptions(for:)`` with `runFacts` among the resolved defaults.
    static func resolvedRunOptions(
        for config: EsVirituConfig,
        adding runFacts: [String: ParameterValue]
    ) -> ProvenanceOptions {
        let options = resolvedRunOptions(for: config)
        return ProvenanceOptions(resolvedDefaults: options.resolvedDefaults.merging(runFacts) { current, _ in current })
    }
}
