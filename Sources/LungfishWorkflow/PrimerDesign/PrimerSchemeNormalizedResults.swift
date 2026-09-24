import Foundation

public struct PrimerSchemeArtifact: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String
    public var byteSize: UInt64
    public var kind: String
    public init(path: String, sha256: String, byteSize: UInt64, kind: String) {
        self.path = path; self.sha256 = sha256; self.byteSize = byteSize; self.kind = kind
    }
}

public struct PrimerSchemeOligo: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var role: PrimerOligoRole
    public var sequence: String
    public var start: Int
    public var end: Int
    public var strand: PrimerOligoStrand
    public var assayIDs: [UUID]
    public var pool: String?
    public var nativeMetadata: [String: PrimerSchemeJSONValue]
    public init(id: UUID, name: String, role: PrimerOligoRole, sequence: String,
                start: Int, end: Int, strand: PrimerOligoStrand, assayIDs: [UUID],
                pool: String?, nativeMetadata: [String: PrimerSchemeJSONValue]) {
        self.id = id; self.name = name; self.role = role; self.sequence = sequence
        self.start = start; self.end = end; self.strand = strand; self.assayIDs = assayIDs
        self.pool = pool; self.nativeMetadata = nativeMetadata
    }
}

public struct PrimerSchemeAssay: Codable, Equatable, Sendable {
    public var id: UUID
    public var start: Int
    public var end: Int
    public var memberIDs: [UUID]
    public var pool: String?
    public var status: PrimerAssayStatus
    public var rank: Int?
    public var nativeMetadata: [String: PrimerSchemeJSONValue]
    public init(id: UUID, start: Int, end: Int, memberIDs: [UUID], pool: String?,
                status: PrimerAssayStatus, rank: Int?,
                nativeMetadata: [String: PrimerSchemeJSONValue]) {
        self.id = id; self.start = start; self.end = end; self.memberIDs = memberIDs
        self.pool = pool; self.status = status; self.rank = rank; self.nativeMetadata = nativeMetadata
    }
}

public struct PrimerSchemeTarget: Codable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var referencePath: String
    public var referenceID: String
    public var referenceLength: Int
    public var sourceInputID: UUID
    public var bindingProjectionPath: String
    public var assays: [PrimerSchemeAssay]
    public var oligos: [PrimerSchemeOligo]
    public init(id: UUID, label: String, referencePath: String, referenceID: String,
                referenceLength: Int, sourceInputID: UUID, bindingProjectionPath: String,
                assays: [PrimerSchemeAssay], oligos: [PrimerSchemeOligo]) {
        self.id = id; self.label = label; self.referencePath = referencePath
        self.referenceID = referenceID; self.referenceLength = referenceLength
        self.sourceInputID = sourceInputID; self.bindingProjectionPath = bindingProjectionPath
        self.assays = assays; self.oligos = oligos
    }
}

public struct PrimerSchemeResult: Codable, Equatable, Sendable {
    public var id: UUID
    public var inputIDs: [UUID]
    public var targets: [PrimerSchemeTarget]
    public init(id: UUID, inputIDs: [UUID], targets: [PrimerSchemeTarget]) {
        self.id = id; self.inputIDs = inputIDs; self.targets = targets
    }
}

public enum PrimerBindingProjectionBlockKind: String, Codable, CaseIterable, Sendable {
    case mapped, collapsed, synthetic
}

public struct PrimerBindingProjectionBlock: Codable, Equatable, Sendable {
    public var generatedStart: Int
    public var generatedEnd: Int
    public var sourceStart: Int?
    public var sourceEnd: Int?
    public var kind: PrimerBindingProjectionBlockKind
    public init(generatedStart: Int, generatedEnd: Int, sourceStart: Int?, sourceEnd: Int?,
                kind: PrimerBindingProjectionBlockKind) {
        self.generatedStart = generatedStart; self.generatedEnd = generatedEnd
        self.sourceStart = sourceStart; self.sourceEnd = sourceEnd; self.kind = kind
    }
}

public struct PrimerBindingProjection: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let coordinateConventionName = "zeroBasedHalfOpen"
    public var schemaVersion: Int
    public var coordinateConvention: String
    public var sourceInputID: UUID
    public var sourcePath: String
    public var generatedReferencePath: String
    public var sourceLength: Int
    public var generatedLength: Int
    public var blocks: [PrimerBindingProjectionBlock]
    public init(schemaVersion: Int = Self.currentSchemaVersion,
                coordinateConvention: String = Self.coordinateConventionName,
                sourceInputID: UUID, sourcePath: String, generatedReferencePath: String,
                sourceLength: Int, generatedLength: Int,
                blocks: [PrimerBindingProjectionBlock]) {
        self.schemaVersion = schemaVersion; self.coordinateConvention = coordinateConvention
        self.sourceInputID = sourceInputID; self.sourcePath = sourcePath
        self.generatedReferencePath = generatedReferencePath; self.sourceLength = sourceLength
        self.generatedLength = generatedLength; self.blocks = blocks
    }

    func validate(target: PrimerSchemeTarget) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              coordinateConvention == Self.coordinateConventionName,
              sourceInputID == target.sourceInputID,
              generatedReferencePath == target.referencePath,
              generatedLength == target.referenceLength,
              sourceLength > 0, generatedLength > 0, !blocks.isEmpty else {
            throw PrimerSchemeDesignError.contractViolation("Binding projection identity or dimensions are inconsistent.")
        }
        var nextGenerated = 0
        var lastSourceEnd = 0
        for block in blocks {
            guard block.generatedStart == nextGenerated, block.generatedEnd >= block.generatedStart,
                  block.generatedEnd <= generatedLength else {
                throw PrimerSchemeDesignError.contractViolation("Binding projection blocks must exactly and monotonically cover the generated reference.")
            }
            switch block.kind {
            case .mapped:
                guard block.generatedEnd > block.generatedStart,
                      let sourceStart = block.sourceStart, let sourceEnd = block.sourceEnd,
                      sourceStart >= lastSourceEnd, sourceEnd > sourceStart, sourceEnd <= sourceLength,
                      sourceEnd - sourceStart == block.generatedEnd - block.generatedStart else {
                    throw PrimerSchemeDesignError.contractViolation("Mapped binding blocks must be one-to-one source intervals.")
                }
                lastSourceEnd = sourceEnd
            case .collapsed:
                guard let sourceStart = block.sourceStart, let sourceEnd = block.sourceEnd,
                      sourceStart >= lastSourceEnd, sourceEnd > sourceStart, sourceEnd <= sourceLength else {
                    throw PrimerSchemeDesignError.contractViolation("Collapsed blocks must identify a valid nonempty source interval.")
                }
                lastSourceEnd = sourceEnd
            case .synthetic:
                guard block.generatedEnd > block.generatedStart,
                      block.sourceStart == nil, block.sourceEnd == nil else {
                    throw PrimerSchemeDesignError.contractViolation("Synthetic binding blocks cannot claim source coordinates.")
                }
            }
            nextGenerated = block.generatedEnd
        }
        guard nextGenerated == generatedLength else {
            throw PrimerSchemeDesignError.contractViolation("Binding projection does not cover the generated reference.")
        }
    }
}

public struct PrimerSchemeResultsDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let storedRelativePath = "results/primer-schemes-v1.json"
    public var schemaVersion: Int
    public var analysisID: UUID
    public var runID: UUID
    public var resultID: UUID
    public var engine: PrimerSchemeEngine
    public var engineVersion: String
    public var adapterVersion: String
    public var mode: PrimerSchemeMode
    public var resolvedOptions: [String: PrimerSchemeJSONValue]
    public var results: [PrimerSchemeResult]
    public var artifacts: [PrimerSchemeArtifact]
    public var provenancePath: String

    public init(schemaVersion: Int = Self.currentSchemaVersion, analysisID: UUID, runID: UUID,
                resultID: UUID, engine: PrimerSchemeEngine, engineVersion: String,
                adapterVersion: String, mode: PrimerSchemeMode,
                resolvedOptions: [String: PrimerSchemeJSONValue], results: [PrimerSchemeResult],
                artifacts: [PrimerSchemeArtifact], provenancePath: String) {
        self.schemaVersion = schemaVersion; self.analysisID = analysisID; self.runID = runID
        self.resultID = resultID; self.engine = engine; self.engineVersion = engineVersion
        self.adapterVersion = adapterVersion; self.mode = mode; self.resolvedOptions = resolvedOptions
        self.results = results; self.artifacts = artifacts; self.provenancePath = provenancePath
    }

    public func validateStructure(
        knownInputIDs: Set<UUID>, options: PrimerSchemeDesignOptions,
        projections: [String: PrimerBindingProjection]
    ) throws {
        try options.validate()
        guard engine == options.engine, mode == options.mode else {
            throw PrimerSchemeDesignError.contractViolation(
                "Stored result engine or mode differs from the requested design.")
        }
        try validateEnvelope(
            knownInputIDs: knownInputIDs, projections: projections,
            minimumAmpliconLength: options.minimumAmpliconLength,
            maximumAmpliconLength: options.maximumAmpliconLength)
    }

    /// Strictly validates a reopened normalized result using its adapter-resolved settings.
    /// Callers do not need to reconstruct mutable design options from untyped JSON.
    public func validateStored(
        knownInputIDs: Set<UUID>, projections: [String: PrimerBindingProjection]
    ) throws {
        let minimum = try requiredInteger("minimumAmpliconLength")
        let nominal = try requiredInteger("nominalAmpliconLength")
        let maximum = try requiredInteger("maximumAmpliconLength")
        let workers = try requiredInteger("workers")
        guard minimum > 0, minimum <= nominal, nominal <= maximum, workers > 0,
              engine != .olivar || (mode == .tiled && minimum >= 120),
              engine != .varvamp || [.single, .tiled, .qpcr].contains(mode) else {
            throw PrimerSchemeDesignError.contractViolation(
                "Stored resolved amplicon bounds, mode, or worker count are invalid.")
        }
        try validateStoredEngineSettings()
        try validateEnvelope(
            knownInputIDs: knownInputIDs, projections: projections,
            minimumAmpliconLength: minimum, maximumAmpliconLength: maximum)
    }

    private func validateEnvelope(
        knownInputIDs: Set<UUID>, projections: [String: PrimerBindingProjection],
        minimumAmpliconLength: Int, maximumAmpliconLength: Int
    ) throws {
        let expectedVersion = engine == .olivar ? "1.3.3" : "1.3.2"
        guard schemaVersion == Self.currentSchemaVersion,
              engineVersion == expectedVersion,
              adapterVersion == "1.0.0", !results.isEmpty,
              resolvedOptions.values.allSatisfy(\.isFinite),
              Self.safeRelativePath(provenancePath) else {
            throw PrimerSchemeDesignError.contractViolation("Result envelope identity, version, mode, or settings are invalid.")
        }
        let resultIDs = results.map(\.id)
        guard Set(resultIDs).count == resultIDs.count else {
            throw PrimerSchemeDesignError.contractViolation("Result IDs must be unique.")
        }
        var allTargetIDs = Set<UUID>(), allAssayIDs = Set<UUID>(), allOligoIDs = Set<UUID>()
        for result in results {
            let inputs = Set(result.inputIDs)
            guard !inputs.isEmpty, inputs.count == result.inputIDs.count,
                  inputs.isSubset(of: knownInputIDs), !result.targets.isEmpty else {
                throw PrimerSchemeDesignError.contractViolation("Result input membership is invalid.")
            }
            for target in result.targets {
                guard allTargetIDs.insert(target.id).inserted,
                      inputs.contains(target.sourceInputID),
                      !target.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !target.referenceID.isEmpty, target.referenceLength > 0,
                      Self.safeRelativePath(target.referencePath),
                      Self.safeRelativePath(target.bindingProjectionPath),
                      let projection = projections[target.bindingProjectionPath] else {
                    throw PrimerSchemeDesignError.contractViolation("Target identity, source membership, or artifact paths are invalid.")
                }
                try projection.validate(target: target)
                try Self.validateTarget(
                                        target, mode: mode,
                                        minimumAmpliconLength: minimumAmpliconLength,
                                        maximumAmpliconLength: maximumAmpliconLength,
                                        allAssayIDs: &allAssayIDs,
                                        allOligoIDs: &allOligoIDs)
            }
        }
    }

    private static func validateTarget(
        _ target: PrimerSchemeTarget, mode: PrimerSchemeMode,
        minimumAmpliconLength: Int, maximumAmpliconLength: Int,
        allAssayIDs: inout Set<UUID>, allOligoIDs: inout Set<UUID>
    ) throws {
        guard !target.assays.isEmpty, !target.oligos.isEmpty else {
            throw PrimerSchemeDesignError.contractViolation("A target must contain assays and oligos.")
        }
        let assayIDs = Set(target.assays.map(\.id))
        let oligoIDs = Set(target.oligos.map(\.id))
        guard assayIDs.count == target.assays.count, oligoIDs.count == target.oligos.count else {
            throw PrimerSchemeDesignError.contractViolation("Assay and oligo IDs must be unique within a target.")
        }
        for id in assayIDs where !allAssayIDs.insert(id).inserted {
            throw PrimerSchemeDesignError.contractViolation("Assay IDs must be globally unique.")
        }
        var names = Set<String>()
        for oligo in target.oligos {
            guard allOligoIDs.insert(oligo.id).inserted,
                  names.insert(oligo.name).inserted,
                  !oligo.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  oligo.start >= 0, oligo.end > oligo.start,
                  oligo.end <= target.referenceLength,
                  oligo.sequence.count == oligo.end - oligo.start,
                  Self.legalIUPAC(oligo.sequence), !oligo.assayIDs.isEmpty,
                  Set(oligo.assayIDs).count == oligo.assayIDs.count,
                  Set(oligo.assayIDs).isSubset(of: assayIDs),
                  oligo.pool.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
                  oligo.nativeMetadata.values.allSatisfy(\.isFinite) else {
                throw PrimerSchemeDesignError.contractViolation("Oligo identity, sequence, interval, or assay membership is invalid.")
            }
            guard (oligo.role == .forward && oligo.strand == .forward)
                    || (oligo.role == .reverse && oligo.strand == .reverse)
                    || oligo.role == .probe else {
                throw PrimerSchemeDesignError.contractViolation("Forward/reverse oligo roles require their native strand.")
            }
        }
        let oligoByID = Dictionary(uniqueKeysWithValues: target.oligos.map { ($0.id, $0) })
        for assay in target.assays {
            let members = Set(assay.memberIDs)
            guard assay.start >= 0, assay.end > assay.start, assay.end <= target.referenceLength,
                  (minimumAmpliconLength...maximumAmpliconLength).contains(assay.end - assay.start),
                  !members.isEmpty, members.count == assay.memberIDs.count,
                  members.isSubset(of: oligoIDs), assay.rank.map({ $0 >= 0 }) ?? true,
                  assay.pool.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
                  assay.nativeMetadata.values.allSatisfy(\.isFinite) else {
                throw PrimerSchemeDesignError.contractViolation("Assay span, rank, or member identity is invalid.")
            }
            let memberOligos = assay.memberIDs.compactMap { oligoByID[$0] }
            guard memberOligos.allSatisfy({ $0.start >= assay.start && $0.end <= assay.end
                && $0.assayIDs.contains(assay.id)
                && (assay.pool == nil || $0.pool == nil || assay.pool == $0.pool) }),
                  memberOligos.contains(where: { $0.role == .forward }),
                  memberOligos.contains(where: { $0.role == .reverse }) else {
                throw PrimerSchemeDesignError.contractViolation("Assay members are not reciprocal, contained, or strand-complete.")
            }
            if mode == .qpcr {
                let roleCounts = Dictionary(grouping: memberOligos, by: \.role).mapValues(\.count)
                guard roleCounts[.forward] == 1, roleCounts[.probe] == 1,
                      roleCounts[.reverse] == 1, memberOligos.count == 3 else {
                    throw PrimerSchemeDesignError.contractViolation(
                        "qPCR assays require exactly one LEFT, PROBE, and RIGHT member.")
                }
            }
        }
        for oligo in target.oligos {
            for assayID in oligo.assayIDs {
                guard target.assays.first(where: { $0.id == assayID })?.memberIDs.contains(oligo.id) == true else {
                    throw PrimerSchemeDesignError.contractViolation("Oligo-to-assay membership must be reciprocal.")
                }
            }
        }
    }

    private func requiredInteger(_ key: String) throws -> Int {
        guard case .integer(let value)? = resolvedOptions[key] else {
            throw PrimerSchemeDesignError.contractViolation(
                "Stored resolved option \(key) must be an integer.")
        }
        return value
    }

    private func validateStoredEngineSettings() throws {
        guard resolvedOptions["adapterResolution"]?.isObject == true else {
            throw PrimerSchemeDesignError.contractViolation(
                "Stored adapter resolution metadata is missing or malformed.")
        }
        let common = Set(["nominalAmpliconLength", "minimumAmpliconLength",
                          "maximumAmpliconLength", "workers", "adapterResolution"])
        switch engine {
        case .olivar:
            let expected = common.union([
                "minimumVariantFrequency", "degenerate", "align", "temperatureC",
                "salinityM", "maximumDimerDeltaG", "minimumGC", "maximumGC",
                "minimumComplexity", "maximumPrimerLength", "checkVariants", "seed",
                "effort", "forwardPrefix", "reversePrefix", "blastDatabasePath",
                "riskWeights",
            ])
            guard Set(resolvedOptions.keys) == expected,
                  resolvedOptions["minimumVariantFrequency"]?.isNumber == true,
                  resolvedOptions["degenerate"]?.isBoolean == true,
                  resolvedOptions["align"] == .boolean(false),
                  resolvedOptions["temperatureC"]?.isNumber == true,
                  resolvedOptions["salinityM"]?.isNumber == true,
                  resolvedOptions["maximumDimerDeltaG"]?.isNumber == true,
                  resolvedOptions["minimumGC"]?.isNumber == true,
                  resolvedOptions["maximumGC"]?.isNumber == true,
                  resolvedOptions["minimumComplexity"]?.isNumber == true,
                  resolvedOptions["maximumPrimerLength"]?.isInteger == true,
                  resolvedOptions["checkVariants"]?.isBoolean == true,
                  resolvedOptions["seed"]?.isInteger == true,
                  resolvedOptions["effort"]?.isInteger == true,
                  resolvedOptions["forwardPrefix"]?.isString == true,
                  resolvedOptions["reversePrefix"]?.isString == true,
                  resolvedOptions["blastDatabasePath"]?.isNullableString == true,
                  case .object(let risk)? = resolvedOptions["riskWeights"],
                  Set(risk.keys) == Set(["extremeGC", "lowComplexity", "nonSpecificity",
                                         "variation", "sensitivity", "combination"]),
                  risk.values.allSatisfy(\.isNumber) else {
                throw PrimerSchemeDesignError.contractViolation(
                    "Stored OliVar resolved settings do not match adapter schema v1.")
            }
        case .varvamp:
            let expected = common.union([
                "cumulativeConsensusThreshold", "maximumPrimerAmbiguities",
                "maximumProbeAmbiguities", "tiledOverlap", "reportCount",
                "qpcrTestCount", "qpcrDeltaG", "schemeName", "compatiblePrimersPath",
                "blastDatabasePath", "configOverrides",
            ])
            guard Set(resolvedOptions.keys) == expected,
                  resolvedOptions["cumulativeConsensusThreshold"]?.isNullableNumber == true,
                  resolvedOptions["maximumPrimerAmbiguities"]?.isInteger == true,
                  resolvedOptions["maximumProbeAmbiguities"]?.isNullableInteger == true,
                  resolvedOptions["tiledOverlap"]?.isInteger == true,
                  resolvedOptions["reportCount"]?.isNullableInteger == true,
                  resolvedOptions["qpcrTestCount"]?.isInteger == true,
                  resolvedOptions["qpcrDeltaG"]?.isInteger == true,
                  resolvedOptions["schemeName"]?.isString == true,
                  resolvedOptions["compatiblePrimersPath"]?.isNullableString == true,
                  resolvedOptions["blastDatabasePath"]?.isNullableString == true,
                  case .object(let overrides)? = resolvedOptions["configOverrides"],
                  Self.validStoredVarVAMPOverrides(overrides),
                  mode != .qpcr || resolvedOptions["cumulativeConsensusThreshold"]?.isNumber == true else {
                throw PrimerSchemeDesignError.contractViolation(
                    "Stored varVAMP resolved settings do not match adapter schema v1.")
            }
        }
    }

    private static func validStoredVarVAMPOverrides(
        _ values: [String: PrimerSchemeJSONValue]
    ) -> Bool {
        let numberKeys = Set(["TERMINAL_MASKING_THRESHOLD", "PRIMER_HAIRPIN",
                              "PRIMER_MAX_DIMER_TMP", "PRIMER_MAX_DIMER_DELTAG",
                              "QPRIMER_DIFF", "PCR_MV_CONC", "PCR_DV_CONC",
                              "PCR_DNTP_CONC", "PCR_DNA_CONC"])
        let integerKeys = Set(["PRIMER_MAX_POLYX", "PRIMER_MAX_DINUC_REPEATS",
                               "PRIMER_MIN_3_WITHOUT_AMB", "END_OVERLAP",
                               "QAMPLICON_DEL_CUTOFF"])
        let doubleTriplets = Set(["PRIMER_TMP", "PRIMER_GC_RANGE", "QPROBE_TMP",
                                  "QPROBE_GC_RANGE"])
        let intTriplets = Set(["PRIMER_SIZES", "QPROBE_SIZES"])
        let doublePairs = Set(["QPROBE_TEMP_DIFF", "QAMPLICON_GC"])
        let intPairs = Set(["PRIMER_GC_END", "QPROBE_GC_END", "QPROBE_DISTANCE"])
        let known = numberKeys.union(integerKeys).union(doubleTriplets).union(intTriplets)
            .union(doublePairs).union(intPairs)
        guard Set(values.keys).isSubset(of: known) else { return false }
        for (key, value) in values {
            if numberKeys.contains(key), !value.isNumber { return false }
            if integerKeys.contains(key), !value.isInteger { return false }
            if doubleTriplets.contains(key), !value.isNumberArray(count: 3) { return false }
            if intTriplets.contains(key), !value.isIntegerArray(count: 3) { return false }
            if doublePairs.contains(key), !value.isNumberArray(count: 2) { return false }
            if intPairs.contains(key), !value.isIntegerArray(count: 2) { return false }
        }
        return true
    }

    static func safeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.contains("\0") && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func legalIUPAC(_ sequence: String) -> Bool {
        !sequence.isEmpty && sequence.uppercased().allSatisfy { "ACGTRYSWKMBDHVN".contains($0) }
    }
}

private extension PrimerSchemeJSONValue {
    var isBoolean: Bool { if case .boolean = self { return true }; return false }
    var isInteger: Bool { if case .integer = self { return true }; return false }
    var isNumber: Bool {
        switch self { case .integer, .number: return isFinite; default: return false }
    }
    var isString: Bool { if case .string = self { return true }; return false }
    var isObject: Bool { if case .object = self { return true }; return false }
    var isNullableInteger: Bool { if case .null = self { return true }; return isInteger }
    var isNullableNumber: Bool { if case .null = self { return true }; return isNumber }
    var isNullableString: Bool { if case .null = self { return true }; return isString }
    func isNumberArray(count: Int) -> Bool {
        guard case .array(let values) = self, values.count == count else { return false }
        return values.allSatisfy(\.isNumber)
    }
    func isIntegerArray(count: Int) -> Bool {
        guard case .array(let values) = self, values.count == count else { return false }
        return values.allSatisfy(\.isInteger)
    }
}
