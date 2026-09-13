import CoreFoundation
import Foundation
import LungfishIO

struct PrimalScheme3CoverageCapabilities: @unchecked Sendable {
    let source: [String: Any]
    let runtime: [String: Any]
}

enum PrimalScheme3CoverageContract {
    static let capabilitiesSchema = "primalscheme3.capabilities/v1"
    static let algorithm = "bounded-multistart-coverage/v1"
    static let catalogSchema = "primalscheme3.coverage-catalog/v1"
    static let optimizerSchema = "primalscheme3.panel-optimizer/v1"
    static let validationSchema = "primalscheme3.panel-validation/v1"
    static let provenanceSchema = "primalscheme3.panel-provenance/v1"
    static let integrationSchema = "primalscheme3.panel-native-integration/v1"

    static func validateCapabilities(_ data: Data,
                                     terminalPolicy: PrimalScheme3TerminalGapPolicy) throws -> PrimalScheme3CoverageCapabilities {
        let root = try object(try JSONSerialization.jsonObject(with: data), "capabilities")
        try expect(string(root, "schemaVersion"), capabilitiesSchema, "capabilities schema")
        try expect(string(root, "tool"), "primalscheme3", "capability tool")
        try expect(string(root, "toolVersion"), PrimalScheme3DesignPipeline.coverageToolVersion, "capability version")
        guard try strings(root, "selectionAlgorithms").contains("coverage") else {
            throw invalid("The executable does not advertise coverage selection.")
        }
        let coverage = try object(root["coverage"], "coverage capability")
        try expect(string(coverage, "algorithm"), algorithm, "coverage algorithm")
        try expect(string(coverage, "catalogSchemaVersion"), catalogSchema, "catalogue schema")
        try expect(string(coverage, "optimizerSchemaVersion"), optimizerSchema, "optimizer schema")
        try expect(string(coverage, "validationSchemaVersion"), validationSchema, "validation schema")
        try expect(string(coverage, "provenanceSchemaVersion"), provenanceSchema, "provenance schema")
        let profile = try object(coverage["profile"], "coverage profile")
        try expect(string(profile, "name"), "panel-v1", "profile name")
        try expect(string(profile, "specificityRevision"), "intended-sites-v1", "specificity revision")
        let scope = try object(coverage["supportedScope"], "coverage supported scope")
        try expect(string(scope, "mode"), "equal", "coverage mode")
        try expect(string(scope, "mapping"), "first", "coverage mapping")
        try expect(string(scope, "ampliconSizeMetric"), "reference-span", "coverage amplicon size metric")
        for key in ["freshDesign", "linear", "suppliedMsaSpecificity"] {
            guard try bool(scope, key) else { throw invalid("Coverage capability \(key) must be true.") }
        }
        guard try strings(scope, "terminalGapPolicies").contains(terminalPolicy.rawValue) else {
            throw invalid("The executable does not support terminal-gap policy \(terminalPolicy.rawValue).")
        }
        let source = try object(root["source"], "capability source identity")
        _ = try nonemptyString(source, "kind")
        guard try nonemptyString(source, "root").hasPrefix("/") else { throw invalid("Capability source root must be absolute.") }
        _ = try nonemptyString(source, "gitCommit")
        _ = try bool(source, "gitDirty")
        _ = try source["gitStatus"] as? [Any] ?? { throw invalid("Capability source gitStatus is malformed.") }()
        try requireDigest(source, "sourceDigest")
        try requireDescriptors(source["files"], "capability source files", relative: true)
        try requireDescriptor(source["build"], "capability source build", relative: true)
        let runtime = try object(root["runtime"], "capability runtime identity")
        for key in ["pythonVersion", "pythonImplementation", "pythonExecutable", "pythonExecutableResolved",
                    "pythonPrefix", "pythonBasePrefix", "platform", "machine"] {
            _ = try nonemptyString(runtime, key)
        }
        for key in ["pythonExecutable", "pythonExecutableResolved", "pythonPrefix", "pythonBasePrefix"]
            where !(try string(runtime, key)).hasPrefix("/") {
            throw invalid("Capability runtime \(key) must be an absolute path.")
        }
        _ = try object(runtime["kernel"], "capability runtime kernel")
        guard let dependencies = runtime["declaredRuntimeDependencies"] as? [[String: Any]], !dependencies.isEmpty,
              dependencies.allSatisfy({ ($0["distribution"] as? String)?.isEmpty == false && ($0["version"] as? String)?.isEmpty == false }) else {
            throw invalid("Capability runtime dependencies are missing or malformed.")
        }
        guard let kernels = runtime["nativeKernels"] as? [[String: Any]], !kernels.isEmpty else {
            throw invalid("Capability native-kernel evidence is missing.")
        }
        for kernel in kernels {
            for key in ["package", "distribution", "version"] { _ = try nonemptyString(kernel, key) }
            try requireDescriptors(kernel["files"], "capability native-kernel files", relative: false)
        }
        return .init(source: source, runtime: runtime)
    }

    static func validateNativeOutput(at output: URL, configuration: [String: Any],
                                     capabilities: PrimalScheme3CoverageCapabilities,
                                     options: PrimalScheme3DesignOptions, inputCount: Int,
                                     executedArgv: [String]) throws {
        try expect(try string(configuration, "version"), PrimalScheme3DesignPipeline.coverageToolVersion, "configuration version")
        try expect(try string(configuration, "mode"), "equal", "panel mode")
        try expect(try string(configuration, "selection_algorithm"), "coverage", "selection algorithm")
        try expect(try string(configuration, "mapping"), "first", "mapping mode")
        try expect(try string(configuration, "amplicon_size_metric"), "reference-span", "amplicon-size metric")
        guard try bool(configuration, "offline_plots") else { throw invalid("Native offline_plots must be true.") }
        try expect(try integer(configuration, "amplicon_size"), options.ampliconSize, "amplicon size")
        try expect(try integer(configuration, "amplicon_size_min"), options.ampliconSizeMinimum, "minimum amplicon size")
        try expect(try integer(configuration, "amplicon_size_max"), options.ampliconSizeMaximum, "maximum amplicon size")
        try expect(try integer(configuration, "n_pools"), options.poolCount, "pool count")
        try expect(try optionalInteger(configuration, "max_amplicons"), options.maxAmplicons, "amplicon cap")
        try expect(try optionalInteger(configuration, "max_amplicons_msa"), options.maxAmpliconsPerMSA, "per-MSA amplicon cap")
        try expect(try bool(configuration, "high_gc"), options.highGC, "high-GC mode")
        try expect(try number(configuration, "min_base_freq"), options.minimumBaseFrequency, "minimum base frequency")
        try expect(try integer(configuration, "ncores"), options.coreCount, "requested core count")
        let workers = try object(configuration["discovery_workers_by_msa"], "discovery workers by MSA")
        guard workers.count == inputCount, workers.values.allSatisfy({ value in
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded() == number.doubleValue else { return false }
            return (1...options.coreCount).contains(number.intValue)
        }) else { throw invalid("Native per-MSA discovery worker counts are invalid.") }
        try expect(try string(configuration, "terminal_gap_policy"), options.terminalGapPolicy.rawValue, "terminal-gap policy")
        try expect(try string(configuration, "discovery_backend"), options.terminalGapPolicy.discoveryBackend, "discovery backend")
        try expect(try number(configuration, "dimer_score"), options.dimerScore, "dimer score")
        try expect(try bool(configuration, "use_matchdb"), options.useMatchDB, "MatchDB option")
        try expect(try string(configuration, "coverage_metric"), options.coverageMetric.rawValue, "coverage metric")
        try expect(try number(configuration, "coverage_target"), options.coverageTarget, "coverage target")
        try expect(try integer(configuration, "optimizer_seed"), options.optimizerSeed, "optimizer seed")
        try expect(try integer(configuration, "optimizer_starts"), options.optimizerStarts, "optimizer starts")
        try expect(try integer(configuration, "optimizer_repair_rounds"), options.optimizerRepairRounds, "optimizer repair rounds")
        try expect(try number(configuration, "optimizer_time_limit"), options.optimizerTimeLimit, "optimizer time limit")
        try expect(try integer(configuration, "mismatch_product_size"), options.misprimingProductSize, "mispriming product size")
        for key in ["circular", "downsample", "use_annealing"] {
            guard try bool(configuration, key) == false else { throw invalid("Unsupported coverage option \(key) must be disabled.") }
        }
        for key in ["input_bedfile", "region_bedfile", "max_amplicons_region_group", "primer_annealing_prop"] {
            guard configuration[key] is NSNull else { throw invalid("Unsupported coverage option \(key) must be null.") }
        }
        try expect(try number(configuration, "downsample_target"), 0.99, "disabled downsample target default")
        try expect(try number(configuration, "downsample_always_add_prop"), 0.25, "disabled downsample add default")

        let expectedProfile = profile(for: options)
        let expectedOptions: [String: Any] = ["metric": options.coverageMetric.rawValue,
            "coverage_target": options.coverageTarget, "seed": options.optimizerSeed,
            "starts": options.optimizerStarts, "repair_rounds": options.optimizerRepairRounds,
            "time_limit": options.optimizerTimeLimit]
        let integration = try object(configuration["panel_optimizer"], "panel_optimizer integration")
        let requiredIntegrationKeys: Set<String> = ["schemaVersion", "selectionAlgorithm", "toolVersion", "profile",
            "options", "catalog", "optimizer", "validation", "provenance", "publication"]
        guard Set(integration.keys) == requiredIntegrationKeys else { throw invalid("panel_optimizer integration keys are incomplete or unexpected.") }
        try expect(try string(integration, "schemaVersion"), integrationSchema, "integration schema")
        try expect(try string(integration, "selectionAlgorithm"), "coverage", "integration algorithm")
        try expect(try string(integration, "toolVersion"), PrimalScheme3DesignPipeline.coverageToolVersion, "integration tool version")
        guard equalJSON(try object(integration["profile"], "integration profile"), expectedProfile),
              equalJSON(try object(integration["options"], "integration options"), expectedOptions) else {
            throw invalid("Native coverage profile or optimizer options do not match the resolved request.")
        }

        let catalogDescriptor = try object(integration["catalog"], "catalogue descriptor")
        try expect(try safeRelativePath(catalogDescriptor["path"], "catalogue path"), "candidate-catalog.json.gz", "catalogue path")
        try expect(try string(catalogDescriptor, "schemaVersion"), catalogSchema, "catalogue descriptor schema")
        try requireDigest(catalogDescriptor, "semanticDigest")
        try requireDigest(catalogDescriptor, "fileSha256")
        let catalogURL = try containedFile(output, catalogDescriptor["path"], "catalogue")
        try expect(try integer(catalogDescriptor, "fileSize", minimum: 0), Int(try ProvenanceFileHasher.fileSize(of: catalogURL)), "catalogue byte size")
        try expect(try string(catalogDescriptor, "fileSha256"), try ProvenanceFileHasher.sha256(of: catalogURL), "catalogue file hash")
        let catalogText = try GzipInputStream(url: catalogURL).readAllSync()
        guard let catalogData = catalogText.data(using: .utf8) else { throw invalid("Catalogue is not UTF-8 JSON.") }
        let catalog = try object(try JSONSerialization.jsonObject(with: catalogData), "coverage catalogue")
        try expect(try string(catalog, "schema"), catalogSchema, "catalogue schema")
        try expect(try string(catalog, "semantic_digest"), try string(catalogDescriptor, "semanticDigest"), "catalogue semantic digest")
        let metadata = try object(catalog["metadata"], "catalogue metadata")
        let resolved = try object(metadata["resolved_config"], "catalogue resolved configuration")
        try expect(try string(resolved, "output"), ".", "catalogue output")
        try validateCatalogResolved(resolved, options: options)
        let targets = try objectArray(catalog["targets"], "catalogue targets")
        guard targets.count == inputCount else { throw invalid("Catalogue target count does not match the supplied inputs.") }
        let targetIDs = try uniqueStrings(targets, key: "id", label: "catalogue target")
        let oligos = try objectArray(catalog["oligos"], "catalogue oligos")
        let oligoIDs = try uniqueStrings(oligos, key: "id", label: "catalogue oligo")
        let oligoSequences = Dictionary(uniqueKeysWithValues: try oligos.map {
            (try string($0, "id"), try nonemptyString($0, "sequence"))
        })
        let candidates = try objectArray(catalog["candidates"], "catalogue candidates")
        let candidateIDs = try uniqueStrings(candidates, key: "id", label: "catalogue candidate")
        guard let sourceMapping = metadata["source_mapping"] as? [[Any]], sourceMapping.count == targets.count else {
            throw invalid("Catalogue source mapping is missing or malformed.")
        }
        var mappedTargets: [Int: String] = [:]
        for pair in sourceMapping {
            guard pair.count == 2, let number = pair[0] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue,
                  (0..<inputCount).contains(number.intValue), let targetID = pair[1] as? String,
                  targetIDs.contains(targetID), mappedTargets.updateValue(targetID, forKey: number.intValue) == nil else {
                throw invalid("Catalogue source mapping is not a strict input-to-target bijection.")
            }
        }
        var targetSources: [Int: String] = [:]
        for target in targets {
            let targetID = try string(target, "id")
            let sourceIndex = try integer(target, "source_msa_index", minimum: 0)
            guard sourceIndex < inputCount,
                  targetSources.updateValue(targetID, forKey: sourceIndex) == nil,
                  mappedTargets[sourceIndex] == targetID,
                  target["mapping"] is [Any], target["ref_to_alignment"] is [Any],
                  target["row_ids"] is [String], target["rows"] is [[String]],
                  try integer(target, "reference_length", minimum: 1) == (try string(target, "reference_sequence")).count else {
                throw invalid("Catalogue target identity or source mapping is inconsistent.")
            }
        }
        guard Set(targetSources.keys) == Set(0..<inputCount), targetSources == mappedTargets else {
            throw invalid("Catalogue source mapping is not a strict input-to-target bijection.")
        }
        for candidate in candidates {
            let forwardIDs = try strings(candidate, "forward_oligo_ids")
            let reverseIDs = try strings(candidate, "reverse_oligo_ids")
            let forwardSequences = forwardIDs.compactMap { oligoSequences[$0] }
            let reverseSequences = reverseIDs.compactMap { oligoSequences[$0] }
            guard targetIDs.contains(try string(candidate, "target_id")),
                  Set(forwardIDs).count == forwardIDs.count, Set(reverseIDs).count == reverseIDs.count,
                  Set(forwardSequences).count == forwardSequences.count,
                  Set(reverseSequences).count == reverseSequences.count,
                  Set(forwardIDs).isSubset(of: oligoIDs), Set(reverseIDs).isSubset(of: oligoIDs) else {
                throw invalid("Catalogue candidate references an unknown target or oligo.")
            }
            _ = try interval(candidate["full_interval"], "candidate full interval")
            _ = try interval(candidate["interior_interval"], "candidate interior interval")
        }

        let optimizerPath = output.appendingPathComponent("panel-optimizer.json")
        let validationPath = output.appendingPathComponent("panel-validation.json")
        let provenancePath = output.appendingPathComponent("panel-provenance.json")
        let optimizer = try readObject(optimizerPath, "optimizer")
        let validation = try readObject(validationPath, "validation")
        let provenance = try readObject(provenancePath, "native provenance")
        let optimizerDescriptor = try object(integration["optimizer"], "optimizer descriptor")
        try expect(try safeRelativePath(optimizerDescriptor["path"], "optimizer path"), "panel-optimizer.json", "optimizer path")
        try expect(try string(optimizerDescriptor, "schemaVersion"), optimizerSchema, "optimizer descriptor schema")
        guard equalJSON(try object(integration["publication"], "integration publication"),
                        try object(optimizer["publication"], "optimizer publication")) else {
            throw invalid("Integration publication metadata differs from the native optimizer artifact.")
        }
        try validateOptimizer(optimizer, options: options, profile: expectedProfile,
                              catalog: catalogDescriptor, candidateCount: candidates.count,
                              targetCount: targets.count)
        try validateValidation(validation, options: options, profile: expectedProfile,
                               digest: try string(catalogDescriptor, "semanticDigest"))
        let embeddedValidation = try object(optimizer["validation"], "optimizer validation")
        guard equalJSON(embeddedValidation, validation),
              try bool(try object(integration["validation"], "validation descriptor"), "valid"),
              try string(try object(integration["validation"], "validation descriptor"), "schemaVersion") == validationSchema,
              try safeRelativePath(try object(integration["validation"], "validation descriptor")["path"], "validation path") == "panel-validation.json" else {
            throw invalid("Independent validation does not match the optimizer and integration records.")
        }
        let assignments = try objectArray(optimizer["assignments"], "optimizer assignments")
        guard equalJSON(assignments, try objectArray(validation["assignments"], "validation assignments")) else {
            throw invalid("Optimizer and independent validation assignments differ.")
        }
        try validateTargetMetadata(optimizer: optimizer, validation: validation, targets: targets,
                                   candidates: candidates, assignments: assignments, options: options)
        try validatePublication(try object(optimizer["publication"], "publication"), assignments: assignments,
                                targets: targets, candidates: candidates, candidateIDs: candidateIDs,
                                oligoSequences: oligoSequences, output: output, poolCount: options.poolCount)
        try validateProvenance(provenance, configuration: configuration, capabilities: capabilities,
                               options: options, profile: expectedProfile, catalog: catalogDescriptor,
                               output: output, inputCount: inputCount, executedArgv: executedArgv)
    }

    static func object(_ value: Any?, _ label: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw invalid("\(label) is missing or malformed.") }
        return value
    }

    static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw invalid("\(key) is missing or malformed.") }
        return value
    }

    static func nonemptyString(_ object: [String: Any], _ key: String) throws -> String {
        let value = try string(object, key)
        guard !value.isEmpty else { throw invalid("\(key) must not be empty.") }
        return value
    }

    static func strings(_ object: [String: Any], _ key: String) throws -> [String] {
        guard let values = object[key] as? [String], !values.isEmpty else { throw invalid("\(key) is missing or malformed.") }
        return values
    }

    static func bool(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw invalid("\(key) is missing or malformed.")
        }
        return number.boolValue
    }

    static func integer(_ object: [String: Any], _ key: String, minimum: Int? = nil) throws -> Int {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int.min), number.doubleValue <= Double(Int.max) else {
            throw invalid("\(key) is missing or is not an integer.")
        }
        let value = number.intValue
        if let minimum, value < minimum { throw invalid("\(key) is outside its valid range.") }
        return value
    }

    static func number(_ object: [String: Any], _ key: String) throws -> Double {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { throw invalid("\(key) is missing or is not finite numeric data.") }
        return number.doubleValue
    }

    static func optionalInteger(_ object: [String: Any], _ key: String) throws -> Int? {
        if object[key] is NSNull { return nil }
        return try integer(object, key)
    }

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        guard actual == expected else { throw invalid("Native \(label) does not match the requested contract.") }
    }

    static func equalJSON(_ lhs: Any, _ rhs: Any) -> Bool {
        if lhs is NSNull || rhs is NSNull { return lhs is NSNull && rhs is NSNull }
        if let left = lhs as? NSNumber, let right = rhs as? NSNumber {
            let leftIsBoolean = CFGetTypeID(left) == CFBooleanGetTypeID()
            let rightIsBoolean = CFGetTypeID(right) == CFBooleanGetTypeID()
            guard leftIsBoolean == rightIsBoolean else { return false }
            return leftIsBoolean ? left.boolValue == right.boolValue : left.compare(right) == .orderedSame
        }
        if let left = lhs as? String, let right = rhs as? String { return left == right }
        if let left = lhs as? [Any], let right = rhs as? [Any] {
            return left.count == right.count && zip(left, right).allSatisfy { equalJSON($0, $1) }
        }
        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
            guard Set(left.keys) == Set(right.keys) else { return false }
            return left.allSatisfy { key, value in right[key].map { equalJSON(value, $0) } == true }
        }
        return false
    }

    static func safeRelativePath(_ value: Any?, _ label: String) throws -> String {
        guard let path = value as? String, !path.isEmpty, !path.hasPrefix("/") else {
            throw invalid("\(label) is not a safe relative path.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw invalid("\(label) is not a safe relative path.")
        }
        return path
    }

    static func requireDigest(_ object: [String: Any], _ key: String) throws {
        let digest = try string(object, key)
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { throw invalid("\(key) is not a SHA-256 digest.") }
    }

    static func requireDescriptor(_ value: Any?, _ label: String, relative: Bool) throws {
        let descriptor = try object(value, label)
        let path = try nonemptyString(descriptor, "path")
        if relative { _ = try safeRelativePath(path, "\(label) path") }
        else if !path.hasPrefix("/") { throw invalid("\(label) path must be absolute.") }
        try requireDigest(descriptor, "sha256")
        _ = try integer(descriptor, "size", minimum: 0)
    }

    static func requireDescriptors(_ value: Any?, _ label: String, relative: Bool) throws {
        guard let descriptors = value as? [[String: Any]], !descriptors.isEmpty else { throw invalid("\(label) are missing.") }
        for descriptor in descriptors { try requireDescriptor(descriptor, label, relative: relative) }
    }

    private static func profile(for options: PrimalScheme3DesignOptions) -> [String: Any] {
        let primerMinimum = options.highGC ? 17 : 19
        return ["name": "panel-v1", "specificity_revision": "intended-sites-v1",
            "reference_coordinates": "zero-based-half-open",
            "product_coordinates": "ungapped-row-full-footprint-half-open",
            "product_bound": "0 < length <= mismatch_product_size; plus_end <= minus_start",
            "mismatch_policy": "exact-or-single-substitution",
            "ambiguity_policy": "non-N-IUPAC-compatible-uncertain; N/missing-unknown-no-support",
            "specificity_scope": "all-supplied-MSA-rows-and-occurrences",
            "allowed_secondary_product_policy": "ordered-disjoint-intended-sites",
            "amplicon_size": options.ampliconSize, "amplicon_size_min": options.ampliconSizeMinimum,
            "amplicon_size_max": options.ampliconSizeMaximum, "n_pools": options.poolCount,
            "max_amplicons": options.maxAmplicons.map { $0 as Any } ?? NSNull(),
            "max_amplicons_msa": options.maxAmpliconsPerMSA.map { $0 as Any } ?? NSNull(),
            "mismatch_product_size": options.misprimingProductSize, "mismatch_kmersize": primerMinimum,
            "mismatch_fuzzy": true,
            "thermochemistry": ["dimer_score": options.dimerScore, "dna_conc": 15.0,
                "dntp_conc": 0.8, "dv_conc": 2.0, "mv_conc": 100.0,
                "effective_tm_upper_offset": 2, "primer_annealing_prop": NSNull(),
                "primer_annealing_tempc": 65, "primer_gc_max": options.highGC ? 65 : 55,
                "primer_gc_min": options.highGC ? 40 : 30, "primer_hairpin_th_max": 51,
                "primer_homopolymer_max": 5, "primer_size_max": options.highGC ? 30 : 36,
                "primer_size_min": primerMinimum, "primer_tm_max": 62.5,
                "primer_tm_min": 59.5, "use_annealing": false]]
    }

    private static func validateCatalogResolved(_ value: [String: Any], options: PrimalScheme3DesignOptions) throws {
        for (key, expected) in [("mapping", "first"),
                                ("amplicon_size_metric", "reference-span"),
                                ("terminal_gap_policy", options.terminalGapPolicy.rawValue)] {
            try expect(try string(value, key), expected, "catalogue \(key)")
        }
        for (key, expected) in [("amplicon_size", options.ampliconSize),
                                ("amplicon_size_min", options.ampliconSizeMinimum),
                                ("amplicon_size_max", options.ampliconSizeMaximum),
                                ("n_pools", options.poolCount), ("ncores", options.coreCount),
                                ("mismatch_product_size", options.misprimingProductSize)] {
            try expect(try integer(value, key), expected, "catalogue \(key)")
        }
        try expect(try bool(value, "high_gc"), options.highGC, "catalogue high_gc")
        try expect(try number(value, "min_base_freq"), options.minimumBaseFrequency, "catalogue min_base_freq")
        try expect(try number(value, "dimer_score"), options.dimerScore, "catalogue dimer_score")
        try expect(try bool(value, "use_matchdb"), true, "catalogue use_matchdb")
    }

    private static func validateOptimizer(_ optimizer: [String: Any], options: PrimalScheme3DesignOptions,
                                          profile: [String: Any], catalog: [String: Any],
                                          candidateCount: Int, targetCount: Int) throws {
        try expect(try string(optimizer, "schemaVersion"), optimizerSchema, "optimizer schema")
        try expect(try string(optimizer, "algorithm"), algorithm, "optimizer algorithm")
        guard equalJSON(try object(optimizer["options"], "optimizer options"), [
            "metric": options.coverageMetric.rawValue, "coverage_target": options.coverageTarget,
            "seed": options.optimizerSeed, "starts": options.optimizerStarts,
            "repair_rounds": options.optimizerRepairRounds, "time_limit": options.optimizerTimeLimit]),
              equalJSON(try object(optimizer["profile"], "optimizer profile"), profile),
              equalJSON(try object(optimizer["catalog"], "optimizer catalogue"), catalog) else {
            throw invalid("Optimizer options, profile, or catalogue descriptor do not match the request.")
        }
        try expect(try integer(optimizer, "catalogue_candidates", minimum: 0), candidateCount, "optimizer candidate count")
        try expect(try integer(optimizer, "catalogue_targets", minimum: 0), targetCount, "optimizer target count")
        try expect(try string(optimizer, "catalog_semantic_digest"), try string(catalog, "semanticDigest"), "optimizer catalogue digest")
        let required = ["objective_version", "objective_terms", "objective_direction", "tie_break", "search_limits",
            "completed_starts", "completed_repair_rounds", "repairs_accepted", "work", "stop_reason",
            "objective_history", "baseline", "baseline_objective", "final_objective", "per_target",
            "validation", "oracle_counters", "phase_seconds", "limitations", "assignments", "publication"]
        guard required.allSatisfy({ optimizer[$0] != nil }) else { throw invalid("Optimizer telemetry is incomplete.") }
        _ = try integer(optimizer, "completed_starts", minimum: 0)
        _ = try integer(optimizer, "completed_repair_rounds", minimum: 0)
        _ = try integer(optimizer, "repairs_accepted", minimum: 0)
        for key in ["search_limits", "work", "baseline", "per_target", "oracle_counters", "phase_seconds"] {
            _ = try object(optimizer[key], "optimizer \(key)")
        }
        for key in ["objective_terms", "objective_history", "baseline_objective",
                    "final_objective", "limitations"] where !(optimizer[key] is [Any]) {
            throw invalid("Optimizer \(key) is malformed.")
        }
    }

    private static func validateValidation(_ validation: [String: Any], options: PrimalScheme3DesignOptions,
                                           profile: [String: Any], digest: String) throws {
        let expectedKeys: Set<String> = ["allowed_secondary_products", "assignments", "catalog_semantic_digest",
            "counters", "coverage_target", "limitations", "metric", "per_target", "profile", "schemaVersion",
            "support_diagnostics", "valid", "violations"]
        guard Set(validation.keys) == expectedKeys else {
            throw invalid("Independent validation keys are incomplete or unexpected.")
        }
        try expect(try string(validation, "schemaVersion"), validationSchema, "validation schema")
        guard try bool(validation, "valid"), let violations = validation["violations"] as? [Any], violations.isEmpty else {
            throw invalid("Independent panel validation failed or contains violations.")
        }
        try expect(try string(validation, "metric"), options.coverageMetric.rawValue, "validation metric")
        try expect(try number(validation, "coverage_target"), options.coverageTarget, "validation coverage target")
        try expect(try string(validation, "catalog_semantic_digest"), digest, "validation catalogue digest")
        guard equalJSON(try object(validation["profile"], "validation profile"), profile),
              validation["assignments"] is [[String: Any]], validation["per_target"] is [String: Any],
              validation["support_diagnostics"] is [String: Any], validation["allowed_secondary_products"] is [[String: Any]],
              validation["counters"] is [String: Any], validation["limitations"] is [Any] else {
            throw invalid("Independent validation records are incomplete or malformed.")
        }
    }

    private static func validateTargetMetadata(optimizer: [String: Any], validation: [String: Any],
                                               targets: [[String: Any]], candidates: [[String: Any]],
                                               assignments: [[String: Any]], options: PrimalScheme3DesignOptions) throws {
        let targetByID = Dictionary(uniqueKeysWithValues: try targets.map { (try string($0, "id"), $0) })
        let candidateByID = Dictionary(uniqueKeysWithValues: try candidates.map { (try string($0, "id"), $0) })
        let targetIDs = Set(targetByID.keys)
        let validationSummaries = try object(validation["per_target"], "validation per_target")
        let optimizerSummaries = try object(optimizer["per_target"], "optimizer per_target")
        guard Set(validationSummaries.keys) == targetIDs, Set(optimizerSummaries.keys) == targetIDs else {
            throw invalid("Validation and optimizer target summaries do not exactly match catalogue targets.")
        }

        var selectedByTarget: [String: [[String: Any]]] = Dictionary(uniqueKeysWithValues: targetIDs.map { ($0, []) })
        var selectedIDs: [String] = []
        for assignment in assignments {
            guard Set(assignment.keys) == ["candidate_id", "pool"] else {
                throw invalid("Optimizer assignment keys are incomplete or unexpected.")
            }
            let candidateID = try nonemptyString(assignment, "candidate_id")
            guard let candidate = candidateByID[candidateID] else {
                throw invalid("Optimizer assignment references an unknown candidate.")
            }
            let targetID = try string(candidate, "target_id")
            selectedByTarget[targetID, default: []].append(candidate)
            selectedIDs.append(candidateID)
        }
        guard Set(selectedIDs).count == selectedIDs.count else {
            throw invalid("Optimizer assignments contain duplicate candidates.")
        }

        let support = try object(validation["support_diagnostics"], "validation support_diagnostics")
        guard Set(support.keys) == Set(selectedIDs) else {
            throw invalid("Validation support diagnostics do not exactly match selected candidates.")
        }
        for candidateID in selectedIDs {
            guard let candidate = candidateByID[candidateID] else { throw invalid("Selected candidate is missing.") }
            let diagnostic = try object(support[candidateID], "support diagnostic")
            let supportKeys: Set<String> = ["joint_rows", "row_product_spans", "unknown_rows"]
            guard Set(diagnostic.keys) == supportKeys else {
                throw invalid("Validation support diagnostic keys are incomplete or unexpected.")
            }
            let candidateSupport = try validateCandidateSupport(candidate,
                target: try object(targetByID[try string(candidate, "target_id")], "support target"))
            let freshJoint = try stringArray(diagnostic["joint_rows"], "validation joint rows")
            let freshUnknown = try stringArray(diagnostic["unknown_rows"], "validation unknown rows")
            let freshSpans = try rowProductSpans(diagnostic["row_product_spans"],
                knownRows: candidateSupport.knownRows, label: "validation support row-product spans")
            guard let freshJointValue = diagnostic["joint_rows"], let candidateJointValue = candidate["joint_rows"],
                  let freshSpanValue = diagnostic["row_product_spans"], let candidateSpanValue = candidate["row_product_spans"],
                  Set(freshJoint).count == freshJoint.count,
                  Set(freshUnknown).count == freshUnknown.count,
                  Set(freshJoint).isSubset(of: candidateSupport.knownRows),
                  Set(freshUnknown).isSubset(of: candidateSupport.knownRows),
                  Set(freshSpans).count == freshSpans.count,
                  equalJSON(freshJointValue, candidateJointValue),
                  equalJSON(freshSpanValue, candidateSpanValue),
                  Set(freshUnknown).subtracting(Set(freshJoint)) == candidateSupport.unknownRows else {
                throw invalid("Validation support diagnostic differs from the selected catalogue candidate.")
            }
        }

        let validationKeys: Set<String> = ["coverage_fraction", "full", "interior", "normalized_shortfall",
            "reference_length", "selected_count", "shortfall", "target_met"]
        let optimizerKeys: Set<String> = ["coverage_fraction", "covered_bases", "intervals", "normalized_shortfall",
            "reference_length", "selected_count"]
        for targetID in targetIDs {
            let target = try object(targetByID[targetID], "catalogue target")
            let referenceLength = try integer(target, "reference_length", minimum: 1)
            let validationSummary = try object(validationSummaries[targetID], "validation target summary")
            let optimizerSummary = try object(optimizerSummaries[targetID], "optimizer target summary")
            guard Set(validationSummary.keys) == validationKeys, Set(optimizerSummary.keys) == optimizerKeys else {
                throw invalid("Validation or optimizer target summary keys are incomplete or unexpected.")
            }
            let selected = selectedByTarget[targetID] ?? []
            let fullIntervals = try mergedIntervals(selected.map { try interval($0["full_interval"], "selected full interval") },
                                                    referenceLength: referenceLength)
            let interiorIntervals = try mergedIntervals(selected.map { try interval($0["interior_interval"], "selected interior interval") },
                                                        referenceLength: referenceLength)
            let full = try object(validationSummary["full"], "validation full metric")
            let interior = try object(validationSummary["interior"], "validation interior metric")
            try validateMetricSummary(full, expectedIntervals: fullIntervals, referenceLength: referenceLength,
                                      label: "validation full metric")
            try validateMetricSummary(interior, expectedIntervals: interiorIntervals, referenceLength: referenceLength,
                                      label: "validation interior metric")
            let active = options.coverageMetric == .fullSpan ? full : interior
            let activeFraction = try number(active, "fraction")
            let shortfall = max(0, options.coverageTarget - activeFraction)
            let normalizedShortfall = options.coverageTarget > 0 ? shortfall / options.coverageTarget : 0
            guard try integer(validationSummary, "reference_length", minimum: 1) == referenceLength,
                  try integer(validationSummary, "selected_count", minimum: 0) == selected.count,
                  approximatelyEqual(try number(validationSummary, "coverage_fraction"), activeFraction),
                  approximatelyEqual(try number(validationSummary, "shortfall"), shortfall),
                  approximatelyEqual(try number(validationSummary, "normalized_shortfall"), normalizedShortfall),
                  try bool(validationSummary, "target_met") == (activeFraction >= options.coverageTarget) else {
                throw invalid("Validation target summary is inconsistent with selected catalogue intervals.")
            }
            guard try integer(optimizerSummary, "reference_length", minimum: 1) == referenceLength,
                  try integer(optimizerSummary, "selected_count", minimum: 0) == selected.count,
                  try integer(optimizerSummary, "covered_bases", minimum: 0) == (try integer(active, "covered_bases", minimum: 0)),
                  try intervalList(optimizerSummary["intervals"], "optimizer target intervals") ==
                    intervalList(active["intervals"], "validation active intervals"),
                  approximatelyEqual(try number(optimizerSummary, "coverage_fraction"), activeFraction),
                  approximatelyEqual(try number(optimizerSummary, "normalized_shortfall"), normalizedShortfall) else {
                throw invalid("Optimizer target summary is inconsistent with independent validation.")
            }
        }
    }

    private struct CandidateSupportIdentity {
        let knownRows: Set<String>
        let unknownRows: Set<String>
    }

    private struct RowProductSpan: Hashable {
        let row: String
        let start: Int
        let end: Int
    }

    private static func validateCandidateSupport(_ candidate: [String: Any],
                                                 target: [String: Any]) throws -> CandidateSupportIdentity {
        let rowIDs = try stringArray(target["row_ids"], "catalogue target row identifiers")
        let knownRows = Set(rowIDs)
        let jointRows = try stringArray(candidate["joint_rows"], "candidate joint rows")
        let unknownRows = try stringArray(candidate["unknown_rows"], "candidate unknown rows")
        let spans = try rowProductSpans(candidate["row_product_spans"], knownRows: knownRows,
                                        label: "catalogue candidate row-product spans")
        guard knownRows.count == rowIDs.count,
              Set(jointRows).count == jointRows.count, Set(unknownRows).count == unknownRows.count,
              Set(jointRows).isSubset(of: knownRows), Set(unknownRows).isSubset(of: knownRows),
              Set(jointRows).isDisjoint(with: Set(unknownRows)),
              Set(spans).count == spans.count, Set(spans.map(\.row)) == Set(jointRows) else {
            throw invalid("Catalogue candidate support metadata is malformed.")
        }
        return .init(knownRows: knownRows, unknownRows: Set(unknownRows))
    }

    private static func rowProductSpans(_ value: Any?, knownRows: Set<String>,
                                        label: String) throws -> [RowProductSpan] {
        guard let values = value as? [[Any]] else { throw invalid("\(label) is missing or malformed.") }
        return try values.map { span in
            guard span.count == 3, let row = span[0] as? String, knownRows.contains(row),
                  let start = strictInteger(span[1]), let end = strictInteger(span[2]), start >= 0, end > start else {
                throw invalid("\(label) contains a malformed entry.")
            }
            return .init(row: row, start: start, end: end)
        }
    }

    private static func validateMetricSummary(_ summary: [String: Any], expectedIntervals: [[Int]],
                                              referenceLength: Int, label: String) throws {
        guard Set(summary.keys) == ["covered_bases", "fraction", "intervals"] else {
            throw invalid("\(label) keys are incomplete or unexpected.")
        }
        let covered = expectedIntervals.reduce(0) { $0 + $1[1] - $1[0] }
        let fraction = Double(covered) / Double(referenceLength)
        guard try intervalList(summary["intervals"], "\(label) intervals") == expectedIntervals,
              try integer(summary, "covered_bases", minimum: 0) == covered,
              approximatelyEqual(try number(summary, "fraction"), fraction) else {
            throw invalid("\(label) is inconsistent with selected catalogue intervals.")
        }
    }

    private static func mergedIntervals(_ intervals: [[Int]], referenceLength: Int) throws -> [[Int]] {
        guard intervals.allSatisfy({ $0.count == 2 && $0[0] >= 0 && $0[1] <= referenceLength && $0[1] > $0[0] }) else {
            throw invalid("A selected candidate interval exceeds its catalogue reference.")
        }
        var merged: [[Int]] = []
        for current in intervals.sorted(by: { $0[0] == $1[0] ? $0[1] < $1[1] : $0[0] < $1[0] }) {
            if let last = merged.last, current[0] <= last[1] {
                merged[merged.count - 1][1] = max(last[1], current[1])
            } else { merged.append(current) }
        }
        return merged
    }

    private static func intervalList(_ value: Any?, _ label: String) throws -> [[Int]] {
        guard let values = value as? [[Any]] else { throw invalid("\(label) is missing or malformed.") }
        return try values.map { try interval($0, label) }
    }

    private static func stringArray(_ value: Any?, _ label: String) throws -> [String] {
        guard let values = value as? [String], values.allSatisfy({ !$0.isEmpty }) else {
            throw invalid("\(label) is missing or malformed.")
        }
        return values
    }

    private static func strictInteger(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int.min), number.doubleValue <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= 1e-12
    }

    private static func validatePublication(_ publication: [String: Any], assignments: [[String: Any]],
                                            targets: [[String: Any]], candidates: [[String: Any]],
                                            candidateIDs: Set<String>, oligoSequences: [String: String],
                                            output: URL, poolCount: Int) throws {
        try expect(try string(publication, "projection"), "ungapped-first-reference-coordinates", "publication projection")
        guard let targetMap = publication["targetToReference"] as? [String: String],
              Set(targetMap.keys) == Set(try targets.map { try string($0, "id") }),
              Set(targetMap.values).count == targetMap.count,
              let candidateMap = publication["candidateToAmplicon"] as? [String: String] else {
            throw invalid("Publication target or candidate mapping is malformed.")
        }
        var selected: [String] = [], pools: [String: Int] = [:]
        for assignment in assignments {
            let candidate = try string(assignment, "candidate_id"), pool = try integer(assignment, "pool", minimum: 0)
            guard pool < poolCount, candidateIDs.contains(candidate) else { throw invalid("Assignment references an invalid candidate or pool.") }
            selected.append(candidate); pools[candidate] = pool
        }
        guard Set(selected).count == selected.count, Set(candidateMap.keys) == Set(selected),
              Set(candidateMap.values).count == candidateMap.count else { throw invalid("Selected candidate publication mapping is inconsistent.") }
        let artifacts = try object(publication["artifacts"], "publication artifacts")
        let expectedArtifacts = ["primerBed": "primer.bed", "ampliconBed": "amplicon.bed",
            "primerTrimmedAmpliconBed": "primertrim.amplicon.bed", "referenceFasta": "reference.fasta",
            "plot": "plot.html", "mismatchPlot": "primer.html", "plotData": "work/plotdata.json.gz",
            "thermoPlot": "work/primer_thermo.html"]
        for (key, path) in expectedArtifacts {
            try expect(try safeRelativePath(artifacts[key], "publication \(key)"), path, "publication \(key)")
            _ = try containedFile(output, artifacts[key], "publication \(key)")
        }
        let candidateByID = Dictionary(uniqueKeysWithValues: try candidates.map { (try string($0, "id"), $0) })
        let references = try referenceRecords(output.appendingPathComponent("reference.fasta"))
        let referenceSequences = Dictionary(uniqueKeysWithValues: references.map { ($0.title, $0.sequence) })
        guard referenceSequences.keys.sorted() == targetMap.values.sorted() else {
            throw invalid("Published reference FASTA does not match targetToReference.")
        }
        for target in targets {
            let expectedSequence = try string(target, "reference_sequence")
            guard let reference = targetMap[try string(target, "id")],
                  referenceSequences[reference] == expectedSequence else {
                throw invalid("Published reference FASTA sequence differs from the catalogue target.")
            }
        }
        let fullBED = try bedRecords(output.appendingPathComponent("amplicon.bed"))
        let trimmedBED = try bedRecords(output.appendingPathComponent("primertrim.amplicon.bed"))
        let primerBED = try bedRecords(output.appendingPathComponent("primer.bed"))
        let expectedPrimerRows = try selected.reduce(into: 0) { count, candidateID in
            guard let candidate = candidateByID[candidateID] else { throw invalid("Selected candidate is absent from the catalogue.") }
            count += try strings(candidate, "forward_oligo_ids").count
            count += try strings(candidate, "reverse_oligo_ids").count
        }
        guard fullBED.count == selected.count, trimmedBED.count == selected.count,
              primerBED.count == expectedPrimerRows, Set(primerBED.map(\.name)).count == primerBED.count else {
            throw invalid("Published BED row counts do not match the selected assignments.")
        }
        for candidateID in selected {
            guard let candidate = candidateByID[candidateID], let name = candidateMap[candidateID], let pool = pools[candidateID],
                  let reference = targetMap[try string(candidate, "target_id")] else {
                throw invalid("Published candidate mapping is incomplete.")
            }
            let fullInterval = try interval(candidate["full_interval"], "full")
            let interiorInterval = try interval(candidate["interior_interval"], "interior")
            let forwardIDs = try strings(candidate, "forward_oligo_ids")
            let reverseIDs = try strings(candidate, "reverse_oligo_ids")
            var expectedPrimers: [BEDRecord] = []
            for (index, oligoID) in forwardIDs.enumerated() {
                guard let sequence = oligoSequences[oligoID] else { throw invalid("Selected forward oligo is absent from the catalogue.") }
                expectedPrimers.append(.init(reference: reference, name: "\(name)_LEFT_\(index + 1)",
                    start: interiorInterval[0] - sequence.count, end: interiorInterval[0], pool: pool + 1,
                    strand: "+", sequence: sequence))
            }
            for (index, oligoID) in reverseIDs.enumerated() {
                guard let sequence = oligoSequences[oligoID] else { throw invalid("Selected reverse oligo is absent from the catalogue.") }
                expectedPrimers.append(.init(reference: reference, name: "\(name)_RIGHT_\(index + 1)",
                    start: interiorInterval[1], end: interiorInterval[1] + sequence.count, pool: pool + 1,
                    strand: "-", sequence: sequence))
            }
            let candidatePrimers = primerBED.filter { $0.name.hasPrefix(name + "_") }
            guard fullBED.contains(where: { $0.name == name && $0.reference == reference && [$0.start, $0.end] == fullInterval && $0.pool == pool + 1 }),
                  trimmedBED.contains(where: { $0.name == name && $0.reference == reference && [$0.start, $0.end] == interiorInterval && $0.pool == pool + 1 }),
                  candidatePrimers.count == expectedPrimers.count,
                  Set(candidatePrimers) == Set(expectedPrimers) else {
                throw invalid("Published primer BED identity, coordinates, strand, sequence, or pool differs from the catalogue.")
            }
        }
    }

    private static func validateProvenance(_ provenance: [String: Any], configuration: [String: Any],
                                           capabilities: PrimalScheme3CoverageCapabilities,
                                           options: PrimalScheme3DesignOptions, profile: [String: Any],
                                           catalog: [String: Any], output: URL, inputCount: Int,
                                           executedArgv: [String]) throws {
        try expect(try string(provenance, "schemaVersion"), provenanceSchema, "native provenance schema")
        try expect(try string(provenance, "tool"), "primalscheme3 panel-create", "native provenance tool")
        try expect(try string(provenance, "toolVersion"), PrimalScheme3DesignPipeline.coverageToolVersion, "native provenance version")
        guard equalJSON(try object(provenance["resolvedOptions"], "provenance resolved options"), configuration),
              equalJSON(try object(provenance["source"], "provenance source"), capabilities.source),
              equalJSON(try object(provenance["sourceAtEnd"], "provenance end source"), capabilities.source),
              equalJSON(try object(provenance["runtime"], "provenance runtime"), capabilities.runtime),
              equalJSON(try object(provenance["runtimeAtEnd"], "provenance end runtime"), capabilities.runtime),
              try bool(provenance, "sourceChangedDuringRun") == false,
              try bool(provenance, "runtimeChangedDuringRun") == false,
              try string(provenance, "status") == "success", try integer(provenance, "exitStatus") == 0 else {
            throw invalid("Native provenance identity, resolved options, or completion status is inconsistent.")
        }
        let command = try object(provenance["command"], "provenance command")
        guard let nativeArgv = command["argv"] as? [String], nativeArgv == executedArgv,
              !(try nonemptyString(command, "shell")).isEmpty,
              !(try nonemptyString(command, "workingDirectory")).isEmpty else {
            throw invalid("Native provenance command does not match the executed argv.")
        }
        let msaPaths = executedArgv.enumerated().compactMap { $0.element == "--msa" && $0.offset + 1 < executedArgv.count ? executedArgv[$0.offset + 1] : nil }
        let inputs = try objectArray(provenance["inputs"], "provenance inputs")
        guard inputs.count == inputCount, msaPaths.count == inputCount else {
            throw invalid("Native provenance input count differs from the supplied inputs.")
        }
        for (index, input) in inputs.enumerated() {
            try expect(try integer(input, "sourceIndex", minimum: 0), index, "native input order")
            try expect(try string(input, "sourcePath"), msaPaths[index], "native input source path")
            let stored = try containedFile(output, input["storedPath"], "stored native input")
            let consumed = URL(fileURLWithPath: msaPaths[index]).standardizedFileURL.resolvingSymlinksInPath()
            let consumedValues = try consumed.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard consumedValues.isRegularFile == true, consumedValues.isSymbolicLink != true else {
                throw invalid("Executed native input is not a regular file.")
            }
            let storedHash = try ProvenanceFileHasher.sha256(of: stored)
            let storedSize = Int(try ProvenanceFileHasher.fileSize(of: stored))
            try expect(try string(input, "sha256"), storedHash, "stored input hash")
            try expect(try integer(input, "size", minimum: 0), storedSize, "stored input size")
            try expect(try ProvenanceFileHasher.sha256(of: consumed), storedHash, "consumed input hash")
            try expect(Int(try ProvenanceFileHasher.fileSize(of: consumed)), storedSize, "consumed input size")
            try expect(try string(input, "sourceAtStartSha256"), try string(input, "sha256"), "input start hash")
            try expect(try integer(input, "sourceAtStartSize", minimum: 0), try integer(input, "size"), "input start size")
            try expect(try string(input, "sourceAtEndSha256"), try string(input, "sha256"), "input end hash")
            try expect(try integer(input, "sourceAtEndSize", minimum: 0), try integer(input, "size"), "input end size")
            guard try bool(input, "storedMissing") == false, try bool(input, "sourceAtStartMatchesStored"),
                  try bool(input, "sourceChangedDuringRun") == false else { throw invalid("Native input provenance reports missing or changed data.") }
        }
        let outputs = try objectArray(provenance["outputs"], "provenance outputs")
        var outputPaths = Set<String>()
        for descriptor in outputs {
            let path = try safeRelativePath(descriptor["path"], "native output descriptor")
            guard path != "panel-provenance.json", outputPaths.insert(path).inserted else { throw invalid("Native provenance output paths are duplicated or self-referential.") }
            let file = try containedFile(output, path, "native provenance output")
            try expect(try string(descriptor, "sha256"), try ProvenanceFileHasher.sha256(of: file), "native output hash")
            try expect(try integer(descriptor, "size", minimum: 0), Int(try ProvenanceFileHasher.fileSize(of: file)), "native output size")
        }
        let actual = try regularRelativeFiles(output).subtracting(["panel-provenance.json"])
        guard outputPaths == actual else { throw invalid("Native provenance output inventory is incomplete.") }
        let scientific = try object(provenance["scientific"], "provenance scientific record")
        try expect(try string(scientific, "algorithm"), algorithm, "scientific algorithm")
        try expect(try string(scientific, "optimizerSchemaVersion"), optimizerSchema, "scientific optimizer schema")
        try expect(try string(scientific, "metric"), options.coverageMetric.rawValue, "scientific metric")
        try expect(try number(scientific, "coverageTarget"), options.coverageTarget, "scientific coverage target")
        try expect(try integer(scientific, "seed"), options.optimizerSeed, "scientific seed")
        try expect(try string(scientific, "catalogSemanticDigest"), try string(catalog, "semanticDigest"), "scientific catalogue digest")
        try expect(try string(scientific, "catalogFileSha256"), try string(catalog, "fileSha256"), "scientific catalogue file hash")
        guard equalJSON(try object(scientific["profile"], "scientific profile"), profile),
              try bool(scientific, "validationValid") else { throw invalid("Scientific provenance profile or validation status is inconsistent.") }
        let budgets = try object(scientific["budgets"], "scientific budgets")
        try expect(try integer(budgets, "starts"), options.optimizerStarts, "scientific starts")
        try expect(try integer(budgets, "repairRounds"), options.optimizerRepairRounds, "scientific repair rounds")
        try expect(try number(budgets, "timeLimit"), options.optimizerTimeLimit, "scientific time limit")
    }

    private struct ReferenceRecord {
        let title: String, sequence: String
    }

    private static func referenceRecords(_ url: URL) throws -> [ReferenceRecord] {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) }
        catch { throw invalid("Published reference FASTA is missing or unreadable.") }
        var records: [ReferenceRecord] = [], title: String?, sequence = ""
        func appendRecord() throws {
            guard let title, !title.isEmpty, !sequence.isEmpty else {
                throw invalid("Published reference FASTA contains an empty identifier or sequence.")
            }
            records.append(.init(title: title, sequence: sequence))
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix(">") {
                if title != nil { try appendRecord() }
                title = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                sequence = ""
            } else {
                guard title != nil, !line.isEmpty else { throw invalid("Published reference FASTA is malformed.") }
                sequence += line.uppercased()
            }
        }
        if title != nil { try appendRecord() }
        guard !records.isEmpty else { throw invalid("Published reference FASTA is empty.") }
        let identifiers = records.map(\.title)
        guard Set(identifiers).count == identifiers.count else {
            throw invalid("Published reference FASTA contains duplicate identifiers.")
        }
        let allowed = CharacterSet(charactersIn: "ACGTRYSWKMBDHVN")
        guard records.allSatisfy({ $0.sequence.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw invalid("Published reference FASTA contains unsupported sequence symbols.")
        }
        return records
    }

    private struct BEDRecord: Hashable {
        let reference: String, name: String
        let start: Int, end: Int, pool: Int
        let strand: String?
        let sequence: String?
    }

    private static func bedRecords(_ url: URL) throws -> [BEDRecord] {
        try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }.map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 5, let start = Int(fields[1]), let end = Int(fields[2]), let pool = Int(fields[4]),
                  start >= 0, end > start, pool > 0 else { throw invalid("A published BED row is malformed.") }
            return .init(reference: String(fields[0]), name: String(fields[3]), start: start, end: end,
                         pool: pool, strand: fields.count > 5 ? String(fields[5]) : nil,
                         sequence: fields.count > 6 ? String(fields[6]) : nil)
        }
    }

    private static func interval(_ value: Any?, _ label: String) throws -> [Int] {
        guard let values = value as? [NSNumber], values.count == 2,
              values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.rounded() == $0.doubleValue }),
              values[0].intValue >= 0, values[1].intValue > values[0].intValue else { throw invalid("\(label) is malformed.") }
        return values.map(\.intValue)
    }

    private static func objectArray(_ value: Any?, _ label: String) throws -> [[String: Any]] {
        guard let values = value as? [[String: Any]] else { throw invalid("\(label) is missing or malformed.") }
        return values
    }

    private static func uniqueStrings(_ objects: [[String: Any]], key: String, label: String) throws -> Set<String> {
        let values = try objects.map { try nonemptyString($0, key) }
        guard Set(values).count == values.count else { throw invalid("\(label) identifiers are duplicated.") }
        return Set(values)
    }

    private static func readObject(_ url: URL, _ label: String) throws -> [String: Any] {
        do {
            return try object(try JSONSerialization.jsonObject(with: Data(contentsOf: url)), label)
        } catch let error as PrimalScheme3DesignError {
            throw error
        } catch {
            throw invalid("\(label) is missing or malformed.")
        }
    }

    private static func containedFile(_ root: URL, _ value: Any?, _ label: String) throws -> URL {
        let path = try safeRelativePath(value, "\(label) path")
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(rootPath + "/"),
              try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw invalid("\(label) does not resolve to a contained regular file.")
        }
        return file
    }

    private static func regularRelativeFiles(_ root: URL, prefix: String = "") throws -> Set<String> {
        var result = Set<String>()
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
            let relative = prefix.isEmpty ? child.lastPathComponent : "\(prefix)/\(child.lastPathComponent)"
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw invalid("Symbolic-link native artifacts are unsupported.") }
            if values.isDirectory == true { result.formUnion(try regularRelativeFiles(child, prefix: relative)) }
            else if values.isRegularFile == true { result.insert(relative) }
            else { throw invalid("Unsupported native artifact file type.") }
        }
        return result
    }

    static func invalid(_ message: String) -> PrimalScheme3DesignError { .invalidRequest(message) }
}
