import CoreFoundation
import CryptoKit
import Foundation
import LungfishIO

struct PrimalScheme3AlleleCapabilities: @unchecked Sendable {
    let source: [String: Any]
    let runtime: [String: Any]
    let phaseSchedulingPolicies: [String: [String: Any]]?
    let intendedProductPolicies: [String: [String: Any]]?
    let secondaryProductPolicies: [String: [String: Any]]?
}

enum PrimalScheme3AlleleContract {
    static let algorithm = "bounded-allele-coverage/v1"
    static let metric = "observed-allele-primer-trimmed/v1"
    static let catalogSchema = "primalscheme3.variant-catalog/v2"
    static let ledgerSchema = "primalscheme3.configuration-ledger/v2"
    static let validationSchema = "primalscheme3.allele-panel-validation/v2"
    static let optimizerSchema = "primalscheme3.panel-optimizer/v2"
    static let integrationSchema = "primalscheme3.panel-native-integration/v2"

    static func validateCapabilities(_ data: Data,
                                     requestedPhaseScheduling: PrimalScheme3PhaseScheduling? = nil,
                                     requestedIntendedProductPolicy: PrimalScheme3IntendedProductPolicy? = nil,
                                     requestedSecondaryProductPolicy: PrimalScheme3SecondaryProductPolicy? = nil) throws
        -> PrimalScheme3AlleleCapabilities {
        let root = try object(JSONSerialization.jsonObject(with: data), "capabilities")
        try expect(string(root, "schemaVersion"), "primalscheme3.capabilities/v1", "capabilities schema")
        try expect(string(root, "tool"), "primalscheme3", "capability tool")
        try expect(string(root, "toolVersion"), PrimalScheme3DesignPipeline.alleleToolVersion, "capabilities version")
        guard try strings(root, "selectionAlgorithms").contains("allele-coverage") else {
            throw invalid("The executable does not advertise allele-coverage selection.")
        }
        let allele = try object(root["alleleCoverage"], "alleleCoverage capability")
        try expect(string(allele, "sourceContractVersion"), PrimalScheme3DesignPipeline.alleleToolVersion, "source contract")
        try expect(string(allele, "algorithm"), algorithm, "algorithm")
        try expect(string(allele, "metric"), metric, "metric")
        try expect(string(allele, "preset"), PrimalScheme3AlleleOptions.presetName, "preset")
        try expect(string(allele, "catalogSchemaVersion"), catalogSchema, "catalog schema")
        try expect(string(allele, "configurationLedgerSchemaVersion"), ledgerSchema, "ledger schema")
        try expect(string(allele, "validationSchemaVersion"), validationSchema, "validation schema")
        let profile = try object(allele["profile"], "capability profile")
        try expect(string(profile, "name"), "allele-panel-v1", "profile name")
        try expect(string(profile, "specificityRevision"), "selected-sites-v2", "specificity revision")
        let scope = try object(allele["supportedScope"], "supported scope")
        try expect(string(scope, "mode"), "equal", "mode")
        try expect(string(scope, "mapping"), "first", "mapping")
        try expect(string(scope, "ampliconSizeMetric"), "reference-span", "amplicon metric")
        guard try bool(scope, "freshDesign"), try bool(scope, "linear"),
              try bool(scope, "suppliedMsaSpecificity"),
              try strings(scope, "terminalGapPolicies") == ["observed-only"] else {
            throw invalid("The executable's allele-coverage scope is unsupported.")
        }
        let phaseSchedulingPolicies: [String: [String: Any]]?
        if let advertised = allele["phaseScheduling"] {
            let serial = schedulingPolicy(.serial)
            let reserved = schedulingPolicy(.reserved)
            let expected: [String: Any] = [
                "default": "serial", "policies": ["serial": serial, "reserved": reserved]
            ]
            guard equalJSON(advertised, expected) else {
                throw invalid("The executable advertises an unsupported phase-scheduling contract.")
            }
            phaseSchedulingPolicies = ["serial": serial, "reserved": reserved]
        } else {
            phaseSchedulingPolicies = nil
        }
        if requestedPhaseScheduling != nil, phaseSchedulingPolicies == nil {
            throw invalid("The executable does not advertise the explicitly requested phase-scheduling policy.")
        }
        let intendedProductPolicies: [String: [String: Any]]?
        if let advertised = allele["intendedProductPolicies"] {
            let exact = intendedProductPolicy(.exactSupported)
            let concrete = intendedProductPolicy(.concreteDesignatedSites)
            let expected: [String: Any] = [
                "default": "exact-supported",
                "policies": ["exact-supported": exact, "concrete-designated-sites": concrete]
            ]
            guard equalJSON(advertised, expected) else {
                throw invalid("The executable advertises an unsupported intended-product contract.")
            }
            intendedProductPolicies = ["exact-supported": exact, "concrete-designated-sites": concrete]
        } else {
            intendedProductPolicies = nil
        }
        if requestedIntendedProductPolicy != nil, intendedProductPolicies == nil {
            throw invalid("The executable does not advertise the explicitly requested intended-product policy.")
        }
        let secondaryProductPolicies: [String: [String: Any]]?
        if let advertised = allele["secondaryProductPolicies"] {
            let intended = secondaryProductPolicy(.orderedDisjointIntendedSites)
            let reject = secondaryProductPolicy(.rejectSecondaryProducts)
            let concrete = secondaryProductPolicy(.orderedDisjointConcreteDesignatedSites)
            let expected: [String: Any] = [
                "default": PrimalScheme3SecondaryProductPolicy.orderedDisjointIntendedSites.rawValue,
                "policies": [
                    PrimalScheme3SecondaryProductPolicy.orderedDisjointIntendedSites.rawValue: intended,
                    PrimalScheme3SecondaryProductPolicy.rejectSecondaryProducts.rawValue: reject,
                    PrimalScheme3SecondaryProductPolicy.orderedDisjointConcreteDesignatedSites.rawValue: concrete,
                ]
            ]
            guard equalJSON(advertised, expected) else {
                throw invalid("The executable advertises an unsupported secondary-product contract.")
            }
            secondaryProductPolicies = [
                PrimalScheme3SecondaryProductPolicy.orderedDisjointIntendedSites.rawValue: intended,
                PrimalScheme3SecondaryProductPolicy.rejectSecondaryProducts.rawValue: reject,
                PrimalScheme3SecondaryProductPolicy.orderedDisjointConcreteDesignatedSites.rawValue: concrete,
            ]
        } else {
            secondaryProductPolicies = nil
        }
        if requestedSecondaryProductPolicy != nil, secondaryProductPolicies == nil {
            throw invalid("The executable does not advertise the explicitly requested secondary-product policy.")
        }
        let source = try object(root["source"], "capability source")
        let runtime = try object(root["runtime"], "capability runtime")
        let sourceFiles = try objectArray(source["files"], "capability source files")
        let build = try object(source["build"], "capability build")
        let dependencies = try objectArray(runtime["declaredRuntimeDependencies"], "runtime dependencies")
        let nativeKernels = try objectArray(runtime["nativeKernels"], "native kernels")
        let kernel = try object(runtime["kernel"], "runtime kernel")
        guard !(try string(source, "root")).isEmpty, isDigest(try string(source, "sourceDigest")),
              !(try string(source, "gitCommit")).isEmpty, !sourceFiles.isEmpty,
              isDigest(try string(build, "sha256")), try integer(build, "size") > 0,
              !(try string(runtime, "pythonExecutable")).isEmpty,
              !(try string(runtime, "pythonExecutableResolved")).isEmpty,
              !(try string(runtime, "pythonVersion")).isEmpty,
              !(try string(runtime, "pythonImplementation")).isEmpty,
              !(try string(runtime, "pythonPrefix")).isEmpty,
              !(try string(runtime, "platform")).isEmpty, !(try string(runtime, "machine")).isEmpty,
              !(try string(kernel, "system")).isEmpty, !dependencies.isEmpty, !nativeKernels.isEmpty,
              sourceFiles.allSatisfy(descriptorIdentityValid),
              dependencies.allSatisfy(dependencyIdentityValid),
              nativeKernels.allSatisfy(nativeKernelIdentityValid) else {
            throw invalid("Capability source or runtime identity is incomplete.")
        }
        return .init(source: source, runtime: runtime, phaseSchedulingPolicies: phaseSchedulingPolicies,
                     intendedProductPolicies: intendedProductPolicies,
                     secondaryProductPolicies: secondaryProductPolicies)
    }

    static func validateNativeOutput(at output: URL, configuration: [String: Any],
                                     capabilities: PrimalScheme3AlleleCapabilities,
                                     options: PrimalScheme3DesignOptions, inputCount: Int,
                                     executedArgv: [String], auditValidation: Data?,
                                     auditProvenance: Data?, auditExecutedArgv: [String]?,
                                     auditExitStatus: Int32?) throws {
        try expect(string(configuration, "version"), PrimalScheme3DesignPipeline.alleleToolVersion, "configuration version")
        try expect(string(configuration, "selection_algorithm"), "allele-coverage", "selection algorithm")
        try expect(string(configuration, "coverage_metric"), "observed-allele-primer-trimmed", "coverage metric")
        try expect(string(configuration, "mode"), "equal", "mode")
        try expect(string(configuration, "mapping"), "first", "mapping")
        try expect(string(configuration, "terminal_gap_policy"), "observed-only", "terminal policy")
        try expect(number(configuration, "coverage_target"), options.coverageTarget, "coverage target")
        try expect(integer(configuration, "n_pools"), options.poolCount, "pool count")
        try expect(integer(configuration, "ncores"), options.coreCount, "core count")
        try expect(integer(configuration, "amplicon_size"), options.ampliconSize, "amplicon size")
        try expect(integer(configuration, "amplicon_size_min"), options.ampliconSizeMinimum, "amplicon minimum")
        try expect(integer(configuration, "amplicon_size_max"), options.ampliconSizeMaximum, "amplicon maximum")

        let integration = try object(configuration["panel_optimizer"], "panel optimizer integration")
        try expect(string(integration, "schemaVersion"), integrationSchema, "integration schema")
        try expect(string(integration, "selectionAlgorithm"), "allele-coverage", "integration selector")
        try expect(string(integration, "toolVersion"), PrimalScheme3DesignPipeline.alleleToolVersion, "integration version")
        try expect(string(integration, "primaryTier"), options.alleleOptions.primaryTier, "primary tier")
        let profile = try object(integration["profile"], "integration profile")
        try expect(string(profile, "name"), "allele-panel-v1", "integration profile")
        try expect(string(profile, "specificity_revision"), "selected-sites-v2", "integration specificity")
        if capabilities.intendedProductPolicies != nil {
            try expect(string(profile, "intended_product_policy"),
                       options.alleleOptions.intendedProductPolicy.rawValue, "integration intended-product policy")
        } else {
            try validateLegacyExactPolicy(profile, label: "integration profile")
        }
        if capabilities.secondaryProductPolicies != nil {
            try expect(string(profile, "secondary_product_policy"),
                       options.alleleOptions.secondaryProductPolicy.rawValue,
                       "integration secondary-product policy")
        } else {
            try validateLegacySecondaryPolicy(profile, label: "integration profile")
        }
        let resolved = try object(integration["options"], "resolved allele options")
        try validateResolved(resolved, options: options,
                             supportsPhaseScheduling: capabilities.phaseSchedulingPolicies != nil,
                             supportsIntendedProducts: capabilities.intendedProductPolicies != nil,
                             supportsSecondaryProducts: capabilities.secondaryProductPolicies != nil)
        guard let encoded = configuration["allele_options_json"] as? String,
              let encodedData = encoded.data(using: .utf8),
              equalJSON(try JSONSerialization.jsonObject(with: encodedData), resolved) else {
            throw invalid("The full native resolved allele configuration is missing or inconsistent.")
        }
        var validationURL: URL?
        for (key, schema) in [("optimizer", optimizerSchema), ("validation", validationSchema),
                              ("provenance", "primalscheme3.panel-provenance/v1")] {
            let descriptor = try object(integration[key], "integration \(key)")
            try expect(string(descriptor, "schemaVersion"), schema, "\(key) schema")
            let url = try contained(output, path: try string(descriptor, "path"), label: key)
            if key == "validation" { validationURL = url }
        }

        let optimizer = try readObject(output.appendingPathComponent("panel-optimizer.json"), "panel optimizer")
        try expect(string(optimizer, "schemaVersion"), optimizerSchema, "optimizer schema")
        try expect(string(optimizer, "algorithm"), algorithm, "optimizer algorithm")
        try expect(string(optimizer, "metric"), metric, "optimizer metric")
        try expect(string(optimizer, "primaryTier"), options.alleleOptions.primaryTier, "optimizer primary tier")
        let optimizerProfile = try object(optimizer["profile"], "optimizer profile")
        if capabilities.intendedProductPolicies != nil {
            try expect(string(optimizerProfile, "intended_product_policy"),
                       options.alleleOptions.intendedProductPolicy.rawValue, "optimizer intended-product policy")
        } else {
            try validateLegacyExactPolicy(optimizerProfile, label: "optimizer profile")
        }
        if capabilities.secondaryProductPolicies != nil {
            try expect(string(optimizerProfile, "secondary_product_policy"),
                       options.alleleOptions.secondaryProductPolicy.rawValue,
                       "optimizer secondary-product policy")
        } else {
            try validateLegacySecondaryPolicy(optimizerProfile, label: "optimizer profile")
        }
        guard let validationURL else { throw invalid("The panel validation artifact is missing.") }
        let panelValidation = try readObject(validationURL, "panel validation")
        if capabilities.intendedProductPolicies != nil {
            try validateIntendedProducts(panelValidation, policy: options.alleleOptions.intendedProductPolicy,
                                         label: "panel validation")
        } else {
            try validateLegacyIntendedProducts(panelValidation, label: "panel validation")
        }
        if capabilities.secondaryProductPolicies != nil {
            try validateSecondaryProducts(panelValidation, policy: options.alleleOptions.secondaryProductPolicy,
                                          label: "panel validation")
        } else {
            try validateLegacySecondaryProducts(panelValidation, label: "panel validation")
        }
        let history = try object(optimizer["history"], "optimizer history")
        _ = try contained(output, path: try string(history, "path"), label: "history")
        let catalogURL = try contained(output, path: "discovery-catalog.json.gz", label: "catalog")
        let ledgerURL = try contained(output, path: try string(history, "configurationLedger"), label: "ledger")
        try validateGzipSchema(catalogURL, expected: catalogSchema)
        try validateGzipSchema(ledgerURL, expected: ledgerSchema)
        let stages = try objectArray(optimizer["stages"], "optimizer stages")
        guard !stages.isEmpty else { throw invalid("The optimizer has no published tier.") }
        var publishedStageIDs = Set<String>()
        let selectedSchedulingPolicy = capabilities.phaseSchedulingPolicies?[options.alleleOptions.phaseScheduling.rawValue]
        for stage in stages {
            let stagePath = try safeRelative(string(stage, "path"))
            guard publishedStageIDs.insert(try string(stage, "stage_id")).inserted else {
                throw invalid("The optimizer publishes duplicate tier identifiers.")
            }
            if let selectedSchedulingPolicy {
                let stageOptimizer = try object(stage["optimizer"], "stage optimizer")
                guard equalJSON(stageOptimizer["scheduling_policy"], selectedSchedulingPolicy) else {
                    throw invalid("The stage optimizer scheduling policy differs from the selected capability descriptor.")
                }
                let objectiveTerms = try strings(stageOptimizer, "objective_terms")
                guard objectiveTerms.count > 1, objectiveTerms.last == "canonical-assignments" else {
                    throw invalid("The stage optimizer objective terms are malformed.")
                }
                let progress = try objectArray(stageOptimizer["phase_progress"], "optimizer phase progress")
                if progress.isEmpty, !validNoAssessableStop(stage: stage, optimizer: stageOptimizer) {
                    throw invalid("The stage optimizer phase progress is empty without no-assessable-target evidence.")
                }
                for entry in progress {
                    let phase = try string(entry, "phase")
                    let outcome = try string(entry, "outcome")
                    let outcomes: Set<String> = ["work-cap", "exhausted", "no-eligible-work", "completed",
                                                 "phase-time-limit", "time-limit", "cancelled", "failed"]
                    guard validPhaseName(phase), outcomes.contains(outcome),
                          try number(entry, "started_seconds") >= 0,
                          try number(entry, "elapsed_seconds") >= 0,
                          try number(entry, "local_overshoot_seconds") >= 0 else {
                        throw invalid("The stage optimizer phase progress is malformed.")
                    }
                    if options.alleleOptions.phaseScheduling == .serial || !isInitiallyReservedPhase(phase) {
                        guard entry["local_budget_seconds"] is NSNull else {
                            throw invalid("An unreserved phase must not claim a local reservation budget.")
                        }
                    } else if try number(entry, "local_budget_seconds") < 0 {
                        throw invalid("The stage optimizer phase budget is malformed.")
                    }
                    let before = try numbers(entry, "objective_before")
                    let after = try numbers(entry, "objective_after")
                    guard before.count == objectiveTerms.count - 1, after.count == before.count,
                          before.allSatisfy(\.isFinite), after.allSatisfy(\.isFinite),
                          try integer(entry, "repairs_accepted_delta") >= 0 else {
                        throw invalid("The stage optimizer phase objective evidence is malformed.")
                    }
                    for key in ["work_delta", "proposal_work_delta", "family_cursors_before", "family_cursors"] {
                        let counters = try object(entry[key], "optimizer phase \(key)")
                        guard counters.values.allSatisfy(nonnegativeInteger) else {
                            throw invalid("The stage optimizer phase \(key) is malformed.")
                        }
                    }
                }
            }
            for required in ["catalog.json.gz", "ledger.json.gz", "authoritative-targets.json.gz",
                             "assignments.json", "coverage.json", "validation.json", "stage.json"] {
                _ = try contained(output, path: "\(stagePath)/\(required)", label: "tier artifact")
            }
            let manifest = try readObject(output.appendingPathComponent("\(stagePath)/stage.json"), "stage manifest")
            let constraints = manifest["constraints"] as? [String: Any]
            if capabilities.intendedProductPolicies != nil {
                guard let constraints else { throw invalid("stage constraints is missing or malformed.") }
                try expect(string(constraints, "intended_product_policy"),
                           options.alleleOptions.intendedProductPolicy.rawValue, "stage intended-product policy")
            } else {
                if let constraints {
                    try validateLegacyExactPolicy(constraints, label: "stage constraints")
                }
            }
            if capabilities.secondaryProductPolicies != nil {
                guard let constraints else { throw invalid("stage constraints is missing or malformed.") }
                try expect(string(constraints, "secondary_product_policy"),
                           options.alleleOptions.secondaryProductPolicy.rawValue,
                           "stage secondary-product policy")
            } else if let constraints {
                try validateLegacySecondaryPolicy(constraints, label: "stage constraints")
            }
            let stageValidation = try readObject(output.appendingPathComponent("\(stagePath)/validation.json"),
                                                 "stage validation")
            if capabilities.intendedProductPolicies != nil {
                try validateIntendedProducts(stageValidation, policy: options.alleleOptions.intendedProductPolicy,
                                             label: "stage validation")
            } else {
                try validateLegacyIntendedProducts(stageValidation, label: "stage validation")
            }
            if capabilities.secondaryProductPolicies != nil {
                try validateSecondaryProducts(stageValidation, policy: options.alleleOptions.secondaryProductPolicy,
                                              label: "stage validation")
            } else {
                try validateLegacySecondaryProducts(stageValidation, label: "stage validation")
            }
        }

        let provenanceURL = output.appendingPathComponent("panel-provenance.json")
        let provenance = try readObject(provenanceURL, "panel provenance")
        try expect(string(provenance, "schemaVersion"), "primalscheme3.panel-provenance/v1", "provenance schema")
        try expect(string(provenance, "toolVersion"), PrimalScheme3DesignPipeline.alleleToolVersion, "provenance version")
        try expect(string(provenance, "status"), "success", "provenance status")
        try expect(integer(provenance, "exitStatus"), 0, "provenance exit status")
        guard try bool(provenance, "sourceChangedDuringRun") == false,
              try bool(provenance, "runtimeChangedDuringRun") == false,
              equalJSON(provenance["source"], capabilities.source),
              equalJSON(provenance["sourceAtEnd"], capabilities.source),
              equalJSON(provenance["runtime"], capabilities.runtime),
              equalJSON(provenance["runtimeAtEnd"], capabilities.runtime) else {
            throw invalid("Native source/runtime identity differs from the verified capability probe.")
        }
        let designCommand = try object(provenance["command"], "native design command")
        guard try strings(designCommand, "argv") == executedArgv else {
            throw invalid("Native panel provenance is detached from the exact executed design command.")
        }
        let inputs = try objectArray(provenance["inputs"], "native inputs")
        guard inputs.count == inputCount else { throw invalid("Native input inventory count is wrong.") }
        let msaArguments = values(after: "--msa", in: executedArgv)
        guard msaArguments.count == inputCount else { throw invalid("Executed MSA argument order is incomplete.") }
        for (index, descriptor) in inputs.enumerated() {
            try expect(integer(descriptor, "sourceIndex"), index, "input source index")
            let stored = try contained(output, path: try string(descriptor, "storedPath"), label: "stored input")
            try validateDescriptor(descriptor, file: stored)
            guard URL(fileURLWithPath: try string(descriptor, "sourcePath")).resolvingSymlinksInPath().standardizedFileURL
                == URL(fileURLWithPath: msaArguments[index]).resolvingSymlinksInPath().standardizedFileURL,
                  try bool(descriptor, "sourceChangedDuringRun") == false,
                  try bool(descriptor, "storedMissing") == false else {
                throw invalid("Native input ordering, source identity, or stored snapshot is inconsistent.")
            }
        }
        let nativeFiles = try regularFiles(output)
        let relativeFiles = Dictionary(uniqueKeysWithValues: nativeFiles.map { (relative($0, to: output), $0) })
        try validateInventory(try objectArray(provenance["outputs"], "native outputs"),
                              files: relativeFiles.filter { $0.key != "panel-provenance.json" }, label: "native output")

        guard let auditValidation, let auditProvenance else {
            throw invalid("Independent native panel-audit evidence is required.")
        }
        let validation = try object(JSONSerialization.jsonObject(with: auditValidation), "audit validation")
        guard try bool(validation, "valid"), try bool(validation, "raw_inputs_reparsed") else {
            throw invalid("Independent native panel-audit did not reparse and validate the stored inputs.")
        }
        try expect(string(validation, "primary_tier"), options.alleleOptions.primaryTier, "audit primary tier")
        try expect(string(validation, "scope"), "stored-original-inputs-and-fresh-selected-stage-kernels", "audit scope")
        let auditedStages = try object(validation["stages"], "audit stages")
        guard Set(auditedStages.keys) == publishedStageIDs else {
            throw invalid("Independent native panel-audit has a missing or invalid tier.")
        }
        for value in auditedStages.values {
            let stage = try object(value, "audit stage")
            guard try bool(stage, "valid") else {
                throw invalid("Independent native panel-audit has a missing or invalid tier.")
            }
            if capabilities.intendedProductPolicies != nil {
                try validateIntendedProducts(stage, policy: options.alleleOptions.intendedProductPolicy,
                                             label: "audit stage")
            } else {
                try validateLegacyIntendedProducts(stage, label: "audit stage")
            }
            if capabilities.secondaryProductPolicies != nil {
                try validateSecondaryProducts(stage, policy: options.alleleOptions.secondaryProductPolicy,
                                              label: "audit stage")
            } else {
                try validateLegacySecondaryProducts(stage, label: "audit stage")
            }
        }
        let audit = try object(JSONSerialization.jsonObject(with: auditProvenance), "audit provenance")
        try expect(string(audit, "schemaVersion"), "primalscheme3.panel-inspection-provenance/v1", "audit provenance schema")
        try expect(string(audit, "toolVersion"), PrimalScheme3DesignPipeline.alleleToolVersion, "audit version")
        try expect(string(audit, "status"), "success", "audit status")
        try expect(integer(audit, "exitStatus"), 0, "audit exit status")
        guard try bool(audit, "inputChangedDuringRun") == false,
              try bool(audit, "sourceChangedDuringRun") == false,
              try bool(audit, "runtimeChangedDuringRun") == false,
              equalJSON(audit["source"], capabilities.source), equalJSON(audit["sourceAtEnd"], capabilities.source),
              equalJSON(audit["runtime"], capabilities.runtime), equalJSON(audit["runtimeAtEnd"], capabilities.runtime) else {
            throw invalid("The independent audit is detached from the verified source/runtime identity.")
        }
        let command = try object(audit["command"], "audit command")
        let auditArgv = try strings(command, "argv")
        guard let auditExecutedArgv, auditExitStatus == 0, auditArgv == auditExecutedArgv,
              auditArgv.contains("panel-audit"), let bundleIndex = auditArgv.firstIndex(of: "--bundle"),
              bundleIndex + 1 < auditArgv.count,
              URL(fileURLWithPath: auditArgv[bundleIndex + 1]).resolvingSymlinksInPath().standardizedFileURL
                == output.resolvingSymlinksInPath().standardizedFileURL else {
            throw invalid("The audit command is not bound to this native result directory.")
        }
        try validateInventory(try objectArray(audit["inputs"], "audit inputs"), files: relativeFiles, label: "audit input")
        let outputs = try objectArray(audit["outputs"], "audit outputs")
        guard outputs.count == 1, try string(outputs[0], "path") == "validation.json",
              try string(outputs[0], "sha256") == sha256(auditValidation),
              try integer(outputs[0], "size") == auditValidation.count else {
            throw invalid("The audit receipt is not bound to the retained validation result.")
        }
    }

    private static func validateResolved(_ value: [String: Any], options: PrimalScheme3DesignOptions,
                                         supportsPhaseScheduling: Bool,
                                         supportsIntendedProducts: Bool,
                                         supportsSecondaryProducts: Bool) throws {
        let allele = options.alleleOptions
        let expectedStrings = ["preset": allele.preset, "candidate_profiles": allele.candidateProfiles,
            "variant_selection": allele.variantSelection, "allele_weighting": allele.alleleWeighting,
            "discovery_length_mode": allele.discoveryLengthMode, "salvage": allele.salvage,
            "primary_tier": allele.primaryTier, "coverage_metric": options.coverageMetric.rawValue]
        for (key, expected) in expectedStrings { try expect(string(value, key), expected, key) }
        if supportsPhaseScheduling {
            try expect(string(value, "phase_scheduling"), allele.phaseScheduling.rawValue, "phase scheduling")
        } else if allele.requestedOptionNames.contains("phaseScheduling") {
            throw invalid("The explicitly requested phase-scheduling policy was not advertised by the executable.")
        }
        if supportsIntendedProducts {
            try expect(string(value, "intended_product_policy"), allele.intendedProductPolicy.rawValue,
                       "intended-product policy")
        } else if allele.requestedOptionNames.contains("intendedProductPolicy") {
            throw invalid("The explicitly requested intended-product policy was not advertised by the executable.")
        } else {
            try validateLegacyExactPolicy(value, label: "resolved options")
        }
        if supportsSecondaryProducts {
            try expect(string(value, "secondary_product_policy"), allele.secondaryProductPolicy.rawValue,
                       "secondary-product policy")
        } else if allele.requestedOptionNames.contains("secondaryProductPolicy") {
            throw invalid("The explicitly requested secondary-product policy was not advertised by the executable.")
        } else {
            try validateLegacySecondaryPolicy(value, label: "resolved options")
        }
        let expectedIntegers = ["specificity_terminal_k": allele.specificityTerminalK,
            "subset_beam_width": allele.subsetBeamWidth, "subset_expansion_limit": allele.subsetExpansionLimit,
            "exchange_width": allele.exchangeWidth, "salvage_max_stages": allele.salvageMaxStages,
            "salvage_max_edges_per_pool": allele.salvageMaxEdgesPerPool,
            "salvage_max_oligos_per_pool": allele.salvageMaxOligosPerPool,
            "work_frontier_candidates": allele.workFrontierCandidates,
            "work_construction_candidate_attempts": allele.workConstructionCandidateAttempts,
            "work_repair_candidate_probes_per_round": allele.workRepairCandidateProbesPerRound,
            "work_repair_neighborhoods_per_round": allele.workRepairNeighborhoodsPerRound,
            "work_repair_trials_per_round": allele.workRepairTrialsPerRound,
            "work_pool_lookahead_candidates": allele.workPoolLookaheadCandidates,
            "work_cleanup_moves_per_round": allele.workCleanupMovesPerRound,
            "work_families_per_refresh": allele.workFamiliesPerRefresh]
        for (key, expected) in expectedIntegers { try expect(integer(value, key), expected, key) }
        for (key, expected) in ["amplicon_size": options.ampliconSize,
                                "amplicon_size_min": options.ampliconSizeMinimum,
                                "amplicon_size_max": options.ampliconSizeMaximum,
                                "n_pools": options.poolCount, "ncores": options.coreCount,
                                "optimizer_seed": options.optimizerSeed,
                                "optimizer_starts": options.optimizerStarts,
                                "optimizer_repair_rounds": options.optimizerRepairRounds,
                                "mismatch_product_size": options.misprimingProductSize] {
            try expect(integer(value, key), expected, key)
        }
        try expectOptionalInteger(value, "max_amplicons", options.maxAmplicons)
        try expectOptionalInteger(value, "max_amplicons_msa", options.maxAmpliconsPerMSA)
        try expect(number(value, "min_base_freq"), options.minimumBaseFrequency, "minimum base frequency")
        try expect(number(value, "dimer_score"), options.dimerScore, "dimer score")
        try expect(number(value, "optimizer_time_limit"), options.optimizerTimeLimit, "optimizer time limit")
        try expect(number(value, "salvage_time_limit"), allele.salvageTimeLimit, "salvage time")
        try expect(number(value, "coverage_target"), options.coverageTarget, "coverage target")
        if let reuse = allele.reuseDiscovery {
            guard URL(fileURLWithPath: try string(value, "reuse_discovery")).standardizedFileURL
                    == reuse.standardizedFileURL else {
                throw invalid("Resolved reuse-discovery path differs from the request.")
            }
        } else if !(value["reuse_discovery"] is NSNull) {
            throw invalid("Resolved reuse-discovery must be null when no cache was requested.")
        }
        let thresholds = try numbers(value, "salvage_thresholds")
        guard thresholds == allele.salvageThresholds else { throw invalid("Resolved salvage thresholds differ from the request.") }
        let requested = try object(value["requested_options"], "native requested allele options")
        let names = [
            "preset": "preset", "candidateProfiles": "candidate_profiles", "reuseDiscovery": "reuse_discovery",
            "variantSelection": "variant_selection", "alleleWeighting": "allele_weighting",
            "phaseScheduling": "phase_scheduling",
            "intendedProductPolicy": "intended_product_policy",
            "discoveryLengthMode": "discovery_length_mode", "specificityTerminalK": "specificity_terminal_k",
            "secondaryProductPolicy": "secondary_product_policy", "subsetBeamWidth": "subset_beam_width",
            "subsetExpansionLimit": "subset_expansion_limit", "exchangeWidth": "exchange_width",
            "salvage": "salvage", "salvageThresholds": "salvage_thresholds",
            "salvageMaxStages": "salvage_max_stages", "salvageMaxEdgesPerPool": "salvage_max_edges_per_pool",
            "salvageMaxOligosPerPool": "salvage_max_oligos_per_pool", "salvageTimeLimit": "salvage_time_limit",
            "primaryTier": "primary_tier", "workFrontierCandidates": "work_frontier_candidates",
            "workConstructionCandidateAttempts": "work_construction_candidate_attempts",
            "workRepairCandidateProbesPerRound": "work_repair_candidate_probes_per_round",
            "workRepairNeighborhoodsPerRound": "work_repair_neighborhoods_per_round",
            "workRepairTrialsPerRound": "work_repair_trials_per_round",
            "workPoolLookaheadCandidates": "work_pool_lookahead_candidates",
            "workCleanupMovesPerRound": "work_cleanup_moves_per_round",
            "workFamiliesPerRefresh": "work_families_per_refresh"
        ]
        for requestedName in allele.requestedOptionNames {
            guard let nativeName = names[requestedName], let requestedValue = requested[nativeName],
                  let resolvedValue = value[nativeName], equalJSON(requestedValue, resolvedValue) else {
                throw invalid("Requested allele override \(requestedName) is absent or differs from the resolved configuration.")
            }
        }
    }

    private static func validateInventory(_ descriptors: [[String: Any]], files: [String: URL], label: String) throws {
        guard descriptors.count == files.count else { throw invalid("The \(label) inventory is incomplete.") }
        var seen = Set<String>()
        for descriptor in descriptors {
            let path = try safeRelative(string(descriptor, "path"))
            guard seen.insert(path).inserted, let file = files[path] else {
                throw invalid("The \(label) inventory contains an unknown or duplicate path.")
            }
            try validateDescriptor(descriptor, file: file)
        }
    }

    private static func validateDescriptor(_ descriptor: [String: Any], file: URL) throws {
        try expect(string(descriptor, "sha256"), try ProvenanceFileHasher.sha256(of: file), "file hash")
        try expect(integer(descriptor, "size"), Int(try ProvenanceFileHasher.fileSize(of: file)), "file size")
    }

    private static func contained(_ root: URL, path: String, label: String) throws -> URL {
        let relativePath = try safeRelative(path)
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: candidate.path) else {
            throw invalid("The \(label) path is missing or escapes the native result.")
        }
        return candidate
    }

    private static func safeRelative(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw invalid("A native path is unsafe.")
        }
        return path
    }

    private static func regularFiles(_ root: URL) throws -> [URL] {
        let values = try root.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw invalid("Native output contains a symbolic link.") }
        if values.isRegularFile == true { return [root] }
        guard values.isDirectory == true else { throw invalid("Native output contains an unsupported file.") }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap(regularFiles)
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        url.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count).joined(separator: "/")
    }

    private static func values(after flag: String, in argv: [String]) -> [String] {
        argv.indices.compactMap { argv[$0] == flag && $0 + 1 < argv.count ? argv[$0 + 1] : nil }
    }

    private static func readObject(_ url: URL, _ label: String) throws -> [String: Any] {
        try object(JSONSerialization.jsonObject(with: Data(contentsOf: url)), label)
    }

    private static func validateGzipSchema(_ url: URL, expected: String) throws {
        let text = try GzipInputStream(url: url).readAllSync()
        guard let data = text.data(using: .utf8) else { throw invalid("Compressed native JSON is not UTF-8.") }
        let value = try object(JSONSerialization.jsonObject(with: data), "compressed native JSON")
        try expect(string(value, "schema_version"), expected, "compressed artifact schema")
    }

    private static func object(_ value: Any?, _ label: String) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw invalid("\(label) is missing or malformed.") }
        return result
    }

    private static func objectArray(_ value: Any?, _ label: String) throws -> [[String: Any]] {
        guard let result = value as? [[String: Any]] else { throw invalid("\(label) is missing or malformed.") }
        return result
    }

    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let result = object[key] as? String else { throw invalid("\(key) is missing or malformed.") }
        return result
    }

    private static func strings(_ object: [String: Any], _ key: String) throws -> [String] {
        guard let result = object[key] as? [String] else { throw invalid("\(key) is missing or malformed.") }
        return result
    }

    private static func numbers(_ object: [String: Any], _ key: String) throws -> [Double] {
        guard let values = object[key] as? [Any] else { throw invalid("\(key) is missing or malformed.") }
        return try values.map { value in
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw invalid("\(key) is missing or malformed.")
            }
            return number.doubleValue
        }
    }

    private static func integers(_ object: [String: Any], _ key: String) throws -> [Int] {
        guard let values = object[key] as? [Any] else { throw invalid("\(key) is missing or malformed.") }
        return try values.map { value in
            guard nonnegativeInteger(value), let number = value as? NSNumber else {
                throw invalid("\(key) is missing or malformed.")
            }
            return number.intValue
        }
    }

    private static func integer(_ object: [String: Any], _ key: String) throws -> Int {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue else {
            throw invalid("\(key) is missing or malformed.")
        }
        return number.intValue
    }

    private static func number(_ object: [String: Any], _ key: String) throws -> Double {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { throw invalid("\(key) is missing or malformed.") }
        return number.doubleValue
    }

    private static func bool(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw invalid("\(key) is missing or malformed.")
        }
        return number.boolValue
    }

    private static func expectOptionalInteger(_ object: [String: Any], _ key: String, _ expected: Int?) throws {
        if let expected { try expect(integer(object, key), expected, key) }
        else if !(object[key] is NSNull) { throw invalid("Native \(key) must be null.") }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func descriptorIdentityValid(_ value: [String: Any]) -> Bool {
        guard let path = value["path"] as? String, !path.isEmpty,
              let digest = value["sha256"] as? String, isDigest(digest),
              let size = value["size"] as? NSNumber, size.intValue >= 0 else { return false }
        return true
    }

    private static func dependencyIdentityValid(_ value: [String: Any]) -> Bool {
        let name = (value["distribution"] ?? value["package"]) as? String
        guard name?.isEmpty == false, let version = value["version"] as? String, !version.isEmpty else { return false }
        if let files = value["files"] as? [[String: Any]] {
            return !files.isEmpty && files.allSatisfy(descriptorIdentityValid)
        }
        return true
    }

    private static func nativeKernelIdentityValid(_ value: [String: Any]) -> Bool {
        guard dependencyIdentityValid(value), let files = value["files"] as? [[String: Any]], !files.isEmpty else {
            return false
        }
        return files.allSatisfy(descriptorIdentityValid)
    }

    private static func validPhaseName(_ value: String) -> Bool {
        if value == "seed:full" || value == "seed:normal" { return true }
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        if pieces.count == 1 {
            let construction = pieces[0].split(separator: ":", omittingEmptySubsequences: false)
            return construction.count == 2 && construction[0] == "construction"
                && Int(construction[1]).map { $0 >= 0 } == true
        }
        guard pieces.count == 2,
              ["preparation", "cleanup", "exchange"].contains(String(pieces[1])) else { return false }
        let repair = pieces[0].split(separator: ":", omittingEmptySubsequences: false)
        return repair.count == 3 && repair[0] == "repair"
            && Int(repair[1]).map { $0 >= 0 } == true && Int(repair[2]).map { $0 >= 0 } == true
    }

    private static func isInitiallyReservedPhase(_ value: String) -> Bool {
        if value == "seed:full" || value == "seed:normal" || value == "construction:0" { return true }
        return value.hasPrefix("repair:0:")
    }

    private static func validNoAssessableStop(stage: [String: Any], optimizer: [String: Any]) -> Bool {
        guard (try? string(optimizer, "stop_reason")) == "no-assessable-targets",
              let coverage = try? object(stage["coverage"], "stage coverage"),
              (try? string(coverage, "status")) == "no-assessable-targets",
              let assignments = stage["assignments"] as? [Any], assignments.isEmpty,
              let work = try? object(optimizer["work"], "optimizer work"), !work.isEmpty else { return false }
        return work.values.allSatisfy { nonnegativeInteger($0) && ($0 as? NSNumber)?.intValue == 0 }
    }

    private static func validateIntendedProducts(_ validation: [String: Any],
                                                 policy: PrimalScheme3IntendedProductPolicy,
                                                 label: String) throws {
        let profile = try object(validation["profile"], "\(label) profile")
        try expect(string(profile, "intended_product_policy"), policy.rawValue,
                   "\(label) intended-product policy")
        let terminalK = try integer(profile, "mismatch_kmersize")
        let productLimit = try integer(profile, "mismatch_product_size")
        guard terminalK > 0, productLimit > 0 else {
            throw invalid("The \(label) specificity bounds are malformed.")
        }
        let secondary = try objectArray(validation["allowed_secondary_products"],
                                        "\(label) allowed secondary products")
        let intended = try objectArray(validation["allowed_intended_products"],
                                       "\(label) allowed intended products")
        try expect(integer(validation, "allowed_intended_product_count"), intended.count,
                   "\(label) intended product count")
        if policy == .exactSupported, !intended.isEmpty {
            throw invalid("Exact-supported output cannot allow nonexact intended products.")
        }
        let secondaryIDs = try Set(secondary.map { try string($0, "id") })
        for witness in intended {
            let identifier = try string(witness, "id")
            guard !identifier.isEmpty, !secondaryIDs.contains(identifier),
                  try string(witness, "classification") == "nonexact-designated-intended-product",
                  try string(witness, "reason") == "concrete-designated-sites",
                  try string(witness, "policy_id") == "concrete-designated-sites/v1",
                  try number(witness, "coverage_credit") == 0,
                  try bool(witness, "uncertain") == false else {
                throw invalid("The allowed intended-product classification is malformed or overlaps secondary products.")
            }
            let targetID = try string(witness, "target_id")
            let rowID = try string(witness, "row_id")
            let plus = try object(witness["plus"], "intended product plus hit")
            let minus = try object(witness["minus"], "intended product minus hit")
            let owners = try strings(witness, "owners")
            let siteIDs = try strings(witness, "site_ids")
            guard siteIDs.count == 2 else { throw invalid("The intended product must identify both designated sites.") }
            let certificate = try object(witness["certificate"], "intended product certificate")
            let certificateKeys: Set<String> = ["configuration_id", "target_id", "row_id", "forward_site_id",
                                                "reverse_site_id", "forward", "reverse"]
            guard Set(certificate.keys) == certificateKeys else {
                throw invalid("The intended product certificate is incomplete.")
            }
            for key in ["configuration_id", "target_id", "row_id", "forward_site_id", "reverse_site_id"] {
                guard !(try string(certificate, key)).isEmpty else {
                    throw invalid("The intended product certificate contains an empty identity.")
                }
            }
            let forwardSiteID = try string(certificate, "forward_site_id")
            let reverseSiteID = try string(certificate, "reverse_site_id")
            let configurationID = try string(certificate, "configuration_id")
            guard try string(certificate, "target_id") == targetID,
                  try string(certificate, "row_id") == rowID,
                  siteIDs == [forwardSiteID, reverseSiteID],
                  owners.contains(configurationID),
                  try strings(plus, "owners").contains(configurationID),
                  try strings(minus, "owners").contains(configurationID) else {
                throw invalid("The intended product certificate is detached from its witness.")
            }
            let plusStart = try integer(plus, "start"), plusEnd = try integer(plus, "end")
            let minusStart = try integer(minus, "start"), minusEnd = try integer(minus, "end")
            guard try string(plus, "orientation") == "+", try string(minus, "orientation") == "-",
                  plusStart >= 0, plusEnd > plusStart, minusStart >= plusEnd, minusEnd > minusStart,
                  try integer(witness, "start") == plusStart,
                  try integer(witness, "end") == minusEnd,
                  try integer(witness, "length") == minusEnd - plusStart,
                  minusEnd - plusStart <= productLimit else {
                throw invalid("The intended product hit geometry is malformed.")
            }
            var fullMismatchCount = 0
            for side in ["forward", "reverse"] {
                let projection = try object(certificate[side], "intended product certificate \(side)")
                let projectionKeys: Set<String> = ["site_id", "expected_footprint", "oligo", "observed_template",
                                                   "mismatch_positions", "terminal_mismatch_positions",
                                                   "outside_terminal_mismatch_positions"]
                guard Set(projection.keys) == projectionKeys,
                      !(try string(projection, "site_id")).isEmpty,
                      !(try string(projection, "oligo")).isEmpty,
                      !(try string(projection, "observed_template")).isEmpty else {
                    throw invalid("The intended product concrete site projection is incomplete.")
                }
                let expectedSiteID = side == "forward" ? forwardSiteID : reverseSiteID
                guard try string(projection, "site_id") == expectedSiteID else {
                    throw invalid("The intended product projection is detached from its designated site.")
                }
                let footprint = try integers(projection, "expected_footprint")
                let oligo = try string(projection, "oligo")
                let observed = try string(projection, "observed_template")
                let oligoBases = Array(oligo), observedBases = Array(observed)
                guard oligoBases.count == observedBases.count else {
                    throw invalid("The intended product concrete templates have inconsistent lengths.")
                }
                let mismatches = try integers(projection, "mismatch_positions")
                let terminal = try integers(projection, "terminal_mismatch_positions")
                let outside = try integers(projection, "outside_terminal_mismatch_positions")
                let measured = oligoBases.indices.filter { oligoBases[$0] != observedBases[$0] }
                let witnessHit = side == "forward" ? plus : minus
                let hitStart = side == "forward" ? plusStart : minusStart
                let hitEnd = side == "forward" ? plusEnd : minusEnd
                let expectedTerminalInterval = side == "forward"
                    ? [hitEnd - terminalK, hitEnd] : [hitStart, hitStart + terminalK]
                let boundary = oligoBases.count - terminalK
                let expectedTerminal = measured.filter { $0 >= boundary }
                let expectedOutside = measured.filter { $0 < boundary }
                let hitMismatchCount = try integer(witnessHit, "mismatches")
                let expectedClassification = hitMismatchCount == 0 ? "exact-terminal" : "single-mismatch"
                guard footprint.count == 2, footprint[0] >= 0, footprint[1] > footprint[0],
                      footprint == [hitStart, hitEnd],
                      footprint[1] - footprint[0] == oligoBases.count,
                      oligoBases.count >= terminalK,
                      oligoBases.allSatisfy({ "ACGT".contains($0) }),
                      observedBases.allSatisfy({ "ACGT".contains($0) }),
                      try string(witnessHit, "oligo") == oligo,
                      try integers(witnessHit, "terminal_interval") == expectedTerminalInterval,
                      hitMismatchCount == expectedTerminal.count, hitMismatchCount <= 1,
                      try string(witnessHit, "classification") == expectedClassification,
                      mismatches == measured,
                      mismatches == mismatches.sorted(), Set(mismatches).count == mismatches.count,
                      terminal == expectedTerminal, outside == expectedOutside else {
                    throw invalid("The intended product concrete footprint is malformed.")
                }
                fullMismatchCount += mismatches.count
            }
            guard fullMismatchCount > 0 else {
                throw invalid("A newly allowed intended product must contain a concrete full-footprint mismatch.")
            }
        }
    }

    private static func validateLegacyExactPolicy(_ object: [String: Any], label: String) throws {
        guard let value = object["intended_product_policy"] else { return }
        guard let policy = value as? String, policy == PrimalScheme3IntendedProductPolicy.exactSupported.rawValue else {
            throw invalid("The legacy \(label) claims an unsupported intended-product policy.")
        }
    }

    private static func validateLegacyIntendedProducts(_ validation: [String: Any], label: String) throws {
        if let profile = validation["profile"] as? [String: Any] {
            try validateLegacyExactPolicy(profile, label: "\(label) profile")
        }
        if let value = validation["allowed_intended_products"] {
            let intended = try objectArray(value, "\(label) allowed intended products")
            guard intended.isEmpty else {
                throw invalid("The legacy \(label) cannot allow nonexact intended products.")
            }
        }
        if validation["allowed_intended_product_count"] != nil {
            try expect(integer(validation, "allowed_intended_product_count"), 0,
                       "\(label) intended product count")
        }
    }

    private struct SecondaryProjectionEvidence {
        let footprint: [Int]
        let mismatchCount: Int
        let terminalHit: [String: Any]
    }

    private static func validateSecondaryProducts(_ validation: [String: Any],
                                                  policy: PrimalScheme3SecondaryProductPolicy,
                                                  label: String) throws {
        let profile = try object(validation["profile"], "\(label) profile")
        try expect(string(profile, "secondary_product_policy"), policy.rawValue,
                   "\(label) secondary-product policy")
        let terminalK = try integer(profile, "mismatch_kmersize")
        let productLimit = try integer(profile, "mismatch_product_size")
        guard terminalK > 0, productLimit > 0 else {
            throw invalid("The \(label) specificity bounds are malformed.")
        }
        let products = try objectArray(validation["allowed_secondary_products"],
                                       "\(label) allowed secondary products")
        try expect(integer(validation, "allowed_secondary_product_count"), products.count,
                   "\(label) secondary product count")
        if policy == .rejectSecondaryProducts, !products.isEmpty {
            throw invalid("Reject-secondary-products output cannot allow secondary products.")
        }
        for witness in products {
            let reason = try string(witness, "reason")
            if reason == PrimalScheme3SecondaryProductPolicy.orderedDisjointIntendedSites.rawValue {
                guard witness["certificate"] == nil, witness["classification"] == nil,
                      witness["policy_id"] == nil else {
                    throw invalid("An exact secondary-product witness contains concrete-policy evidence.")
                }
                continue
            }
            guard reason == PrimalScheme3SecondaryProductPolicy.orderedDisjointConcreteDesignatedSites.rawValue,
                  policy == .orderedDisjointConcreteDesignatedSites else {
                throw invalid("The allowed secondary-product policy does not permit this witness.")
            }
            try validateConcreteSecondaryProduct(witness, terminalK: terminalK,
                                                 productLimit: productLimit, label: label)
        }
    }

    private static func validateConcreteSecondaryProduct(_ witness: [String: Any], terminalK: Int,
                                                         productLimit: Int, label: String) throws {
        let policy = PrimalScheme3SecondaryProductPolicy.orderedDisjointConcreteDesignatedSites.rawValue
        guard !(try string(witness, "id")).isEmpty,
              try string(witness, "classification") == "nonexact-ordered-concrete-secondary-product",
              try string(witness, "reason") == policy,
              try string(witness, "policy_id") == policy,
              try number(witness, "coverage_credit") == 0,
              try bool(witness, "uncertain") == false else {
            throw invalid("The allowed concrete secondary-product classification is malformed.")
        }
        let targetID = try string(witness, "target_id")
        let rowID = try string(witness, "row_id")
        let owners = try strings(witness, "owners")
        let siteIDs = try strings(witness, "site_ids")
        guard !targetID.isEmpty, !rowID.isEmpty, siteIDs.count == 4 else {
            throw invalid("The concrete secondary-product identity is incomplete.")
        }
        let certificate = try object(witness["certificate"], "concrete secondary-product certificate")
        let certificateKeys: Set<String> = ["target_id", "row_id", "left_configuration_id",
                                            "right_configuration_id", "left_forward", "left_reverse",
                                            "right_forward", "right_reverse"]
        guard Set(certificate.keys) == certificateKeys else {
            throw invalid("The concrete secondary-product certificate is incomplete.")
        }
        let leftID = try string(certificate, "left_configuration_id")
        let rightID = try string(certificate, "right_configuration_id")
        guard !leftID.isEmpty, !rightID.isEmpty, leftID != rightID,
              try string(certificate, "target_id") == targetID,
              try string(certificate, "row_id") == rowID,
              owners.contains(leftID), owners.contains(rightID) else {
            throw invalid("The concrete secondary-product certificate is detached from its witness owners.")
        }
        let specifications: [(String, String, String, String)] = [
            ("left_forward", "+", leftID, siteIDs[0]),
            ("left_reverse", "-", leftID, siteIDs[1]),
            ("right_forward", "+", rightID, siteIDs[2]),
            ("right_reverse", "-", rightID, siteIDs[3]),
        ]
        let declaredFootprints = try specifications.map {
            try integers(try object(certificate[$0.0], "concrete secondary-product \($0.0)"),
                         "expected_footprint")
        }
        guard declaredFootprints.allSatisfy({ $0.count == 2 }),
              declaredFootprints[0][1] <= declaredFootprints[1][0],
              declaredFootprints[1][1] <= declaredFootprints[2][0],
              declaredFootprints[2][1] <= declaredFootprints[3][0] else {
            throw invalid("The concrete secondary-product designated sites have invalid ordered geometry.")
        }
        var projections: [SecondaryProjectionEvidence] = []
        for (key, orientation, owner, siteID) in specifications {
            projections.append(try validateSecondaryProjection(
                try object(certificate[key], "concrete secondary-product \(key)"),
                expectedSiteID: siteID, orientation: orientation, owner: owner,
                terminalK: terminalK, label: label))
        }
        let footprints = projections.map(\.footprint)
        let plus = try object(witness["plus"], "concrete secondary-product plus hit")
        let minus = try object(witness["minus"], "concrete secondary-product minus hit")
        let externalStart = footprints[0][0]
        let externalEnd = footprints[3][1]
        guard sameTerminalHitOccurrence(plus, projections[0].terminalHit),
              sameTerminalHitOccurrence(minus, projections[3].terminalHit),
              try strings(plus, "owners").contains(leftID),
              try strings(minus, "owners").contains(rightID),
              try integer(witness, "start") == externalStart,
              try integer(witness, "end") == externalEnd,
              try integer(witness, "length") == externalEnd - externalStart,
              externalEnd > externalStart, externalEnd - externalStart <= productLimit else {
            throw invalid("The concrete secondary-product external hits are detached or malformed.")
        }
        guard projections.reduce(0, { $0 + $1.mismatchCount }) > 0 else {
            throw invalid("A newly allowed concrete secondary product must contain a full-footprint mismatch.")
        }
    }

    private static func validateSecondaryProjection(_ projection: [String: Any], expectedSiteID: String,
                                                    orientation: String, owner: String, terminalK: Int,
                                                    label: String) throws -> SecondaryProjectionEvidence {
        let keys: Set<String> = ["site_id", "expected_footprint", "oligo", "observed_template",
                                 "mismatch_positions", "terminal_mismatch_positions",
                                 "outside_terminal_mismatch_positions", "terminal_hit"]
        guard Set(projection.keys) == keys, try string(projection, "site_id") == expectedSiteID else {
            throw invalid("The concrete secondary-product projection is incomplete or detached from its site.")
        }
        let footprint = try integers(projection, "expected_footprint")
        let oligo = try string(projection, "oligo")
        let observed = try string(projection, "observed_template")
        let oligoBases = Array(oligo), observedBases = Array(observed)
        let mismatches = try integers(projection, "mismatch_positions")
        let terminal = try integers(projection, "terminal_mismatch_positions")
        let outside = try integers(projection, "outside_terminal_mismatch_positions")
        guard footprint.count == 2, footprint[0] >= 0, footprint[1] > footprint[0],
              footprint[1] - footprint[0] == oligoBases.count,
              oligoBases.count == observedBases.count, oligoBases.count >= terminalK,
              oligoBases.allSatisfy({ "ACGT".contains($0) }),
              observedBases.allSatisfy({ "ACGT".contains($0) }) else {
            throw invalid("The concrete secondary-product projection has malformed templates or footprint.")
        }
        let measured = oligoBases.indices.filter { oligoBases[$0] != observedBases[$0] }
        let boundary = oligoBases.count - terminalK
        guard mismatches == measured, mismatches == mismatches.sorted(),
              Set(mismatches).count == mismatches.count,
              terminal == measured.filter({ $0 >= boundary }),
              outside == measured.filter({ $0 < boundary }) else {
            throw invalid("The concrete secondary-product mismatch partitions are malformed.")
        }
        let hit = try object(projection["terminal_hit"], "concrete secondary-product terminal hit")
        let hitKeys: Set<String> = ["oligo", "orientation", "start", "end", "terminal_interval",
                                    "mismatches", "classification", "owners"]
        let expectedInterval = orientation == "+"
            ? [footprint[1] - terminalK, footprint[1]] : [footprint[0], footprint[0] + terminalK]
        let hitMismatches = try integer(hit, "mismatches")
        let expectedClassification = hitMismatches == 0 ? "exact-terminal" : "single-mismatch"
        guard Set(hit.keys) == hitKeys, try string(hit, "oligo") == oligo,
              try string(hit, "orientation") == orientation,
              try integer(hit, "start") == footprint[0], try integer(hit, "end") == footprint[1],
              try integers(hit, "terminal_interval") == expectedInterval,
              hitMismatches == terminal.count, hitMismatches <= 1,
              try string(hit, "classification") == expectedClassification,
              try strings(hit, "owners") == [owner] else {
            throw invalid("The concrete secondary-product terminal hit is malformed or detached from its owner.")
        }
        return .init(footprint: footprint, mismatchCount: mismatches.count, terminalHit: hit)
    }

    private static func sameTerminalHitOccurrence(_ external: [String: Any],
                                                  _ selected: [String: Any]) -> Bool {
        let keys: Set<String> = ["oligo", "orientation", "start", "end", "terminal_interval",
                                 "mismatches", "classification", "owners"]
        guard Set(external.keys) == keys, Set(selected.keys) == keys else { return false }
        return keys.subtracting(["owners"]).allSatisfy { equalJSON(external[$0], selected[$0]) }
    }

    private static func validateLegacySecondaryPolicy(_ object: [String: Any], label: String) throws {
        guard let value = object["secondary_product_policy"] else { return }
        guard let policy = value as? String,
              policy == PrimalScheme3SecondaryProductPolicy.orderedDisjointIntendedSites.rawValue else {
            throw invalid("The legacy \(label) claims an unsupported secondary-product policy.")
        }
    }

    private static func validateLegacySecondaryProducts(_ validation: [String: Any], label: String) throws {
        if let profile = validation["profile"] as? [String: Any] {
            try validateLegacySecondaryPolicy(profile, label: "\(label) profile")
        }
        guard let value = validation["allowed_secondary_products"] else {
            if validation["allowed_secondary_product_count"] != nil {
                try expect(integer(validation, "allowed_secondary_product_count"), 0,
                           "\(label) secondary product count")
            }
            return
        }
        let products = try objectArray(value, "\(label) allowed secondary products")
        if validation["allowed_secondary_product_count"] != nil {
            try expect(integer(validation, "allowed_secondary_product_count"), products.count,
                       "\(label) secondary product count")
        }
        for witness in products {
            guard (try? string(witness, "reason"))
                    == PrimalScheme3SecondaryProductPolicy.orderedDisjointIntendedSites.rawValue,
                  witness["certificate"] == nil, witness["classification"] == nil,
                  witness["policy_id"] == nil else {
                throw invalid("The legacy \(label) contains a concrete or unknown secondary-product witness.")
            }
        }
    }

    private static func nonnegativeInteger(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite && number.doubleValue >= 0
            && number.doubleValue.rounded() == number.doubleValue
    }

    private static func schedulingPolicy(_ policy: PrimalScheme3PhaseScheduling) -> [String: Any] {
        switch policy {
        case .serial:
            return ["id": "serial/v1"]
        case .reserved:
            return [
                "id": "initial-phase-reservations/v1",
                "initial_weights": ["seeds": 0.2, "construction": 0.4, "repair": 0.4],
                "repair_weights": ["preparation": 0.2, "cleanup": 0.2, "exchange": 0.6]
            ]
        }
    }

    private static func intendedProductPolicy(_ policy: PrimalScheme3IntendedProductPolicy) -> [String: Any] {
        switch policy {
        case .exactSupported:
            return ["id": "exact-supported/v1"]
        case .concreteDesignatedSites:
            return ["id": "concrete-designated-sites/v1", "coverageCredit": 0]
        }
    }

    private static func secondaryProductPolicy(_ policy: PrimalScheme3SecondaryProductPolicy) -> [String: Any] {
        switch policy {
        case .orderedDisjointIntendedSites:
            return ["id": "ordered-disjoint-intended-sites/v1"]
        case .rejectSecondaryProducts:
            return ["id": "reject-secondary-products/v1"]
        case .orderedDisjointConcreteDesignatedSites:
            return ["id": "ordered-disjoint-concrete-designated-sites/v1", "coverageCredit": 0]
        }
    }

    private static func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        guard actual == expected else { throw invalid("Native \(label) does not match the verified request.") }
    }

    private static func equalJSON(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        if let left = lhs as? NSNumber, let right = rhs as? NSNumber {
            return CFGetTypeID(left) == CFGetTypeID(right) && left == right
        }
        if let left = lhs as? String, let right = rhs as? String { return left == right }
        if lhs is NSNull, rhs is NSNull { return true }
        guard JSONSerialization.isValidJSONObject(lhs), JSONSerialization.isValidJSONObject(rhs),
              let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else { return false }
        return left == right
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func invalid(_ message: String) -> PrimalScheme3DesignError {
        .invalidRequest("PrimalScheme: \(message)")
    }
}
