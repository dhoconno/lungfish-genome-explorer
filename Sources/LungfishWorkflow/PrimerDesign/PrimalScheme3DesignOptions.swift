import CryptoKit
import Darwin
import Foundation
import LungfishIO

public struct PrimalScheme3DesignOptions: Codable, Equatable, Sendable {
    public static var defaultCoreCount: Int { max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)) }
    public let requestedAmpliconSizeMinimum: Int?
    public let requestedAmpliconSizeMaximum: Int?
    /// Bounds the GUI seeds and the CLI defaults to when neither bound is
    /// supplied: 90% and 110% of a supported target. The installed fork uses
    /// the same fallback for an individually omitted bound, so every caller
    /// resolves identical spans from the same visible target.
    public static func defaultAmpliconSizeBounds(target: Int) -> (minimum: Int, maximum: Int)? {
        guard (100...2000).contains(target) else { return nil }
        return (Int(Double(target) * 0.9), Int(Double(target) * 1.1))
    }
    public var ampliconSizeMinimum: Int { requestedAmpliconSizeMinimum ?? Self.defaultAmpliconSizeBounds(target: ampliconSize)?.minimum ?? 0 }
    public var ampliconSizeMaximum: Int { requestedAmpliconSizeMaximum ?? Self.defaultAmpliconSizeBounds(target: ampliconSize)?.maximum ?? 0 }
    public var ampliconSizeMetric: String {
        requestedAmpliconSizeMinimum != nil || requestedAmpliconSizeMaximum != nil ? "reference-span" : "legacy-pairing"
    }
    public let dimerScore: Double
    public let useMatchDB: Bool
    public let backtrack: Bool
    public let ignoreN: Bool
    public let panelMode: PrimalScheme3PanelMode
    public let maxAmplicons: Int?
    public let maxAmpliconsPerMSA: Int?
    public let ampliconSize: Int
    public let poolCount: Int
    public let minOverlap: Int
    public let minimumBaseFrequency: Double
    public let highGC: Bool
    public let coreCount: Int
    public let terminalGapPolicy: PrimalScheme3TerminalGapPolicy
    public let selectionAlgorithm: PrimalScheme3SelectionAlgorithm
    public let coverageMetric: PrimalScheme3CoverageMetric
    public let coverageTarget: Double
    public let optimizerSeed: Int
    public let requestedOptimizerStarts: Int?
    public let requestedOptimizerRepairRounds: Int?
    public let requestedOptimizerTimeLimit: Double?
    public let optimizerStarts: Int
    public let optimizerRepairRounds: Int
    public let optimizerTimeLimit: Double
    public let alleleOptions: PrimalScheme3AlleleOptions
    public let legacySalvageOptions: PrimalScheme3LegacySalvageOptions
    public let gapCompletionParent: URL?
    public let gapExpansionOptions: PrimalScheme3GapExpansionOptions
    public let requestedMisprimingProductSize: Int?
    public var misprimingProductSize: Int {
        requestedMisprimingProductSize ?? (selectionAlgorithm == .legacy ? 0 : 2_000)
    }
    public init(ampliconSize: Int, poolCount: Int, minOverlap: Int = 10,
                minimumBaseFrequency: Double = 0, highGC: Bool = false, coreCount: Int = PrimalScheme3DesignOptions.defaultCoreCount,
                terminalGapPolicy: PrimalScheme3TerminalGapPolicy = .observedOnly,
                dimerScore: Double = -26, useMatchDB: Bool = true,
                backtrack: Bool = false, ignoreN: Bool = false,
                panelMode: PrimalScheme3PanelMode = .equal,
                maxAmplicons: Int? = nil, maxAmpliconsPerMSA: Int? = nil,
                ampliconSizeMinimum: Int? = nil, ampliconSizeMaximum: Int? = nil,
                selectionAlgorithm: PrimalScheme3SelectionAlgorithm = .legacy,
                coverageMetric: PrimalScheme3CoverageMetric? = nil,
                coverageTarget: Double? = nil, optimizerSeed: Int = 0,
                optimizerStarts: Int? = nil, optimizerRepairRounds: Int? = nil,
                optimizerTimeLimit: Double? = nil,
                misprimingProductSize: Int? = nil,
                alleleOptions: PrimalScheme3AlleleOptions = .init(),
                legacySalvageOptions: PrimalScheme3LegacySalvageOptions = .init(),
                gapCompletionParent: URL? = nil,
                gapExpansionOptions: PrimalScheme3GapExpansionOptions = .init()) {
        self.requestedAmpliconSizeMinimum = ampliconSizeMinimum
        self.requestedAmpliconSizeMaximum = ampliconSizeMaximum
        self.dimerScore = dimerScore
        self.useMatchDB = useMatchDB
        self.backtrack = backtrack
        self.ignoreN = ignoreN
        self.panelMode = panelMode
        self.maxAmplicons = maxAmplicons
        self.maxAmpliconsPerMSA = maxAmpliconsPerMSA
        self.ampliconSize = ampliconSize
        self.poolCount = poolCount
        self.minOverlap = minOverlap
        self.minimumBaseFrequency = minimumBaseFrequency
        self.highGC = highGC
        self.coreCount = coreCount
        self.terminalGapPolicy = terminalGapPolicy
        self.selectionAlgorithm = selectionAlgorithm
        self.coverageMetric = coverageMetric ?? (selectionAlgorithm == .alleleCoverage ? .observedAllelePrimerTrimmed : .fullSpan)
        self.coverageTarget = coverageTarget ?? (selectionAlgorithm == .alleleCoverage ? 0.95 : 0.90)
        self.optimizerSeed = optimizerSeed
        self.requestedOptimizerStarts = optimizerStarts
        self.requestedOptimizerRepairRounds = optimizerRepairRounds
        self.requestedOptimizerTimeLimit = optimizerTimeLimit
        let effort = alleleOptions.searchEffort
        self.optimizerStarts = optimizerStarts ?? effort.optimizerStarts
        self.optimizerRepairRounds = optimizerRepairRounds ?? effort.optimizerRepairRounds
        self.optimizerTimeLimit = optimizerTimeLimit ?? effort.optimizerTimeLimit
        self.requestedMisprimingProductSize = misprimingProductSize
        self.alleleOptions = alleleOptions
        self.legacySalvageOptions = legacySalvageOptions
        self.gapCompletionParent = gapCompletionParent
        self.gapExpansionOptions = gapExpansionOptions
    }

    private enum CodingKeys: String, CodingKey {
        case requestedAmpliconSizeMinimum, requestedAmpliconSizeMaximum, dimerScore, useMatchDB
        case backtrack, ignoreN, panelMode, maxAmplicons, maxAmpliconsPerMSA, ampliconSize
        case poolCount, minOverlap, minimumBaseFrequency, highGC, coreCount, terminalGapPolicy
        case selectionAlgorithm, coverageMetric, coverageTarget, optimizerSeed, optimizerStarts
        case optimizerRepairRounds, optimizerTimeLimit, requestedMisprimingProductSize
        case requestedOptimizerStarts, requestedOptimizerRepairRounds, requestedOptimizerTimeLimit
        case alleleOptions
        case legacySalvageOptions, gapCompletionParent, gapExpansionOptions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let alleleOptions = try values.decodeIfPresent(
            PrimalScheme3AlleleOptions.self, forKey: .alleleOptions) ?? .init()
        let storedStarts = try values.decodeIfPresent(Int.self, forKey: .optimizerStarts)
            ?? PrimalScheme3SearchEffort.standardV1.optimizerStarts
        let storedRepairRounds = try values.decodeIfPresent(Int.self, forKey: .optimizerRepairRounds)
            ?? PrimalScheme3SearchEffort.standardV1.optimizerRepairRounds
        let storedTimeLimit = try values.decodeIfPresent(Double.self, forKey: .optimizerTimeLimit)
            ?? PrimalScheme3SearchEffort.standardV1.optimizerTimeLimit
        let requestedStarts = try values.decodeIfPresent(Int.self, forKey: .requestedOptimizerStarts)
            ?? (storedStarts == alleleOptions.searchEffort.optimizerStarts ? nil : storedStarts)
        let requestedRepairRounds = try values.decodeIfPresent(
            Int.self, forKey: .requestedOptimizerRepairRounds)
            ?? (storedRepairRounds == alleleOptions.searchEffort.optimizerRepairRounds
                ? nil : storedRepairRounds)
        let requestedTimeLimit = try values.decodeIfPresent(
            Double.self, forKey: .requestedOptimizerTimeLimit)
            ?? (storedTimeLimit == alleleOptions.searchEffort.optimizerTimeLimit ? nil : storedTimeLimit)
        self.init(
            ampliconSize: try values.decode(Int.self, forKey: .ampliconSize),
            poolCount: try values.decode(Int.self, forKey: .poolCount),
            minOverlap: try values.decode(Int.self, forKey: .minOverlap),
            minimumBaseFrequency: try values.decode(Double.self, forKey: .minimumBaseFrequency),
            highGC: try values.decode(Bool.self, forKey: .highGC),
            coreCount: try values.decode(Int.self, forKey: .coreCount),
            terminalGapPolicy: try values.decode(PrimalScheme3TerminalGapPolicy.self, forKey: .terminalGapPolicy),
            dimerScore: try values.decode(Double.self, forKey: .dimerScore),
            useMatchDB: try values.decode(Bool.self, forKey: .useMatchDB),
            backtrack: try values.decode(Bool.self, forKey: .backtrack),
            ignoreN: try values.decode(Bool.self, forKey: .ignoreN),
            panelMode: try values.decode(PrimalScheme3PanelMode.self, forKey: .panelMode),
            maxAmplicons: try values.decodeIfPresent(Int.self, forKey: .maxAmplicons),
            maxAmpliconsPerMSA: try values.decodeIfPresent(Int.self, forKey: .maxAmpliconsPerMSA),
            ampliconSizeMinimum: try values.decodeIfPresent(Int.self, forKey: .requestedAmpliconSizeMinimum),
            ampliconSizeMaximum: try values.decodeIfPresent(Int.self, forKey: .requestedAmpliconSizeMaximum),
            selectionAlgorithm: try values.decodeIfPresent(PrimalScheme3SelectionAlgorithm.self, forKey: .selectionAlgorithm) ?? .legacy,
            coverageMetric: try values.decodeIfPresent(PrimalScheme3CoverageMetric.self, forKey: .coverageMetric),
            coverageTarget: try values.decodeIfPresent(Double.self, forKey: .coverageTarget),
            optimizerSeed: try values.decodeIfPresent(Int.self, forKey: .optimizerSeed) ?? 0,
            optimizerStarts: requestedStarts,
            optimizerRepairRounds: requestedRepairRounds,
            optimizerTimeLimit: requestedTimeLimit,
            misprimingProductSize: try values.decodeIfPresent(Int.self, forKey: .requestedMisprimingProductSize),
            alleleOptions: alleleOptions,
            legacySalvageOptions: try values.decodeIfPresent(PrimalScheme3LegacySalvageOptions.self, forKey: .legacySalvageOptions) ?? .init(),
            gapCompletionParent: try values.decodeIfPresent(URL.self, forKey: .gapCompletionParent),
            gapExpansionOptions: try values.decodeIfPresent(PrimalScheme3GapExpansionOptions.self, forKey: .gapExpansionOptions) ?? .init())
        guard optimizerStarts == storedStarts, optimizerRepairRounds == storedRepairRounds,
              optimizerTimeLimit == storedTimeLimit else {
            throw DecodingError.dataCorruptedError(
                forKey: .alleleOptions, in: values,
                debugDescription: "Stored optimizer values differ from the effort and explicit override mask.")
        }
    }

    public var provenanceOptions: [String: ParameterValue] {
        ["ampliconSize": .integer(ampliconSize), "ampliconSizeMinimum": .integer(ampliconSizeMinimum),
         "ampliconSizeMaximum": .integer(ampliconSizeMaximum), "ampliconSizeMetric": .string(ampliconSizeMetric),
         "requestedAmpliconSizeMinimum": requestedAmpliconSizeMinimum.map(ParameterValue.integer) ?? .null,
         "requestedAmpliconSizeMaximum": requestedAmpliconSizeMaximum.map(ParameterValue.integer) ?? .null,
         "poolCount": .integer(poolCount),
         "minOverlap": .integer(minOverlap), "minimumBaseFrequency": .number(minimumBaseFrequency),
         "highGC": .boolean(highGC), "coreCount": .integer(coreCount),
         "terminalGapPolicy": .string(terminalGapPolicy.rawValue), "dimerScore": .number(dimerScore),
         "useMatchDB": .boolean(useMatchDB), "backtrack": .boolean(backtrack), "ignoreN": .boolean(ignoreN),
         "panelMode": .string(panelMode.rawValue),
         "maxAmplicons": maxAmplicons.map(ParameterValue.integer) ?? .string("unlimited"),
         "maxAmpliconsPerMSA": maxAmpliconsPerMSA.map(ParameterValue.integer) ?? .string("unlimited"),
         "selectionAlgorithm": .string(selectionAlgorithm.rawValue),
         "coverageMetric": .string(coverageMetric.rawValue), "coverageTarget": .number(coverageTarget),
         "optimizerSeed": .integer(optimizerSeed), "optimizerStarts": .integer(optimizerStarts),
         "optimizerRepairRounds": .integer(optimizerRepairRounds),
         "optimizerTimeLimit": .number(optimizerTimeLimit),
         "requestedOptimizerStarts": requestedOptimizerStarts.map(ParameterValue.integer) ?? .null,
         "requestedOptimizerRepairRounds": requestedOptimizerRepairRounds.map(ParameterValue.integer) ?? .null,
         "requestedOptimizerTimeLimit": requestedOptimizerTimeLimit.map(ParameterValue.number) ?? .null,
         "requestedMisprimingProductSize": requestedMisprimingProductSize.map(ParameterValue.integer) ?? .null,
         "misprimingProductSize": .integer(misprimingProductSize),
         "alleleOptions": .dictionary(alleleOptions.resolvedProvenanceOptions),
         "alleleRequestedOptions": .dictionary(alleleOptions.requestedProvenanceOptions),
         "legacySalvage": .dictionary(legacySalvageOptions.provenance),
         "gapCompletionParent": gapCompletionParent.map { .string($0.path) } ?? .null,
         "gapExpansion": .dictionary(gapExpansionOptions.provenance)]
    }
}
