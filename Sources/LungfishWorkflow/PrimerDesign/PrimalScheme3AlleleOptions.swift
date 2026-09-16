import Foundation

public enum PrimalScheme3PhaseScheduling: String, Codable, CaseIterable, Sendable {
    case serial, reserved
}

public struct PrimalScheme3AlleleOptions: Codable, Equatable, Sendable {
    public static let presetName = "allele-balanced-v1"
    public static let workDefaults: [String: Int] = [
        "frontierCandidates": 64,
        "constructionCandidateAttempts": 2_048,
        "repairCandidateProbesPerRound": 128,
        "repairNeighborhoodsPerRound": 256,
        "repairTrialsPerRound": 256,
        "poolLookaheadCandidates": 4,
        "cleanupMovesPerRound": 64,
        "familiesPerRefresh": 16,
    ]

    public let preset: String
    public let candidateProfiles: String
    public let reuseDiscovery: URL?
    public let variantSelection: String
    public let requestedPhaseScheduling: PrimalScheme3PhaseScheduling?
    public var phaseScheduling: PrimalScheme3PhaseScheduling { requestedPhaseScheduling ?? .serial }
    public let alleleWeighting: String
    public let discoveryLengthMode: String
    public let specificityTerminalK: Int
    public let secondaryProductPolicy: String
    public let subsetBeamWidth: Int
    public let subsetExpansionLimit: Int
    public let exchangeWidth: Int
    public let salvage: String
    public let salvageThresholds: [Double]
    public let salvageMaxStages: Int
    public let salvageMaxEdgesPerPool: Int
    public let salvageMaxOligosPerPool: Int
    public let salvageTimeLimit: Double
    public let primaryTier: String
    public let workFrontierCandidates: Int
    public let workConstructionCandidateAttempts: Int
    public let workRepairCandidateProbesPerRound: Int
    public let workRepairNeighborhoodsPerRound: Int
    public let workRepairTrialsPerRound: Int
    public let workPoolLookaheadCandidates: Int
    public let workCleanupMovesPerRound: Int
    public let workFamiliesPerRefresh: Int
    public let requestedOptionNames: Set<String>

    public init(
        preset: String? = nil,
        candidateProfiles: String? = nil,
        reuseDiscovery: URL? = nil,
        variantSelection: String? = nil,
        phaseScheduling: PrimalScheme3PhaseScheduling? = nil,
        alleleWeighting: String? = nil,
        discoveryLengthMode: String? = nil,
        specificityTerminalK: Int? = nil,
        secondaryProductPolicy: String? = nil,
        subsetBeamWidth: Int? = nil,
        subsetExpansionLimit: Int? = nil,
        exchangeWidth: Int? = nil,
        salvage: String? = nil,
        salvageThresholds: [Double]? = nil,
        salvageMaxStages: Int? = nil,
        salvageMaxEdgesPerPool: Int? = nil,
        salvageMaxOligosPerPool: Int? = nil,
        salvageTimeLimit: Double? = nil,
        primaryTier: String? = nil,
        workFrontierCandidates: Int? = nil,
        workConstructionCandidateAttempts: Int? = nil,
        workRepairCandidateProbesPerRound: Int? = nil,
        workRepairNeighborhoodsPerRound: Int? = nil,
        workRepairTrialsPerRound: Int? = nil,
        workPoolLookaheadCandidates: Int? = nil,
        workCleanupMovesPerRound: Int? = nil,
        workFamiliesPerRefresh: Int? = nil
    ) {
        self.preset = preset ?? Self.presetName
        self.candidateProfiles = candidateProfiles ?? "union"
        self.reuseDiscovery = reuseDiscovery
        self.variantSelection = variantSelection ?? "subsets"
        self.requestedPhaseScheduling = phaseScheduling
        self.alleleWeighting = alleleWeighting ?? "distinct-observed"
        self.discoveryLengthMode = discoveryLengthMode ?? "first-compatible"
        self.specificityTerminalK = specificityTerminalK ?? 17
        self.secondaryProductPolicy = secondaryProductPolicy ?? "ordered-disjoint-intended-sites"
        self.subsetBeamWidth = subsetBeamWidth ?? 16
        self.subsetExpansionLimit = subsetExpansionLimit ?? 256
        self.exchangeWidth = exchangeWidth ?? 2
        self.salvage = salvage ?? "off"
        self.salvageMaxStages = salvageMaxStages ?? 3
        self.salvageThresholds = salvageThresholds
            ?? Array([-28, -30, -32].prefix(max(0, min(3, self.salvageMaxStages))))
        self.salvageMaxEdgesPerPool = salvageMaxEdgesPerPool ?? 8
        self.salvageMaxOligosPerPool = salvageMaxOligosPerPool ?? 4
        self.salvageTimeLimit = salvageTimeLimit ?? 60
        self.primaryTier = primaryTier ?? "strict"
        self.workFrontierCandidates = workFrontierCandidates ?? 64
        self.workConstructionCandidateAttempts = workConstructionCandidateAttempts ?? 2_048
        self.workRepairCandidateProbesPerRound = workRepairCandidateProbesPerRound ?? 128
        self.workRepairNeighborhoodsPerRound = workRepairNeighborhoodsPerRound ?? 256
        self.workRepairTrialsPerRound = workRepairTrialsPerRound ?? 256
        self.workPoolLookaheadCandidates = workPoolLookaheadCandidates ?? 4
        self.workCleanupMovesPerRound = workCleanupMovesPerRound ?? 64
        self.workFamiliesPerRefresh = workFamiliesPerRefresh ?? 16
        var requested = Set<String>()
        for (name, supplied) in [
            ("preset", preset != nil), ("candidateProfiles", candidateProfiles != nil),
            ("reuseDiscovery", reuseDiscovery != nil), ("variantSelection", variantSelection != nil),
            ("phaseScheduling", phaseScheduling != nil),
            ("alleleWeighting", alleleWeighting != nil), ("discoveryLengthMode", discoveryLengthMode != nil),
            ("specificityTerminalK", specificityTerminalK != nil),
            ("secondaryProductPolicy", secondaryProductPolicy != nil),
            ("subsetBeamWidth", subsetBeamWidth != nil), ("subsetExpansionLimit", subsetExpansionLimit != nil),
            ("exchangeWidth", exchangeWidth != nil), ("salvage", salvage != nil),
            ("salvageThresholds", salvageThresholds != nil), ("salvageMaxStages", salvageMaxStages != nil),
            ("salvageMaxEdgesPerPool", salvageMaxEdgesPerPool != nil),
            ("salvageMaxOligosPerPool", salvageMaxOligosPerPool != nil),
            ("salvageTimeLimit", salvageTimeLimit != nil), ("primaryTier", primaryTier != nil),
            ("workFrontierCandidates", workFrontierCandidates != nil),
            ("workConstructionCandidateAttempts", workConstructionCandidateAttempts != nil),
            ("workRepairCandidateProbesPerRound", workRepairCandidateProbesPerRound != nil),
            ("workRepairNeighborhoodsPerRound", workRepairNeighborhoodsPerRound != nil),
            ("workRepairTrialsPerRound", workRepairTrialsPerRound != nil),
            ("workPoolLookaheadCandidates", workPoolLookaheadCandidates != nil),
            ("workCleanupMovesPerRound", workCleanupMovesPerRound != nil),
            ("workFamiliesPerRefresh", workFamiliesPerRefresh != nil),
        ] where supplied { requested.insert(name) }
        self.requestedOptionNames = requested
    }

    public var resolvedProvenanceOptions: [String: ParameterValue] {
        [
            "preset": .string(preset), "candidateProfiles": .string(candidateProfiles),
            "reuseDiscovery": reuseDiscovery.map { .string($0.path) } ?? .null,
            "variantSelection": .string(variantSelection), "phaseScheduling": .string(phaseScheduling.rawValue),
            "alleleWeighting": .string(alleleWeighting),
            "discoveryLengthMode": .string(discoveryLengthMode),
            "specificityTerminalK": .integer(specificityTerminalK),
            "secondaryProductPolicy": .string(secondaryProductPolicy),
            "subsetBeamWidth": .integer(subsetBeamWidth), "subsetExpansionLimit": .integer(subsetExpansionLimit),
            "exchangeWidth": .integer(exchangeWidth), "salvage": .string(salvage),
            "salvageThresholds": .array(salvageThresholds.map(ParameterValue.number)),
            "salvageMaxStages": .integer(salvageMaxStages),
            "salvageMaxEdgesPerPool": .integer(salvageMaxEdgesPerPool),
            "salvageMaxOligosPerPool": .integer(salvageMaxOligosPerPool),
            "salvageTimeLimit": .number(salvageTimeLimit), "primaryTier": .string(primaryTier),
            "workFrontierCandidates": .integer(workFrontierCandidates),
            "workConstructionCandidateAttempts": .integer(workConstructionCandidateAttempts),
            "workRepairCandidateProbesPerRound": .integer(workRepairCandidateProbesPerRound),
            "workRepairNeighborhoodsPerRound": .integer(workRepairNeighborhoodsPerRound),
            "workRepairTrialsPerRound": .integer(workRepairTrialsPerRound),
            "workPoolLookaheadCandidates": .integer(workPoolLookaheadCandidates),
            "workCleanupMovesPerRound": .integer(workCleanupMovesPerRound),
            "workFamiliesPerRefresh": .integer(workFamiliesPerRefresh),
        ]
    }

    public var requestedProvenanceOptions: [String: ParameterValue] {
        resolvedProvenanceOptions.filter { requestedOptionNames.contains($0.key) }
    }

    func validate() throws {
        guard preset == Self.presetName,
              ["union", "normal", "high-gc"].contains(candidateProfiles),
              ["subsets", "full-cloud"].contains(variantSelection),
              alleleWeighting == "distinct-observed",
              ["first-compatible", "all"].contains(discoveryLengthMode),
              ["ordered-disjoint-intended-sites", "reject-secondary-products/v1"].contains(secondaryProductPolicy),
              ["off", "bounded"].contains(salvage), specificityTerminalK > 0,
              subsetBeamWidth > 0, subsetExpansionLimit > 0, (0...2).contains(exchangeWidth),
              (1...3).contains(salvageMaxStages), salvageMaxEdgesPerPool >= 0,
              salvageMaxOligosPerPool >= 0, salvageTimeLimit.isFinite, salvageTimeLimit > 0 else {
            throw PrimalScheme3DesignError.invalidRequest("Allele coverage advanced options are outside the supported lge.4 contract.")
        }
        let work = [workFrontierCandidates, workConstructionCandidateAttempts,
                    workRepairCandidateProbesPerRound, workRepairNeighborhoodsPerRound,
                    workRepairTrialsPerRound, workPoolLookaheadCandidates,
                    workCleanupMovesPerRound, workFamiliesPerRefresh]
        guard work.allSatisfy({ $0 > 0 }), !salvageThresholds.isEmpty,
              salvageThresholds.count <= salvageMaxStages else {
            throw PrimalScheme3DesignError.invalidRequest("Allele coverage work bounds and salvage ladder must be positive and explicitly bounded.")
        }
        var prior = -26.0
        for threshold in salvageThresholds {
            guard threshold.isFinite, threshold < prior else {
                throw PrimalScheme3DesignError.invalidRequest("Salvage thresholds must be finite and strictly decreasing from -26.")
            }
            prior = threshold
        }
        let salvageControls = ["salvageThresholds", "salvageMaxStages", "salvageMaxEdgesPerPool",
                               "salvageMaxOligosPerPool", "salvageTimeLimit"]
        if salvage == "off", salvageControls.contains(where: requestedOptionNames.contains) {
            throw PrimalScheme3DesignError.invalidRequest("Salvage controls require --salvage bounded.")
        }
        if variantSelection == "full-cloud",
           requestedOptionNames.contains("subsetBeamWidth") || requestedOptionNames.contains("subsetExpansionLimit") {
            throw PrimalScheme3DesignError.invalidRequest("Subset controls are ignored by full-cloud variant selection.")
        }
        let tiers = salvage == "bounded"
            ? ["strict"] + (1...salvageThresholds.count).map { "salvage-\($0)" }
            : ["strict"]
        guard tiers.contains(primaryTier) else {
            throw PrimalScheme3DesignError.invalidRequest("Primary tier must name an enabled requested stage.")
        }
    }

    func appendRequestedArguments(to arguments: inout [String]) {
        func append(_ key: String, _ flag: String, _ value: String) {
            if requestedOptionNames.contains(key) { arguments += [flag, value] }
        }
        append("preset", "--preset", preset)
        append("candidateProfiles", "--candidate-profiles", candidateProfiles)
        if let reuseDiscovery { append("reuseDiscovery", "--reuse-discovery", reuseDiscovery.path) }
        append("variantSelection", "--variant-selection", variantSelection)
        append("phaseScheduling", "--phase-scheduling", phaseScheduling.rawValue)
        append("alleleWeighting", "--allele-weighting", alleleWeighting)
        append("discoveryLengthMode", "--discovery-length-mode", discoveryLengthMode)
        append("specificityTerminalK", "--specificity-terminal-k", String(specificityTerminalK))
        append("secondaryProductPolicy", "--secondary-product-policy", secondaryProductPolicy)
        append("subsetBeamWidth", "--subset-beam-width", String(subsetBeamWidth))
        append("subsetExpansionLimit", "--subset-expansion-limit", String(subsetExpansionLimit))
        append("exchangeWidth", "--exchange-width", String(exchangeWidth))
        append("salvage", "--salvage", salvage)
        if requestedOptionNames.contains("salvageThresholds") {
            for threshold in salvageThresholds { arguments += ["--salvage-threshold", String(threshold)] }
        }
        append("salvageMaxStages", "--salvage-max-stages", String(salvageMaxStages))
        append("salvageMaxEdgesPerPool", "--salvage-max-edges-per-pool", String(salvageMaxEdgesPerPool))
        append("salvageMaxOligosPerPool", "--salvage-max-oligos-per-pool", String(salvageMaxOligosPerPool))
        append("salvageTimeLimit", "--salvage-time-limit", String(salvageTimeLimit))
        append("primaryTier", "--primary-tier", primaryTier)
        append("workFrontierCandidates", "--work-frontier-candidates", String(workFrontierCandidates))
        append("workConstructionCandidateAttempts", "--work-construction-candidate-attempts", String(workConstructionCandidateAttempts))
        append("workRepairCandidateProbesPerRound", "--work-repair-candidate-probes-per-round", String(workRepairCandidateProbesPerRound))
        append("workRepairNeighborhoodsPerRound", "--work-repair-neighborhoods-per-round", String(workRepairNeighborhoodsPerRound))
        append("workRepairTrialsPerRound", "--work-repair-trials-per-round", String(workRepairTrialsPerRound))
        append("workPoolLookaheadCandidates", "--work-pool-lookahead-candidates", String(workPoolLookaheadCandidates))
        append("workCleanupMovesPerRound", "--work-cleanup-moves-per-round", String(workCleanupMovesPerRound))
        append("workFamiliesPerRefresh", "--work-families-per-refresh", String(workFamiliesPerRefresh))
    }
}
