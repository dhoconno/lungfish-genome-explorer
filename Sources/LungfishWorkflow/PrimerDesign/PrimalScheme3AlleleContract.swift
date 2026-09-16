import CoreFoundation
import CryptoKit
import Foundation
import LungfishIO

struct PrimalScheme3AlleleCapabilities: @unchecked Sendable {
    let source: [String: Any]
    let runtime: [String: Any]
}

enum PrimalScheme3AlleleContract {
    static let algorithm = "bounded-allele-coverage/v1"
    static let metric = "observed-allele-primer-trimmed/v1"
    static let catalogSchema = "primalscheme3.variant-catalog/v2"
    static let ledgerSchema = "primalscheme3.configuration-ledger/v2"
    static let validationSchema = "primalscheme3.allele-panel-validation/v2"
    static let optimizerSchema = "primalscheme3.panel-optimizer/v2"
    static let integrationSchema = "primalscheme3.panel-native-integration/v2"

    static func validateCapabilities(_ data: Data) throws -> PrimalScheme3AlleleCapabilities {
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
        return .init(source: source, runtime: runtime)
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
        let resolved = try object(integration["options"], "resolved allele options")
        try validateResolved(resolved, options: options)
        guard let encoded = configuration["allele_options_json"] as? String,
              let encodedData = encoded.data(using: .utf8),
              equalJSON(try JSONSerialization.jsonObject(with: encodedData), resolved) else {
            throw invalid("The full native resolved allele configuration is missing or inconsistent.")
        }
        for (key, schema) in [("optimizer", optimizerSchema), ("validation", validationSchema),
                              ("provenance", "primalscheme3.panel-provenance/v1")] {
            let descriptor = try object(integration[key], "integration \(key)")
            try expect(string(descriptor, "schemaVersion"), schema, "\(key) schema")
            _ = try contained(output, path: try string(descriptor, "path"), label: key)
        }

        let optimizer = try readObject(output.appendingPathComponent("panel-optimizer.json"), "panel optimizer")
        try expect(string(optimizer, "schemaVersion"), optimizerSchema, "optimizer schema")
        try expect(string(optimizer, "algorithm"), algorithm, "optimizer algorithm")
        try expect(string(optimizer, "metric"), metric, "optimizer metric")
        try expect(string(optimizer, "primaryTier"), options.alleleOptions.primaryTier, "optimizer primary tier")
        let history = try object(optimizer["history"], "optimizer history")
        _ = try contained(output, path: try string(history, "path"), label: "history")
        let catalogURL = try contained(output, path: "discovery-catalog.json.gz", label: "catalog")
        let ledgerURL = try contained(output, path: try string(history, "configurationLedger"), label: "ledger")
        try validateGzipSchema(catalogURL, expected: catalogSchema)
        try validateGzipSchema(ledgerURL, expected: ledgerSchema)
        let stages = try objectArray(optimizer["stages"], "optimizer stages")
        guard !stages.isEmpty else { throw invalid("The optimizer has no published tier.") }
        var publishedStageIDs = Set<String>()
        for stage in stages {
            let stagePath = try safeRelative(string(stage, "path"))
            guard publishedStageIDs.insert(try string(stage, "stage_id")).inserted else {
                throw invalid("The optimizer publishes duplicate tier identifiers.")
            }
            for required in ["catalog.json.gz", "ledger.json.gz", "authoritative-targets.json.gz",
                             "assignments.json", "coverage.json", "validation.json", "stage.json"] {
                _ = try contained(output, path: "\(stagePath)/\(required)", label: "tier artifact")
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
        guard Set(auditedStages.keys) == publishedStageIDs, auditedStages.values.allSatisfy({ value in
            guard let stage = value as? [String: Any], let valid = stage["valid"] as? NSNumber else { return false }
            return CFGetTypeID(valid) == CFBooleanGetTypeID() && valid.boolValue
        }) else { throw invalid("Independent native panel-audit has a missing or invalid tier.") }
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

    private static func validateResolved(_ value: [String: Any], options: PrimalScheme3DesignOptions) throws {
        let allele = options.alleleOptions
        let expectedStrings = ["preset": allele.preset, "candidate_profiles": allele.candidateProfiles,
            "variant_selection": allele.variantSelection, "allele_weighting": allele.alleleWeighting,
            "discovery_length_mode": allele.discoveryLengthMode,
            "secondary_product_policy": allele.secondaryProductPolicy, "salvage": allele.salvage,
            "primary_tier": allele.primaryTier, "coverage_metric": options.coverageMetric.rawValue]
        for (key, expected) in expectedStrings { try expect(string(value, key), expected, key) }
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
