import Foundation
import LungfishIO

public enum PrimalScheme3LegacySalvageMode: String, Codable, CaseIterable, Sendable {
    case off, bounded
}

public struct PrimalScheme3LegacySalvageOptions: Codable, Equatable, Sendable {
    public let mode: PrimalScheme3LegacySalvageMode
    public let thresholds: [Double]
    public let floor: Double
    public let maxEdgesPerPool: Int
    public let maxIncidentSpeciesPerPool: Int
    public let minReferenceGain: Int
    public let maxCandidateEvaluations: Int
    public let requestedOptionNames: Set<String>
    private enum CodingKeys: String, CodingKey { case mode, thresholds, floor, maxEdgesPerPool, maxIncidentSpeciesPerPool, minReferenceGain, maxCandidateEvaluations, requestedOptionNames }

    public init(mode: PrimalScheme3LegacySalvageMode = .off,
                thresholds: [Double]? = nil, floor: Double? = nil,
                maxEdgesPerPool: Int? = nil, maxIncidentSpeciesPerPool: Int? = nil,
                minReferenceGain: Int? = nil, maxCandidateEvaluations: Int? = nil) {
        self.mode = mode
        self.thresholds = thresholds ?? [-28, -30, -32]
        self.floor = floor ?? -32
        self.maxEdgesPerPool = maxEdgesPerPool ?? 8
        self.maxIncidentSpeciesPerPool = maxIncidentSpeciesPerPool ?? 4
        self.minReferenceGain = minReferenceGain ?? 1
        self.maxCandidateEvaluations = maxCandidateEvaluations ?? 10_000
        var names = Set<String>()
        if mode != .off { names.insert("mode") }
        if thresholds != nil { names.insert("thresholds") }
        if floor != nil { names.insert("floor") }
        if maxEdgesPerPool != nil { names.insert("maxEdgesPerPool") }
        if maxIncidentSpeciesPerPool != nil { names.insert("maxIncidentSpeciesPerPool") }
        if minReferenceGain != nil { names.insert("minReferenceGain") }
        if maxCandidateEvaluations != nil { names.insert("maxCandidateEvaluations") }
        self.requestedOptionNames = names
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decodeIfPresent(PrimalScheme3LegacySalvageMode.self, forKey: .mode) ?? .off
        self.thresholds = try c.decodeIfPresent([Double].self, forKey: .thresholds) ?? [-28, -30, -32]
        self.floor = try c.decodeIfPresent(Double.self, forKey: .floor) ?? -32
        self.maxEdgesPerPool = try c.decodeIfPresent(Int.self, forKey: .maxEdgesPerPool) ?? 8
        self.maxIncidentSpeciesPerPool = try c.decodeIfPresent(Int.self, forKey: .maxIncidentSpeciesPerPool) ?? 4
        self.minReferenceGain = try c.decodeIfPresent(Int.self, forKey: .minReferenceGain) ?? 1
        self.maxCandidateEvaluations = try c.decodeIfPresent(Int.self, forKey: .maxCandidateEvaluations) ?? 10_000
        self.requestedOptionNames = try c.decodeIfPresent(Set<String>.self, forKey: .requestedOptionNames) ?? []
    }

    public func validate(selectionAlgorithm: PrimalScheme3SelectionAlgorithm,
                         grouping: PrimerAnalysisGrouping, panelMode: PrimalScheme3PanelMode = .equal, strictCutoff: Double = -26,
                         mapping: String = "first", hasRegionInput: Bool = false,
                         hasImportedPrimers: Bool = false) throws {
        guard mode == .off || mode == .bounded else { throw PrimalScheme3DesignError.invalidRequest("Legacy salvage mode must be off or bounded.") }
        if mode == .off && !requestedOptionNames.isEmpty { throw PrimalScheme3DesignError.invalidRequest("Legacy salvage controls require bounded mode.") }
        guard mode == .off || (selectionAlgorithm == .legacy && grouping == .combined && panelMode == .equal && mapping == "first" && !hasRegionInput && !hasImportedPrimers) else {
            throw PrimalScheme3DesignError.invalidRequest("Legacy salvage requires legacy selection, a combined equal panel, first mapping, and no region or imported primer inputs.")
        }
        if mode == .off { return }
        guard thresholds.count > 0, thresholds.count <= 16, thresholds.enumerated().allSatisfy({ $0.element.isFinite && $0.element < strictCutoff && ($0.offset == 0 || $0.element < thresholds[$0.offset - 1]) }),
              floor.isFinite, floor < strictCutoff, thresholds.allSatisfy({ $0 >= floor }), maxEdgesPerPool >= 0,
              maxIncidentSpeciesPerPool >= 0, minReferenceGain > 0, maxCandidateEvaluations > 0 else {
            throw PrimalScheme3DesignError.invalidRequest("Legacy salvage budgets must be finite, bounded, and strictly decreasing below -26.")
        }
    }

    func appendRequestedArguments(to args: inout [String]) {
        guard mode == .bounded else { return }
        args += ["--legacy-salvage", mode.rawValue]
        if requestedOptionNames.contains("thresholds") { for value in thresholds { args += ["--legacy-salvage-threshold", String(value)] } }
        if requestedOptionNames.contains("floor") { args += ["--legacy-salvage-floor", String(floor)] }
        if requestedOptionNames.contains("maxEdgesPerPool") { args += ["--legacy-salvage-max-edges-per-pool", String(maxEdgesPerPool)] }
        if requestedOptionNames.contains("maxIncidentSpeciesPerPool") { args += ["--legacy-salvage-max-incident-species-per-pool", String(maxIncidentSpeciesPerPool)] }
        if requestedOptionNames.contains("minReferenceGain") { args += ["--legacy-salvage-min-reference-gain", String(minReferenceGain)] }
        if requestedOptionNames.contains("maxCandidateEvaluations") { args += ["--legacy-salvage-max-candidate-evaluations", String(maxCandidateEvaluations)] }
    }

    var provenance: [String: ParameterValue] {
        ["mode": .string(mode.rawValue), "thresholds": .array(thresholds.map(ParameterValue.number)),
         "floor": .number(floor), "maxEdgesPerPool": .integer(maxEdgesPerPool),
         "maxIncidentSpeciesPerPool": .integer(maxIncidentSpeciesPerPool),
         "minReferenceGain": .integer(minReferenceGain), "maxCandidateEvaluations": .integer(maxCandidateEvaluations)]
    }
}

public enum PrimalScheme3GapExpansionMode: String, Codable, CaseIterable, Sendable { case off, bounded }

public struct PrimalScheme3GapExpansionOptions: Codable, Equatable, Sendable {
    public let mode: PrimalScheme3GapExpansionMode
    public let maxAnchorsPerMSA: Int
    public let maxPairsPerMSA: Int
    public let requestedOptionNames: Set<String>
    private enum CodingKeys: String, CodingKey { case mode, maxAnchorsPerMSA, maxPairsPerMSA, requestedOptionNames }

    public init(mode: PrimalScheme3GapExpansionMode = .off, maxAnchorsPerMSA: Int? = nil, maxPairsPerMSA: Int? = nil) {
        self.mode = mode; self.maxAnchorsPerMSA = maxAnchorsPerMSA ?? 2_000; self.maxPairsPerMSA = maxPairsPerMSA ?? 1_000
        var names = Set<String>(); if mode != .off { names.insert("mode") }; if maxAnchorsPerMSA != nil { names.insert("maxAnchorsPerMSA") }; if maxPairsPerMSA != nil { names.insert("maxPairsPerMSA") }; self.requestedOptionNames = names
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decodeIfPresent(PrimalScheme3GapExpansionMode.self, forKey: .mode) ?? .off
        self.maxAnchorsPerMSA = try c.decodeIfPresent(Int.self, forKey: .maxAnchorsPerMSA) ?? 2_000
        self.maxPairsPerMSA = try c.decodeIfPresent(Int.self, forKey: .maxPairsPerMSA) ?? 1_000
        self.requestedOptionNames = try c.decodeIfPresent(Set<String>.self, forKey: .requestedOptionNames) ?? []
    }
    public func validate(hasParent: Bool) throws {
        if mode == .off && !requestedOptionNames.isEmpty { throw PrimalScheme3DesignError.invalidRequest("Gap expansion budgets require bounded mode.") }
        if mode == .bounded && !hasParent { throw PrimalScheme3DesignError.invalidRequest("Gap expansion requires a gap-completion parent.") }
        guard maxAnchorsPerMSA > 0, maxPairsPerMSA > 0 else { throw PrimalScheme3DesignError.invalidRequest("Gap expansion budgets must be positive.") }
    }
    func appendRequestedArguments(to args: inout [String]) {
        guard mode == .bounded else { return }
        args += ["--gap-expansion", mode.rawValue]
        if requestedOptionNames.contains("maxAnchorsPerMSA") { args += ["--gap-expansion-max-anchors-per-msa", String(maxAnchorsPerMSA)] }
        if requestedOptionNames.contains("maxPairsPerMSA") { args += ["--gap-expansion-max-pairs-per-msa", String(maxPairsPerMSA)] }
    }
    var provenance: [String: ParameterValue] { ["mode": .string(mode.rawValue), "maxAnchorsPerMSA": .integer(maxAnchorsPerMSA), "maxPairsPerMSA": .integer(maxPairsPerMSA)] }
}


extension PrimalScheme3DesignOptions {
    func replacingGapCompletionParent(_ parent: URL?) -> Self {
        Self(ampliconSize: ampliconSize, poolCount: poolCount, minOverlap: minOverlap,
             minimumBaseFrequency: minimumBaseFrequency, highGC: highGC, coreCount: coreCount,
             terminalGapPolicy: terminalGapPolicy, dimerScore: dimerScore, useMatchDB: useMatchDB,
             backtrack: backtrack, ignoreN: ignoreN, panelMode: panelMode, maxAmplicons: maxAmplicons,
             maxAmpliconsPerMSA: maxAmpliconsPerMSA, ampliconSizeMinimum: requestedAmpliconSizeMinimum,
             ampliconSizeMaximum: requestedAmpliconSizeMaximum, selectionAlgorithm: selectionAlgorithm,
             coverageMetric: coverageMetric, coverageTarget: coverageTarget, optimizerSeed: optimizerSeed,
             optimizerStarts: requestedOptimizerStarts, optimizerRepairRounds: requestedOptimizerRepairRounds,
             optimizerTimeLimit: requestedOptimizerTimeLimit, misprimingProductSize: requestedMisprimingProductSize,
             alleleOptions: alleleOptions, legacySalvageOptions: legacySalvageOptions,
             gapCompletionParent: parent, gapExpansionOptions: gapExpansionOptions)
    }
}
