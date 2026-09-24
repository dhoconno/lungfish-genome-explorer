import Foundation
import LungfishIO

public enum PrimerSchemeEngine: String, Codable, CaseIterable, Sendable { case olivar, varvamp }
public enum PrimerSchemeMode: String, Codable, CaseIterable, Sendable { case single, tiled, qpcr }
public enum PrimerOligoRole: String, Codable, CaseIterable, Sendable { case forward, reverse, probe }
public enum PrimerAssayStatus: String, Codable, CaseIterable, Sendable { case selected, alternative }
public enum PrimerOligoStrand: String, Codable, CaseIterable, Sendable {
    case forward = "+"
    case reverse = "-"
}

public enum PrimerSchemeDesignError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case executionFailed(Int32, String, String?)
    case contractViolation(String, diagnostics: String? = nil)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): return "Primer scheme: \(reason)"
        case .executionFailed(let status, let detail, let diagnostics):
            let suffix = diagnostics.map { " Failure evidence: \($0)" } ?? ""
            return "Primer scheme adapter exited with status \(status): \(detail)\(suffix)"
        case .contractViolation(let reason, let diagnostics):
            let suffix = diagnostics.map { " Failure evidence: \($0)" } ?? ""
            return "Primer scheme adapter contract: \(reason)\(suffix)"
        }
    }
}

/// Plain JSON values used by adapter metadata and resolved settings.
public enum PrimerSchemeJSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), integer(Int), boolean(Bool), null
    case array([PrimerSchemeJSONValue])
    case object([String: PrimerSchemeJSONValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .boolean(bool) }
        else if let integer = try? value.decode(Int.self) { self = .integer(integer) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([PrimerSchemeJSONValue].self) { self = .array(array) }
        else if let object = try? value.decode([String: PrimerSchemeJSONValue].self) { self = .object(object) }
        else {
            throw DecodingError.typeMismatch(Self.self, .init(
                codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .boolean(let item): try value.encode(item)
        case .null: try value.encodeNil()
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.string(let lhs), .string(let rhs)): return lhs == rhs
        case (.number(let lhs), .number(let rhs)): return lhs == rhs
        case (.integer(let lhs), .integer(let rhs)): return lhs == rhs
        case (.number(let lhs), .integer(let rhs)), (.integer(let rhs), .number(let lhs)):
            return lhs == Double(rhs)
        case (.boolean(let lhs), .boolean(let rhs)): return lhs == rhs
        case (.null, .null): return true
        case (.array(let lhs), .array(let rhs)): return lhs == rhs
        case (.object(let lhs), .object(let rhs)): return lhs == rhs
        default: return false
        }
    }

    var parameterValue: ParameterValue {
        switch self {
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        case .integer(let value): return .integer(value)
        case .boolean(let value): return .boolean(value)
        case .null: return .null
        case .array(let values): return .array(values.map(\.parameterValue))
        case .object(let values): return .dictionary(values.mapValues(\.parameterValue))
        }
    }

    var isFinite: Bool {
        switch self {
        case .number(let value): return value.isFinite
        case .array(let values): return values.allSatisfy(\.isFinite)
        case .object(let values): return values.values.allSatisfy(\.isFinite)
        default: return true
        }
    }
}

public struct PrimerSchemeDoubleTriplet: Codable, Equatable, Sendable {
    public var minimum: Double
    public var maximum: Double
    public var optimum: Double
    public init(minimum: Double, maximum: Double, optimum: Double) {
        self.minimum = minimum; self.maximum = maximum; self.optimum = optimum
    }
    var values: [Double] { [minimum, maximum, optimum] }
    func validate(_ name: String) throws {
        guard values.allSatisfy(\.isFinite), minimum <= optimum, optimum <= maximum else {
            throw PrimerSchemeDesignError.invalidRequest("\(name) must have finite minimum ≤ optimum ≤ maximum values.")
        }
    }
}

public struct PrimerSchemeIntTriplet: Codable, Equatable, Sendable {
    public var minimum: Int
    public var maximum: Int
    public var optimum: Int
    public init(minimum: Int, maximum: Int, optimum: Int) {
        self.minimum = minimum; self.maximum = maximum; self.optimum = optimum
    }
    var values: [Int] { [minimum, maximum, optimum] }
    func validate(_ name: String) throws {
        guard minimum >= 0, minimum <= optimum, optimum <= maximum else {
            throw PrimerSchemeDesignError.invalidRequest("\(name) must have nonnegative minimum ≤ optimum ≤ maximum values.")
        }
    }
}

public struct PrimerSchemeDoubleRange: Codable, Equatable, Sendable {
    public var minimum: Double
    public var maximum: Double
    public init(minimum: Double, maximum: Double) { self.minimum = minimum; self.maximum = maximum }
    var values: [Double] { [minimum, maximum] }
    func validate(_ name: String) throws {
        guard minimum.isFinite, maximum.isFinite, minimum <= maximum else {
            throw PrimerSchemeDesignError.invalidRequest("\(name) must be a finite ordered range.")
        }
    }
}

public struct PrimerSchemeIntRange: Codable, Equatable, Sendable {
    public var minimum: Int
    public var maximum: Int
    public init(minimum: Int, maximum: Int) { self.minimum = minimum; self.maximum = maximum }
    var values: [Int] { [minimum, maximum] }
    func validate(_ name: String) throws {
        guard minimum >= 0, minimum <= maximum else {
            throw PrimerSchemeDesignError.invalidRequest("\(name) must be a nonnegative ordered range.")
        }
    }
}

public struct OlivarRiskWeights: Codable, Equatable, Sendable {
    public var extremeGC: Double
    public var lowComplexity: Double
    public var nonSpecificity: Double
    public var variation: Double
    public var sensitivity: Double
    public var combination: Double
    public init(extremeGC: Double = 1, lowComplexity: Double = 1,
                nonSpecificity: Double = 1, variation: Double = 1,
                sensitivity: Double = 1, combination: Double = 1) {
        self.extremeGC = extremeGC; self.lowComplexity = lowComplexity
        self.nonSpecificity = nonSpecificity; self.variation = variation
        self.sensitivity = sensitivity; self.combination = combination
    }
    var json: [String: PrimerSchemeJSONValue] {
        ["extremeGC": .number(extremeGC), "lowComplexity": .number(lowComplexity),
         "nonSpecificity": .number(nonSpecificity), "variation": .number(variation),
         "sensitivity": .number(sensitivity), "combination": .number(combination)]
    }
    func validate() throws {
        guard json.values.allSatisfy({ $0.isFinite && ($0.numberValue ?? -1) >= 0 }) else {
            throw PrimerSchemeDesignError.invalidRequest("Olivar risk weights must be finite and nonnegative.")
        }
    }
}

private extension PrimerSchemeJSONValue {
    var numberValue: Double? {
        switch self { case .number(let value): return value; case .integer(let value): return Double(value); default: return nil }
    }
}

public struct OlivarDesignOptions: Codable, Equatable, Sendable {
    public var minimumVariantFrequency: Double
    public var degenerate: Bool
    public var align: Bool
    public var temperatureC: Double
    public var salinityM: Double
    public var maximumDimerDeltaG: Double
    public var minimumGC: Double
    public var maximumGC: Double
    public var minimumComplexity: Double
    public var maximumPrimerLength: Int
    public var checkVariants: Bool
    public var seed: Int
    public var effort: Int
    public var forwardPrefix: String
    public var reversePrefix: String
    public var blastDatabasePath: String?
    public var riskWeights: OlivarRiskWeights
    public var suppliedOptionNames: Set<String>

    public init(minimumVariantFrequency: Double = 0.01, degenerate: Bool = false,
                align: Bool = false, temperatureC: Double = 60, salinityM: Double = 0.18,
                maximumDimerDeltaG: Double = -11.8, minimumGC: Double = 0.2,
                maximumGC: Double = 0.75, minimumComplexity: Double = 0.4,
                maximumPrimerLength: Int = 36, checkVariants: Bool = false,
                seed: Int = 10, effort: Int = 1, forwardPrefix: String = "",
                reversePrefix: String = "", blastDatabasePath: String? = nil,
                riskWeights: OlivarRiskWeights = .init(), suppliedOptionNames: Set<String> = []) {
        self.minimumVariantFrequency = minimumVariantFrequency; self.degenerate = degenerate
        self.align = align; self.temperatureC = temperatureC; self.salinityM = salinityM
        self.maximumDimerDeltaG = maximumDimerDeltaG; self.minimumGC = minimumGC
        self.maximumGC = maximumGC; self.minimumComplexity = minimumComplexity
        self.maximumPrimerLength = maximumPrimerLength; self.checkVariants = checkVariants
        self.seed = seed; self.effort = effort; self.forwardPrefix = forwardPrefix
        self.reversePrefix = reversePrefix; self.blastDatabasePath = blastDatabasePath
        self.riskWeights = riskWeights; self.suppliedOptionNames = suppliedOptionNames
    }

    func validate() throws {
        guard minimumVariantFrequency.isFinite, (0...1).contains(minimumVariantFrequency),
              !align, temperatureC.isFinite, salinityM.isFinite, salinityM >= 0,
              maximumDimerDeltaG.isFinite, minimumGC.isFinite, maximumGC.isFinite,
              (0.0...1.0).contains(minimumGC), (0.0...1.0).contains(maximumGC), minimumGC <= maximumGC,
              minimumComplexity.isFinite, (0.0...1.0).contains(minimumComplexity),
              maximumPrimerLength > 0, effort > 0 else {
            throw PrimerSchemeDesignError.invalidRequest("Olivar options must use an equal-length alignment and finite native ranges; adapter v1 does not permit --align.")
        }
        try riskWeights.validate()
    }

    var json: [String: PrimerSchemeJSONValue] {
        ["minimumVariantFrequency": .number(minimumVariantFrequency), "degenerate": .boolean(degenerate),
         "align": .boolean(align), "temperatureC": .number(temperatureC), "salinityM": .number(salinityM),
         "maximumDimerDeltaG": .number(maximumDimerDeltaG), "minimumGC": .number(minimumGC),
         "maximumGC": .number(maximumGC), "minimumComplexity": .number(minimumComplexity),
         "maximumPrimerLength": .integer(maximumPrimerLength), "checkVariants": .boolean(checkVariants),
         "seed": .integer(seed), "effort": .integer(effort), "forwardPrefix": .string(forwardPrefix),
         "reversePrefix": .string(reversePrefix),
         "blastDatabasePath": blastDatabasePath.map(PrimerSchemeJSONValue.string) ?? .null,
         "riskWeights": .object(riskWeights.json)]
    }

    var provenance: ParameterValue {
        let resolved = json.mapValues(\.parameterValue)
        return .dictionary(["supplied": .dictionary(resolved.filter { suppliedOptionNames.contains($0.key) }),
                            "resolved": .dictionary(resolved)])
    }
}

public struct VarVAMPConfigOverrides: Codable, Equatable, Sendable {
    public var terminalMaskingThreshold: Double?
    public var primerTemperature: PrimerSchemeDoubleTriplet?
    public var primerGCRange: PrimerSchemeDoubleTriplet?
    public var primerSizes: PrimerSchemeIntTriplet?
    public var primerMaximumPolyX: Int?
    public var primerMaximumDinucleotideRepeats: Int?
    public var primerHairpin: Double?
    public var primerGCEnd: PrimerSchemeIntRange?
    public var primerMinimum3PrimeWithoutAmbiguity: Int?
    public var primerMaximumDimerTemperature: Double?
    public var primerMaximumDimerDeltaG: Double?
    public var endOverlap: Int?
    public var probeTemperature: PrimerSchemeDoubleTriplet?
    public var probeSizes: PrimerSchemeIntTriplet?
    public var probeGCRange: PrimerSchemeDoubleTriplet?
    public var probeGCEnd: PrimerSchemeIntRange?
    public var qprimerDifference: Double?
    public var probeTemperatureDifference: PrimerSchemeDoubleRange?
    public var probeDistance: PrimerSchemeIntRange?
    public var ampliconGCRange: PrimerSchemeDoubleRange?
    public var ampliconDeletionCutoff: Int?
    public var monovalentCationConcentration: Double?
    public var divalentCationConcentration: Double?
    public var dNTPConcentration: Double?
    public var DNAConcentration: Double?

    public init(terminalMaskingThreshold: Double? = nil,
                primerTemperature: PrimerSchemeDoubleTriplet? = nil,
                primerGCRange: PrimerSchemeDoubleTriplet? = nil,
                primerSizes: PrimerSchemeIntTriplet? = nil,
                primerMaximumPolyX: Int? = nil,
                primerMaximumDinucleotideRepeats: Int? = nil,
                primerHairpin: Double? = nil, primerGCEnd: PrimerSchemeIntRange? = nil,
                primerMinimum3PrimeWithoutAmbiguity: Int? = nil,
                primerMaximumDimerTemperature: Double? = nil,
                primerMaximumDimerDeltaG: Double? = nil, endOverlap: Int? = nil,
                probeTemperature: PrimerSchemeDoubleTriplet? = nil,
                probeSizes: PrimerSchemeIntTriplet? = nil,
                probeGCRange: PrimerSchemeDoubleTriplet? = nil,
                probeGCEnd: PrimerSchemeIntRange? = nil,
                qprimerDifference: Double? = nil,
                probeTemperatureDifference: PrimerSchemeDoubleRange? = nil,
                probeDistance: PrimerSchemeIntRange? = nil,
                ampliconGCRange: PrimerSchemeDoubleRange? = nil,
                ampliconDeletionCutoff: Int? = nil,
                monovalentCationConcentration: Double? = nil,
                divalentCationConcentration: Double? = nil,
                dNTPConcentration: Double? = nil, DNAConcentration: Double? = nil) {
        self.terminalMaskingThreshold = terminalMaskingThreshold
        self.primerTemperature = primerTemperature; self.primerGCRange = primerGCRange
        self.primerSizes = primerSizes; self.primerMaximumPolyX = primerMaximumPolyX
        self.primerMaximumDinucleotideRepeats = primerMaximumDinucleotideRepeats
        self.primerHairpin = primerHairpin; self.primerGCEnd = primerGCEnd
        self.primerMinimum3PrimeWithoutAmbiguity = primerMinimum3PrimeWithoutAmbiguity
        self.primerMaximumDimerTemperature = primerMaximumDimerTemperature
        self.primerMaximumDimerDeltaG = primerMaximumDimerDeltaG; self.endOverlap = endOverlap
        self.probeTemperature = probeTemperature; self.probeSizes = probeSizes
        self.probeGCRange = probeGCRange; self.probeGCEnd = probeGCEnd
        self.qprimerDifference = qprimerDifference
        self.probeTemperatureDifference = probeTemperatureDifference
        self.probeDistance = probeDistance; self.ampliconGCRange = ampliconGCRange
        self.ampliconDeletionCutoff = ampliconDeletionCutoff
        self.monovalentCationConcentration = monovalentCationConcentration
        self.divalentCationConcentration = divalentCationConcentration
        self.dNTPConcentration = dNTPConcentration; self.DNAConcentration = DNAConcentration
    }

    var hasQPCRSetting: Bool {
        [probeTemperature != nil, probeSizes != nil, probeGCRange != nil, probeGCEnd != nil,
         qprimerDifference != nil, probeTemperatureDifference != nil, probeDistance != nil,
         ampliconGCRange != nil, ampliconDeletionCutoff != nil].contains(true)
    }

    func validate() throws {
        try primerTemperature?.validate("Primer temperature")
        try primerGCRange?.validate("Primer GC")
        try primerSizes?.validate("Primer sizes")
        try primerGCEnd?.validate("Primer GC end")
        try probeTemperature?.validate("Probe temperature")
        try probeSizes?.validate("Probe sizes")
        try probeGCRange?.validate("Probe GC")
        try probeGCEnd?.validate("Probe GC end")
        try probeTemperatureDifference?.validate("Probe temperature difference")
        try probeDistance?.validate("Probe distance")
        try ampliconGCRange?.validate("Amplicon GC")
        let doubles = [terminalMaskingThreshold, primerHairpin, primerMaximumDimerTemperature,
                       primerMaximumDimerDeltaG, qprimerDifference,
                       monovalentCationConcentration, divalentCationConcentration,
                       dNTPConcentration, DNAConcentration].compactMap { $0 }
        let integers = [primerMaximumPolyX, primerMaximumDinucleotideRepeats,
                        primerMinimum3PrimeWithoutAmbiguity, endOverlap,
                        ampliconDeletionCutoff].compactMap { $0 }
        guard doubles.allSatisfy(\.isFinite), integers.allSatisfy({ $0 >= 0 }) else {
            throw PrimerSchemeDesignError.invalidRequest("varVAMP overrides must be finite and nonnegative where counts are required.")
        }
    }

    var json: [String: PrimerSchemeJSONValue] {
        var result: [String: PrimerSchemeJSONValue] = [:]
        func number(_ key: String, _ value: Double?) { if let value { result[key] = .number(value) } }
        func integer(_ key: String, _ value: Int?) { if let value { result[key] = .integer(value) } }
        func doubles(_ key: String, _ value: [Double]?) { if let value { result[key] = .array(value.map(PrimerSchemeJSONValue.number)) } }
        func integers(_ key: String, _ value: [Int]?) { if let value { result[key] = .array(value.map(PrimerSchemeJSONValue.integer)) } }
        number("TERMINAL_MASKING_THRESHOLD", terminalMaskingThreshold)
        doubles("PRIMER_TMP", primerTemperature?.values); doubles("PRIMER_GC_RANGE", primerGCRange?.values)
        integers("PRIMER_SIZES", primerSizes?.values); integer("PRIMER_MAX_POLYX", primerMaximumPolyX)
        integer("PRIMER_MAX_DINUC_REPEATS", primerMaximumDinucleotideRepeats)
        number("PRIMER_HAIRPIN", primerHairpin); integers("PRIMER_GC_END", primerGCEnd?.values)
        integer("PRIMER_MIN_3_WITHOUT_AMB", primerMinimum3PrimeWithoutAmbiguity)
        number("PRIMER_MAX_DIMER_TMP", primerMaximumDimerTemperature)
        number("PRIMER_MAX_DIMER_DELTAG", primerMaximumDimerDeltaG); integer("END_OVERLAP", endOverlap)
        doubles("QPROBE_TMP", probeTemperature?.values); integers("QPROBE_SIZES", probeSizes?.values)
        doubles("QPROBE_GC_RANGE", probeGCRange?.values); integers("QPROBE_GC_END", probeGCEnd?.values)
        number("QPRIMER_DIFF", qprimerDifference); doubles("QPROBE_TEMP_DIFF", probeTemperatureDifference?.values)
        integers("QPROBE_DISTANCE", probeDistance?.values); doubles("QAMPLICON_GC", ampliconGCRange?.values)
        integer("QAMPLICON_DEL_CUTOFF", ampliconDeletionCutoff)
        number("PCR_MV_CONC", monovalentCationConcentration); number("PCR_DV_CONC", divalentCationConcentration)
        number("PCR_DNTP_CONC", dNTPConcentration); number("PCR_DNA_CONC", DNAConcentration)
        return result
    }
}

public struct VarVAMPDesignOptions: Codable, Equatable, Sendable {
    public var cumulativeConsensusThreshold: Double?
    public var maximumPrimerAmbiguities: Int
    public var maximumProbeAmbiguities: Int?
    public var tiledOverlap: Int
    public var reportCount: Int?
    public var qpcrTestCount: Int
    public var qpcrDeltaG: Int
    public var schemeName: String
    public var compatiblePrimersPath: String?
    public var blastDatabasePath: String?
    public var configOverrides: VarVAMPConfigOverrides
    public var suppliedOptionNames: Set<String>

    public init(cumulativeConsensusThreshold: Double? = nil,
                maximumPrimerAmbiguities: Int = 2, maximumProbeAmbiguities: Int? = nil,
                tiledOverlap: Int = 25, reportCount: Int? = nil, qpcrTestCount: Int = 50,
                qpcrDeltaG: Int = -3, schemeName: String = "varVAMP",
                compatiblePrimersPath: String? = nil, blastDatabasePath: String? = nil,
                configOverrides: VarVAMPConfigOverrides = .init(),
                suppliedOptionNames: Set<String> = []) {
        self.cumulativeConsensusThreshold = cumulativeConsensusThreshold
        self.maximumPrimerAmbiguities = maximumPrimerAmbiguities
        self.maximumProbeAmbiguities = maximumProbeAmbiguities
        self.tiledOverlap = tiledOverlap; self.reportCount = reportCount
        self.qpcrTestCount = qpcrTestCount; self.qpcrDeltaG = qpcrDeltaG
        self.schemeName = schemeName; self.compatiblePrimersPath = compatiblePrimersPath
        self.blastDatabasePath = blastDatabasePath; self.configOverrides = configOverrides
        self.suppliedOptionNames = suppliedOptionNames
    }

    func validate(mode: PrimerSchemeMode) throws {
        if let threshold = cumulativeConsensusThreshold {
            guard threshold.isFinite, threshold > 0, threshold <= 1 else {
                throw PrimerSchemeDesignError.invalidRequest("varVAMP cumulative consensus threshold must be finite and in (0, 1].")
            }
        } else if mode == .qpcr {
            throw PrimerSchemeDesignError.invalidRequest("qPCR requires an explicit cumulative consensus threshold.")
        }
        guard maximumPrimerAmbiguities >= 0, maximumProbeAmbiguities.map({ $0 >= 0 }) ?? true,
              tiledOverlap >= 0, reportCount.map({ $0 > 0 }) ?? true,
              qpcrTestCount > 0, !schemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PrimerSchemeDesignError.invalidRequest("varVAMP counts and scheme name are invalid.")
        }
        if mode != .single, reportCount != nil {
            throw PrimerSchemeDesignError.invalidRequest("varVAMP report count applies only to single mode.")
        }
        if mode != .tiled, suppliedOptionNames.contains("tiledOverlap") {
            throw PrimerSchemeDesignError.invalidRequest("varVAMP tiled overlap applies only to tiled mode.")
        }
        if mode != .qpcr && (maximumProbeAmbiguities != nil || configOverrides.hasQPCRSetting
            || suppliedOptionNames.contains("qpcrTestCount") || suppliedOptionNames.contains("qpcrDeltaG")) {
            throw PrimerSchemeDesignError.invalidRequest("varVAMP probe and qPCR controls require qPCR mode.")
        }
        try configOverrides.validate()
    }

    var json: [String: PrimerSchemeJSONValue] {
        ["cumulativeConsensusThreshold": cumulativeConsensusThreshold.map(PrimerSchemeJSONValue.number) ?? .null,
         "maximumPrimerAmbiguities": .integer(maximumPrimerAmbiguities),
         "maximumProbeAmbiguities": maximumProbeAmbiguities.map(PrimerSchemeJSONValue.integer) ?? .null,
         "tiledOverlap": .integer(tiledOverlap), "reportCount": reportCount.map(PrimerSchemeJSONValue.integer) ?? .null,
         "qpcrTestCount": .integer(qpcrTestCount), "qpcrDeltaG": .integer(qpcrDeltaG),
         "schemeName": .string(schemeName),
         "compatiblePrimersPath": compatiblePrimersPath.map(PrimerSchemeJSONValue.string) ?? .null,
         "blastDatabasePath": blastDatabasePath.map(PrimerSchemeJSONValue.string) ?? .null,
         "configOverrides": .object(configOverrides.json)]
    }

    var provenance: ParameterValue {
        let resolved = json.mapValues(\.parameterValue)
        return .dictionary(["supplied": .dictionary(resolved.filter { suppliedOptionNames.contains($0.key) }),
                            "resolved": .dictionary(resolved)])
    }
}

public struct PrimerSchemeDesignOptions: Codable, Equatable, Sendable {
    public static var defaultWorkers: Int { max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)) }
    public var engine: PrimerSchemeEngine
    public var mode: PrimerSchemeMode
    public var grouping: PrimerAnalysisGrouping
    public var nominalAmpliconLength: Int
    public var minimumAmpliconLength: Int
    public var maximumAmpliconLength: Int
    public var requestedMinimumAmpliconLength: Int?
    public var requestedMaximumAmpliconLength: Int?
    public var workers: Int
    public var suppliedOptionNames: Set<String>
    public var olivar: OlivarDesignOptions?
    public var varvamp: VarVAMPDesignOptions?

    public init(engine: PrimerSchemeEngine, mode: PrimerSchemeMode,
                grouping: PrimerAnalysisGrouping, nominalAmpliconLength: Int,
                minimumAmpliconLength: Int, maximumAmpliconLength: Int,
                requestedMinimumAmpliconLength: Int? = nil,
                requestedMaximumAmpliconLength: Int? = nil,
                workers: Int = Self.defaultWorkers,
                suppliedOptionNames: Set<String> = [], olivar: OlivarDesignOptions? = nil,
                varvamp: VarVAMPDesignOptions? = nil) {
        self.engine = engine; self.mode = mode; self.grouping = grouping
        self.nominalAmpliconLength = nominalAmpliconLength
        self.minimumAmpliconLength = minimumAmpliconLength
        self.maximumAmpliconLength = maximumAmpliconLength
        self.requestedMinimumAmpliconLength = requestedMinimumAmpliconLength
        self.requestedMaximumAmpliconLength = requestedMaximumAmpliconLength
        self.workers = workers
        self.suppliedOptionNames = suppliedOptionNames
        self.olivar = olivar; self.varvamp = varvamp
    }

    public func validate() throws {
        guard minimumAmpliconLength > 0,
              minimumAmpliconLength <= nominalAmpliconLength,
              nominalAmpliconLength <= maximumAmpliconLength, workers > 0 else {
            throw PrimerSchemeDesignError.invalidRequest("Amplicon sizes require positive minimum ≤ nominal target ≤ maximum and workers must be positive.")
        }
        switch engine {
        case .olivar:
            guard mode == .tiled, minimumAmpliconLength >= 120,
                  let olivar, varvamp == nil else {
                throw PrimerSchemeDesignError.invalidRequest("Olivar requires tiled mode, a minimum of at least 120 bp, and only Olivar settings.")
            }
            try olivar.validate()
        case .varvamp:
            guard grouping == .independent, olivar == nil, let varvamp else {
                throw PrimerSchemeDesignError.invalidRequest("varVAMP requires independent per-input grouping and only varVAMP settings.")
            }
            try varvamp.validate(mode: mode)
        }
    }

    var adapterOptions: [String: PrimerSchemeJSONValue] {
        var values: [String: PrimerSchemeJSONValue] = [
            "nominalAmpliconLength": .integer(nominalAmpliconLength),
            "minimumAmpliconLength": .integer(minimumAmpliconLength),
            "maximumAmpliconLength": .integer(maximumAmpliconLength),
            "workers": .integer(workers),
        ]
        if let olivar { values.merge(olivar.json) { _, new in new } }
        if let varvamp { values.merge(varvamp.json) { _, new in new } }
        return values
    }

    public var provenanceOptions: [String: ParameterValue] {
        let common: [String: ParameterValue] = [
            "engine": .string(engine.rawValue), "mode": .string(mode.rawValue),
            "grouping": .string(grouping.rawValue),
            "nominalAmpliconLength": .integer(nominalAmpliconLength),
            "minimumAmpliconLength": .integer(minimumAmpliconLength),
            "maximumAmpliconLength": .integer(maximumAmpliconLength),
            "requestedMinimumAmpliconLength": requestedMinimumAmpliconLength.map(ParameterValue.integer) ?? .null,
            "requestedMaximumAmpliconLength": requestedMaximumAmpliconLength.map(ParameterValue.integer) ?? .null,
            "workers": .integer(workers),
        ]
        var values = common
        values["common"] = .dictionary([
            "supplied": .dictionary(common.filter { suppliedOptionNames.contains($0.key) }),
            "resolved": .dictionary(common),
        ])
        if let olivar { values["olivar"] = olivar.provenance }
        if let varvamp { values["varvamp"] = varvamp.provenance }
        return values
    }
}
