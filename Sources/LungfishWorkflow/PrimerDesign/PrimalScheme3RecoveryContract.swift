import Foundation

enum PrimalScheme3RecoveryContract {
    private static func object(_ url: URL, _ label: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path),
              let value = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw PrimalScheme3DesignError.invalidRequest("Native recovery \(label) is missing or malformed.")
        }
        return value
    }
    static func validate(at output: URL, options: PrimalScheme3DesignOptions, configuration: [String: Any]) throws {
        if options.legacySalvageOptions.mode == .bounded {
            let report = try object(output.appendingPathComponent("legacy-salvage.json"), "legacy salvage report")
            let validation = try object(output.appendingPathComponent("legacy-salvage-validation.json"), "legacy salvage validation")
            guard report["schemaVersion"] as? String == "primalscheme3.legacy-dimer-salvage/v1",
                  validation["schemaVersion"] as? String == "primalscheme3.legacy-dimer-salvage-validation/v1",
                  validation["valid"] as? Bool == true else { throw PrimalScheme3DesignError.invalidRequest("Native legacy salvage validation did not pass.") }
            guard let actual = configuration["legacy_salvage"] as? [String: Any],
                  actual["mode"] as? String == "bounded",
                  actual["floor"] as? Double == options.legacySalvageOptions.floor,
                  actual["max_edges_per_pool"] as? Int == options.legacySalvageOptions.maxEdgesPerPool,
                  actual["max_incident_species_per_pool"] as? Int == options.legacySalvageOptions.maxIncidentSpeciesPerPool,
                  actual["min_reference_gain"] as? Int == options.legacySalvageOptions.minReferenceGain,
                  actual["max_candidate_evaluations"] as? Int == options.legacySalvageOptions.maxCandidateEvaluations,
                  (actual["thresholds"] as? [Double]) == options.legacySalvageOptions.thresholds else {
                throw PrimalScheme3DesignError.invalidRequest("Native configuration omitted or changed resolved legacy salvage options.")
            }
        }
        if options.gapCompletionParent != nil {
            let report = try object(output.appendingPathComponent("gap-completion.json"), "gap-completion report")
            let coverage = try object(output.appendingPathComponent("gap-completion-coverage.json"), "gap-completion coverage")
            guard report["schemaVersion"] as? String == "primalscheme3.gap-completion/v1",
                  coverage["schemaVersion"] as? String == "primalscheme3.gap-completion-coverage/v1" else {
                throw PrimalScheme3DesignError.invalidRequest("Native gap-completion reports have unsupported schemas.")
            }
            let followup = report["followup"] as? [String: Any]
            guard followup?["poolCount"] as? Int == options.poolCount,
                  configuration["gap_completion_report"] as? String == "gap-completion.json",
                  configuration["gap_completion_coverage"] as? String == "gap-completion-coverage.json" else {
                throw PrimalScheme3DesignError.invalidRequest("Native gap-completion configuration does not match the requested follow-up pool.")
            }
            guard let fresh = coverage["freshValidation"] as? [String: Any], fresh["status"] as? String == "passed",
                  let drift = coverage["sourceDrift"] as? [String: Any],
                  drift["parentChangedDuringRun"] as? Bool == false, drift["inputsChangedDuringRun"] as? Bool == false else {
                throw PrimalScheme3DesignError.invalidRequest("Native gap-completion fresh validation or source-drift evidence is missing or failed.")
            }
            guard configuration["gap_expansion_mode"] as? String == options.gapExpansionOptions.mode.rawValue,
                  configuration["gap_expansion_max_anchors_per_msa"] as? Int == options.gapExpansionOptions.maxAnchorsPerMSA,
                  configuration["gap_expansion_max_pairs_per_msa"] as? Int == options.gapExpansionOptions.maxPairsPerMSA else {
                throw PrimalScheme3DesignError.invalidRequest("Native gap-expansion configuration does not match requested budgets.")
            }
        }
    }
}
