import Foundation
import LungfishCore

public struct GenotypeHaplotypeDefinitionRegistry: Codable, Equatable, Sendable {
    public let assays: [GenotypeHaplotypeAssay]
    public let defaultDefinitionSetID: String?

    public init(
        assays: [GenotypeHaplotypeAssay],
        defaultDefinitionSetID: String? = nil
    ) {
        self.assays = assays
        self.defaultDefinitionSetID = defaultDefinitionSetID
    }

    public func assay(id: String) -> GenotypeHaplotypeAssay? {
        assays.first { $0.id == id }
    }

    public func definitionSets(assayID: String, speciesCode: String? = nil) -> [GenotypeHaplotypeDefinitionSet] {
        guard let assay = assay(id: assayID) else { return [] }
        guard let speciesCode = speciesCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !speciesCode.isEmpty else {
            return assay.definitionSets
        }
        return assay.definitionSets.filter {
            $0.speciesCode.caseInsensitiveCompare(speciesCode) == .orderedSame
        }
    }

    public func definitionSet(id: String, assayID: String?) -> GenotypeHaplotypeDefinitionSet? {
        guard let assayID = assayID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !assayID.isEmpty else {
            return definitionSet(id: id)
        }
        return definitionSets(assayID: assayID).first { $0.id == id }
    }

    public func definitionSets(id: String) -> [GenotypeHaplotypeDefinitionSet] {
        assays.flatMap(\.definitionSets).filter { $0.id == id }
    }

    public func definitionSet(id: String) -> GenotypeHaplotypeDefinitionSet? {
        assays.lazy.flatMap(\.definitionSets).first { $0.id == id }
    }
}

public struct GenotypeHaplotypeAssay: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let definitionSets: [GenotypeHaplotypeDefinitionSet]

    public init(
        id: String,
        displayName: String,
        definitionSets: [GenotypeHaplotypeDefinitionSet]
    ) {
        self.id = id
        self.displayName = displayName
        self.definitionSets = definitionSets
    }
}

public struct GenotypeHaplotypeDefinitionSet: Codable, Equatable, Sendable {
    public let id: String
    public let assayID: String
    public let displayName: String
    public let speciesName: String
    public let speciesCode: String
    public let prefix: String
    public let locusDefinitions: [GenotypeHaplotypeLocusDefinition]
    /// Optional schema version for the set itself. Bumped each time the
    /// editor saves a change so downstream artifacts (LabKey export,
    /// provenance JSON) can record which version of the definition was
    /// used to make a call. nil for built-in sets that ship with Lungfish
    /// at the app's release version.
    public let schemaVersion: Int?
    /// ISO-8601 timestamp of the last edit. nil for built-in sets.
    public let lastModified: String?
    /// Free-text description of the change. Useful for explaining "added
    /// MHC-B alleles from pbaa.xlsx row 109" in the provenance trail.
    public let changeNote: String?

    private enum CodingKeys: String, CodingKey {
        case id, assayID, displayName, speciesName, speciesCode, prefix, locusDefinitions
        case schemaVersion, lastModified, changeNote
    }

    public init(
        id: String,
        assayID: String,
        displayName: String,
        speciesName: String,
        speciesCode: String,
        prefix: String,
        locusDefinitions: [GenotypeHaplotypeLocusDefinition],
        schemaVersion: Int? = nil,
        lastModified: String? = nil,
        changeNote: String? = nil
    ) {
        self.id = id
        self.assayID = assayID
        self.displayName = displayName
        self.speciesName = speciesName
        self.speciesCode = speciesCode
        self.prefix = prefix
        self.locusDefinitions = locusDefinitions
        self.schemaVersion = schemaVersion
        self.lastModified = lastModified
        self.changeNote = changeNote
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self.id = id
        self.assayID = try container.decodeIfPresent(String.self, forKey: .assayID)
            ?? GenotypeHaplotypeAssayIDResolver.assayID(forDefinitionSetID: id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.speciesName = try container.decode(String.self, forKey: .speciesName)
        self.speciesCode = try container.decode(String.self, forKey: .speciesCode)
        self.prefix = try container.decode(String.self, forKey: .prefix)
        self.locusDefinitions = try container.decode([GenotypeHaplotypeLocusDefinition].self, forKey: .locusDefinitions)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        self.lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
        self.changeNote = try container.decodeIfPresent(String.self, forKey: .changeNote)
    }
}

public struct GenotypeHaplotypeLocusDefinition: Codable, Equatable, Sendable {
    public let locus: String
    public let sourceLocus: String
    public let haplotypes: [GenotypeHaplotypeDefinition]

    public init(
        locus: String,
        sourceLocus: String,
        haplotypes: [GenotypeHaplotypeDefinition]
    ) {
        self.locus = locus
        self.sourceLocus = sourceLocus
        self.haplotypes = haplotypes
    }
}

public struct GenotypeHaplotypeDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let diagnosticAlleles: [String]
    public let colorTokenIndex: Int
    /// Minimum number of `diagnosticAlleles` that must be observed for
    /// this haplotype to match. `nil` means "all" (the strict notebook
    /// rule). Use a smaller integer when supplying multi-family
    /// supporting alleles so the call still succeeds when one or two
    /// families dropped out — this lets the inspector use rich
    /// diagnostic lists from the pbaa.xlsx workbook without requiring
    /// every single allele to be present.
    public let minimumMatches: Int?

    public init(name: String, diagnosticAlleles: [String], colorTokenIndex: Int? = nil, minimumMatches: Int? = nil) {
        self.name = name
        self.diagnosticAlleles = diagnosticAlleles
        self.colorTokenIndex = colorTokenIndex ?? HaplotypeColorToken.assigned(forName: name).canonicalIndex
        self.minimumMatches = minimumMatches
    }

    /// Effective threshold for matching: `minimumMatches` when set,
    /// otherwise the full diagnostic-allele count (the strict rule).
    public var effectiveMinimumMatches: Int {
        if let minimumMatches { return max(1, min(minimumMatches, diagnosticAlleles.count)) }
        return diagnosticAlleles.count
    }

    private enum CodingKeys: String, CodingKey {
        case name, diagnosticAlleles, colorTokenIndex, minimumMatches
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let diagnosticAlleles = try container.decode([String].self, forKey: .diagnosticAlleles)
        let colorTokenIndex = try container.decodeIfPresent(Int.self, forKey: .colorTokenIndex)
            ?? HaplotypeColorToken.assigned(forName: name).canonicalIndex
        self.name = name
        self.diagnosticAlleles = diagnosticAlleles
        self.colorTokenIndex = colorTokenIndex
        self.minimumMatches = try container.decodeIfPresent(Int.self, forKey: .minimumMatches)
    }
}

public enum GenotypeHaplotypeDiagnosticMatcher {
    public static func matches(genotype: String, diagnosticAllele: String) -> Bool {
        if genotype == diagnosticAllele { return true }
        let diagnosticTokens = normalizedTokens(from: diagnosticAllele)
        let genotypeTokens = normalizedTokens(from: genotype)
        for diagnostic in diagnosticTokens where diagnostic.count >= 3 {
            for token in genotypeTokens where tokenMatches(token, diagnostic: diagnostic) {
                return true
            }
        }
        return false
    }

    private static func tokenMatches(_ token: String, diagnostic: String) -> Bool {
        token == diagnostic
            || token.hasPrefix("\(diagnostic)_")
            || token.hasPrefix("\(diagnostic)g")
    }

    private static func normalizedTokens(from allele: String) -> Set<String> {
        let pieces = allele
            .split(separator: "|", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
            .map { String($0) }
        var tokens = Set<String>()
        for piece in pieces {
            let cleaned = piece
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            guard !cleaned.isEmpty else { continue }
            insertTokenVariants(cleaned, into: &tokens)
            insertTokenVariants(removingLeadingRunNumber(from: cleaned), into: &tokens)
            if let speciesFree = removingSpeciesPrefix(from: removingLeadingRunNumber(from: cleaned)) {
                insertTokenVariants(speciesFree, into: &tokens)
            }
        }
        return tokens
    }

    private static func insertTokenVariants(_ token: String, into tokens: inout Set<String>) {
        guard !token.isEmpty else { return }
        tokens.insert(token)
        if let range = token.range(of: #"g\d*$"#, options: .regularExpression) {
            let stripped = String(token[..<range.lowerBound])
            if !stripped.isEmpty { tokens.insert(stripped) }
        }
    }

    private static func removingLeadingRunNumber(from token: String) -> String {
        let parts = token.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].allSatisfy(\.isNumber) else { return token }
        return String(parts[1])
    }

    private static func removingSpeciesPrefix(from token: String) -> String? {
        let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let species = parts[0].lowercased()
        guard ["mafa", "mamu", "mane"].contains(species) else { return nil }
        return String(parts[1])
    }
}

public enum GenotypeHaplotypeLocusResolver {
    public static func canonicalLocusName(_ rawLocus: String) -> String {
        let trimmed = rawLocus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        var token = trimmed
        if token.uppercased().hasPrefix("MHC-") {
            token = String(token.dropFirst(4))
            if let speciesFree = speciesFreeToken(token) {
                token = speciesFree
            }
        } else if let speciesFree = speciesFreeToken(token) {
            token = speciesFree
        }
        token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercased = token.uppercased()
        if uppercased == "AG" || uppercased.hasPrefix("AG") {
            return "MHC-AG"
        }
        if uppercased == "A" || (uppercased.hasPrefix("A") && uppercased.dropFirst().allSatisfy(\.isNumber)) {
            return "MHC-A"
        }
        if uppercased == "B" || (uppercased.hasPrefix("B") && uppercased.dropFirst().allSatisfy(\.isNumber)) {
            return "MHC-B"
        }
        if uppercased.hasPrefix("DRB") {
            return "MHC-DRB"
        }
        for locus in ["DQA", "DQB", "DPA", "DPB"] where uppercased.hasPrefix(locus) {
            return "MHC-\(locus)"
        }
        if uppercased == "F" || uppercased == "G" || uppercased == "E" || uppercased == "70" {
            return "MHC-\(uppercased)"
        }
        if uppercased.hasPrefix("KIR") {
            return "KIR-\(uppercased)"
        }
        return "MHC-\(uppercased)"
    }

    public static func canonicalLocus(
        for call: ONTGenotypeCall,
        definitionSet: GenotypeHaplotypeDefinitionSet?
    ) -> String {
        let raw = canonicalLocusName(call.locusGroup)
        guard let definitionSet else { return raw }
        if let definition = definitionSet.locusDefinitions.first(where: {
            $0.locus == raw || canonicalLocusName($0.sourceLocus) == raw
        }) {
            return definition.locus
        }
        if let definition = definitionSet.locusDefinitions.first(where: { diagnosticCall(call, belongsTo: $0) }) {
            return definition.locus
        }
        return raw
    }

    public static func rawCall(_ call: ONTGenotypeCall, belongsTo definition: GenotypeHaplotypeLocusDefinition) -> Bool {
        let raw = canonicalLocusName(call.locusGroup)
        let definitionLocus = canonicalLocusName(definition.locus)
        let sourceLocus = canonicalLocusName(definition.sourceLocus)
        if raw == definition.locus || raw == definitionLocus || raw == sourceLocus {
            return true
        }
        switch definitionLocus {
        case "MHC-DQ":
            return raw == "MHC-DQA" || raw == "MHC-DQB"
        case "MHC-DP":
            return raw == "MHC-DPA" || raw == "MHC-DPB"
        default:
            return false
        }
    }

    public static func diagnosticCall(_ call: ONTGenotypeCall, belongsTo definition: GenotypeHaplotypeLocusDefinition) -> Bool {
        if rawCall(call, belongsTo: definition) { return true }
        guard allowsCrossFamilyDiagnostics(for: definition) else { return false }
        return definition.haplotypes.contains { haplotype in
            haplotype.diagnosticAlleles.contains {
                GenotypeHaplotypeDiagnosticMatcher.matches(genotype: call.genotype, diagnosticAllele: $0)
            }
        }
    }

    public static func allowsCrossFamilyDiagnostics(for definition: GenotypeHaplotypeLocusDefinition) -> Bool {
        let source = definition.sourceLocus.lowercased()
        switch canonicalLocusName(definition.sourceLocus) {
        case "MHC-A":
            return source.contains("mafa")
        case "MHC-DQ", "MHC-DP":
            return source.contains("mafa") || source == "mhc-dq" || source == "mhc-dp"
        default:
            return false
        }
    }

    private static func speciesFreeToken(_ token: String) -> String? {
        let runStripped = removeLeadingRunNumber(from: token)
        let parts = runStripped.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let species = parts[0].lowercased()
        guard ["mafa", "mamu", "mane"].contains(species) else { return nil }
        return String(parts[1])
    }

    private static func removeLeadingRunNumber(from token: String) -> String {
        let parts = token.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].allSatisfy(\.isNumber) else { return token }
        return String(parts[1])
    }
}

public enum GenotypeHaplotypeCallStatus: String, Codable, Equatable, Sendable {
    case called
    case notAssayed
    case noHaplotype
    case tooManyHaplotypes
    case tooManyGenotypes
    case specialCase
}

public struct GenotypeHaplotypeMatchedDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let diagnosticAlleles: [String]
    public let observedDiagnosticAlleles: [String]

    public init(
        name: String,
        diagnosticAlleles: [String],
        observedDiagnosticAlleles: [String]
    ) {
        self.name = name
        self.diagnosticAlleles = diagnosticAlleles
        self.observedDiagnosticAlleles = observedDiagnosticAlleles
    }
}

public struct GenotypeHaplotypeLocusCall: Codable, Equatable, Sendable {
    public let locus: String
    public let sourceLocus: String
    public let haplotype1: String
    public let haplotype2: String
    public let status: GenotypeHaplotypeCallStatus
    public let matchedHaplotypes: [GenotypeHaplotypeMatchedDefinition]
    public let observedGenotypeCount: Int
    public let observedGenotypes: [String]
    public let notes: String

    public init(
        locus: String,
        sourceLocus: String,
        haplotype1: String,
        haplotype2: String,
        status: GenotypeHaplotypeCallStatus,
        matchedHaplotypes: [GenotypeHaplotypeMatchedDefinition],
        observedGenotypeCount: Int,
        observedGenotypes: [String],
        notes: String = ""
    ) {
        self.locus = locus
        self.sourceLocus = sourceLocus
        self.haplotype1 = haplotype1
        self.haplotype2 = haplotype2
        self.status = status
        self.matchedHaplotypes = matchedHaplotypes
        self.observedGenotypeCount = observedGenotypeCount
        self.observedGenotypes = observedGenotypes
        self.notes = notes
    }
}

public struct GenotypeHaplotypeSampleAnalysis: Codable, Equatable, Sendable {
    public let sample: String
    public let calls: [GenotypeHaplotypeLocusCall]

    public init(sample: String, calls: [GenotypeHaplotypeLocusCall]) {
        self.sample = sample
        self.calls = calls
    }
}

public struct GenotypeHaplotypeAnalysis: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let assayID: String
    public let definitionSetID: String
    public let definitionSetName: String
    public let speciesName: String
    public let generatedAt: String?
    public let samples: [GenotypeHaplotypeSampleAnalysis]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, assayID, definitionSetID, definitionSetName, speciesName, generatedAt, samples
    }

    public init(
        schemaVersion: Int = 1,
        assayID: String,
        definitionSetID: String,
        definitionSetName: String,
        speciesName: String,
        generatedAt: String? = nil,
        samples: [GenotypeHaplotypeSampleAnalysis]
    ) {
        self.schemaVersion = schemaVersion
        self.assayID = assayID
        self.definitionSetID = definitionSetID
        self.definitionSetName = definitionSetName
        self.speciesName = speciesName
        self.generatedAt = generatedAt
        self.samples = samples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let definitionSetID = try container.decode(String.self, forKey: .definitionSetID)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.assayID = try container.decodeIfPresent(String.self, forKey: .assayID)
            ?? GenotypeHaplotypeAssayIDResolver.assayID(forDefinitionSetID: definitionSetID)
        self.definitionSetID = definitionSetID
        self.definitionSetName = try container.decode(String.self, forKey: .definitionSetName)
        self.speciesName = try container.decode(String.self, forKey: .speciesName)
        self.generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        self.samples = try container.decode([GenotypeHaplotypeSampleAnalysis].self, forKey: .samples)
    }
}

private enum GenotypeHaplotypeAssayIDResolver {
    static let defaultAssayID = "MHC-exon2-miSeq"

    static func assayID(forDefinitionSetID id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = trimmed.firstIndex(of: ".") {
            let prefix = String(trimmed[..<separator])
            if prefix == defaultAssayID {
                return defaultAssayID
            }
        }
        return defaultAssayID
    }
}

public enum GenotypeHaplotypeAnalyzer {
    public static func analyze(
        calls: [ONTGenotypeCall],
        definitionSet: GenotypeHaplotypeDefinitionSet,
        generatedAt: String? = nil
    ) -> GenotypeHaplotypeAnalysis {
        analyze(
            calls: calls,
            definitionSet: definitionSet,
            generatedAt: generatedAt,
            dropoutFilter: nil
        )
    }

    /// Re-analyze with an optional dropout filter applied to the raw calls
    /// before matching. Genotypes that fall below the per-locus threshold
    /// are dropped from each sample's observed set, then the standard
    /// subset-match algorithm runs. Use this from the inspector to support
    /// "live" threshold changes without touching the persisted pipeline
    /// output: the bundle's `haplotypeAnalysis` stays authoritative, while
    /// this re-analysis drives what the viewport renders.
    public static func analyze(
        calls: [ONTGenotypeCall],
        definitionSet: GenotypeHaplotypeDefinitionSet,
        generatedAt: String? = nil,
        dropoutFilter: GenotypeDropoutEvaluator?
    ) -> GenotypeHaplotypeAnalysis {
        let filteredCalls = applyDropout(calls, evaluator: dropoutFilter, definitionSet: definitionSet)
        let callsBySample = Dictionary(grouping: filteredCalls, by: { normalizedSampleName($0.sample) })
        let observedLoci = observedDefinitionLoci(calls: calls, definitionSet: definitionSet)
        let rawSampleNames = Set(calls.map { normalizedSampleName($0.sample) })
        let samples = rawSampleNames.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map { sample in
            let sampleCalls = callsBySample[sample] ?? []
            return GenotypeHaplotypeSampleAnalysis(
                sample: sample,
                calls: definitionSet.locusDefinitions.map { definition in
                    callHaplotype(
                        locusDefinition: definition,
                        calls: sampleCalls,
                        locusObservedInRun: observedLoci.contains(definition.locus)
                    )
                }
            )
        }
        let resolvedSamples = resolveLinkedMCMClassIIAmbiguousDP(in: samples, definitionSet: definitionSet)
        return GenotypeHaplotypeAnalysis(
            assayID: definitionSet.assayID,
            definitionSetID: definitionSet.id,
            definitionSetName: definitionSet.displayName,
            speciesName: definitionSet.speciesName,
            generatedAt: generatedAt,
            samples: resolvedSamples
        )
    }

    private static func resolveLinkedMCMClassIIAmbiguousDP(
        in samples: [GenotypeHaplotypeSampleAnalysis],
        definitionSet: GenotypeHaplotypeDefinitionSet
    ) -> [GenotypeHaplotypeSampleAnalysis] {
        guard definitionSet.speciesCode.caseInsensitiveCompare("MCM") == .orderedSame else {
            return samples
        }
        return samples.map { sample in
            guard let dqIndex = sample.calls.firstIndex(where: {
                GenotypeHaplotypeLocusResolver.canonicalLocusName($0.locus) == "MHC-DQ"
            }),
            let dpIndex = sample.calls.firstIndex(where: {
                GenotypeHaplotypeLocusResolver.canonicalLocusName($0.locus) == "MHC-DP"
            }) else {
                return sample
            }
            let dqCall = sample.calls[dqIndex]
            let dpCall = sample.calls[dpIndex]
            let resolved = resolveMCMClassIIDPCall(dpCall, usingLinkedDQ: dqCall)
            guard resolved != dpCall else { return sample }
            var calls = sample.calls
            calls[dpIndex] = resolved
            return GenotypeHaplotypeSampleAnalysis(sample: sample.sample, calls: calls)
        }
    }

    private static func resolveMCMClassIIDPCall(
        _ dpCall: GenotypeHaplotypeLocusCall,
        usingLinkedDQ dqCall: GenotypeHaplotypeLocusCall
    ) -> GenotypeHaplotypeLocusCall {
        let dqFamilies = linkedDQFamilies(from: dqCall)
        guard !dqFamilies.isEmpty else { return dpCall }

        if let resolved = resolveConcreteMCMClassIIDPOvercall(dpCall, dqFamilies: dqFamilies) {
            return resolved
        }

        let originalValues = [dpCall.haplotype1, dpCall.haplotype2]
        var usedResolvedFamilies = Set<String>()
        var resolvedValues: [String] = []
        for (index, value) in originalValues.enumerated() {
            let ambiguousFamilies = mcmFamilies(inAlleleName: value)
            guard ambiguousFamilies.count > 1 else {
                resolvedValues.append(value)
                if let family = mcmFamily(value) {
                    usedResolvedFamilies.insert(family)
                }
                continue
            }
            if let family = linkedMCMFamily(
                at: index,
                candidates: ambiguousFamilies,
                dqFamilies: dqFamilies,
                usedFamilies: usedResolvedFamilies
            ) {
                usedResolvedFamilies.insert(family)
                resolvedValues.append("\(family)DP")
            } else {
                resolvedValues.append(value)
            }
        }

        guard resolvedValues != originalValues else { return dpCall }
        let resolutionNotes = zip(originalValues, resolvedValues).compactMap { original, resolved -> String? in
            guard mcmFamilies(inAlleleName: original).count > 1, resolved != original else { return nil }
            return "MHC-DP \(original) ambiguity resolved to \(resolved) from linked MHC-DQ call."
        }
        let notes = ([dpCall.notes].filter { !$0.isEmpty } + resolutionNotes).joined(separator: " ")
        return GenotypeHaplotypeLocusCall(
            locus: dpCall.locus,
            sourceLocus: dpCall.sourceLocus,
            haplotype1: resolvedValues[0],
            haplotype2: resolvedValues[1],
            status: dpCall.status,
            matchedHaplotypes: dpCall.matchedHaplotypes,
            observedGenotypeCount: dpCall.observedGenotypeCount,
            observedGenotypes: dpCall.observedGenotypes,
            notes: notes
        )
    }

    private static func resolveConcreteMCMClassIIDPOvercall(
        _ dpCall: GenotypeHaplotypeLocusCall,
        dqFamilies: [String?]
    ) -> GenotypeHaplotypeLocusCall? {
        guard dpCall.matchedHaplotypes.count > 1 else { return nil }
        var matchByFamily: [String: GenotypeHaplotypeMatchedDefinition] = [:]
        for matched in dpCall.matchedHaplotypes {
            let families = mcmFamilies(inAlleleName: matched.name)
            guard families.count == 1, let family = families.first else { continue }
            matchByFamily[family] = matchByFamily[family] ?? matched
        }
        let matchedFamilies = Set(matchByFamily.keys)
        guard matchedFamilies.count > 1 else { return nil }

        var selectedFamilies: [String] = []
        for family in dqFamilies.compactMap({ $0 }) where matchByFamily[family] != nil {
            if !selectedFamilies.contains(family) {
                selectedFamilies.append(family)
            }
        }
        let selectedFamilySet = Set(selectedFamilies)
        guard !selectedFamilies.isEmpty,
              selectedFamilySet.count < matchedFamilies.count,
              selectedFamilies.count <= 2 else {
            return nil
        }

        let selectedMatches = selectedFamilies.compactMap { matchByFamily[$0] }
        let haplotype1 = selectedMatches[0].name
        let haplotype2 = selectedMatches.count > 1 ? selectedMatches[1].name : "-"
        let original = dpCall.matchedHaplotypes.map(\.name).joined(separator: ", ")
        let resolved = selectedMatches.map(\.name).joined(separator: ", ")
        let resolutionNote = "MHC-DP ambiguity resolved from linked MHC-DQ call: \(original) -> \(resolved)."
        let notes = ([dpCall.notes].filter { !$0.isEmpty } + [resolutionNote]).joined(separator: " ")

        return GenotypeHaplotypeLocusCall(
            locus: dpCall.locus,
            sourceLocus: dpCall.sourceLocus,
            haplotype1: haplotype1,
            haplotype2: haplotype2,
            status: .called,
            matchedHaplotypes: selectedMatches,
            observedGenotypeCount: dpCall.observedGenotypeCount,
            observedGenotypes: dpCall.observedGenotypes,
            notes: notes
        )
    }

    private static func linkedDQFamilies(from dqCall: GenotypeHaplotypeLocusCall) -> [String?] {
        guard dqCall.status == .called || dqCall.status == .specialCase else { return [] }
        return [dqCall.haplotype1, dqCall.haplotype2].map { value in
            guard !value.isEmpty,
                  value != "-",
                  value != "Not assayed",
                  !value.hasPrefix("ERR:") else {
                return nil
            }
            return mcmFamily(value)
        }
    }

    private static func linkedMCMFamily(
        at index: Int,
        candidates: Set<String>,
        dqFamilies: [String?],
        usedFamilies: Set<String>
    ) -> String? {
        if dqFamilies.indices.contains(index),
           let sameSlot = dqFamilies[index],
           candidates.contains(sameSlot) {
            return sameSlot
        }
        let available = dqFamilies.compactMap { family -> String? in
            guard let family, candidates.contains(family), !usedFamilies.contains(family) else {
                return nil
            }
            return family
        }
        return Set(available).count == 1 ? available[0] : nil
    }

    private static func mcmFamily(_ value: String?) -> String? {
        guard let value else { return nil }
        let pattern = #"\bM[1-7]"#
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(value[range])
    }

    /// Apply the dropout evaluator: for each (sample, locus group), drop
    /// calls whose per-allele read count is below the effective threshold
    /// (global + per-locus override). Calls are kept by default when the
    /// evaluator is nil. This is the recalculation hook the per-locus EQ
    /// section needs to make haplotype calls "live."
    private static func applyDropout(
        _ calls: [ONTGenotypeCall],
        evaluator: GenotypeDropoutEvaluator?,
        definitionSet: GenotypeHaplotypeDefinitionSet
    ) -> [ONTGenotypeCall] {
        guard let evaluator else { return calls }
        // Build sample × locus-group totals once so the evaluator gets the
        // correct denominator for the ratio tests.
        var sampleTotals: [String: Int] = [:]
        var sampleLocusTotals: [String: [String: Int]] = [:]
        let canonicalDefinitionLocusByRawLocus = canonicalLocusLookup(for: definitionSet)
        for call in calls {
            let sample = normalizedSampleName(call.sample)
            sampleTotals[sample, default: 0] += max(0, call.passedUniqueReads)
            sampleLocusTotals[sample, default: [:]][call.locusGroup, default: 0] += max(0, call.passedUniqueReads)
        }
        return calls.filter { call in
            let sample = normalizedSampleName(call.sample)
            let sampleTotal = sampleTotals[sample] ?? 0
            let locusTotal = sampleLocusTotals[sample]?[call.locusGroup] ?? 0
            let rawLocus = GenotypeHaplotypeLocusResolver.canonicalLocusName(call.locusGroup)
            let canonicalLocus = canonicalDefinitionLocusByRawLocus[rawLocus]
                ?? GenotypeHaplotypeLocusResolver.canonicalLocus(
                    for: call,
                    definitionSet: definitionSet
                )
            return !evaluator.isLowSupport(
                reads: call.passedUniqueReads,
                sampleTotal: sampleTotal,
                locusTotal: locusTotal,
                locus: canonicalLocus
            )
        }
    }

    private static func normalizedSampleName(_ sample: String) -> String {
        let cleaned = sample
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? sample : cleaned
    }

    private static func canonicalLocusLookup(
        for definitionSet: GenotypeHaplotypeDefinitionSet
    ) -> [String: String] {
        var lookup: [String: String] = [:]
        for definition in definitionSet.locusDefinitions {
            let definitionLocus = GenotypeHaplotypeLocusResolver.canonicalLocusName(definition.locus)
            lookup[definitionLocus] = definition.locus
            lookup[GenotypeHaplotypeLocusResolver.canonicalLocusName(definition.sourceLocus)] = definition.locus
            switch definitionLocus {
            case "MHC-DQ":
                lookup["MHC-DQA"] = definition.locus
                lookup["MHC-DQB"] = definition.locus
            case "MHC-DP":
                lookup["MHC-DPA"] = definition.locus
                lookup["MHC-DPB"] = definition.locus
            default:
                break
            }
        }
        return lookup
    }

    private static func callHaplotype(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        calls: [ONTGenotypeCall],
        locusObservedInRun: Bool
    ) -> GenotypeHaplotypeLocusCall {
        let observedGenotypeSet = Set(calls.map(\.genotype))
        let diagnosticCalls = calls.filter {
            GenotypeHaplotypeLocusResolver.diagnosticCall($0, belongsTo: locusDefinition)
        }
        let observedGenotypes = diagnosticCalls
            .map(\.genotype)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var matched = locusDefinition.haplotypes.compactMap { haplotype -> GenotypeHaplotypeMatchedDefinition? in
            let observedDiagnostics = haplotype.diagnosticAlleles.filter { allele in
                diagnosticCalls.contains { call in
                    GenotypeHaplotypeDiagnosticMatcher.matches(
                        genotype: call.genotype,
                        diagnosticAllele: allele
                    )
                }
            }
            // Haplotypes can opt into a "K of N" rule by setting
            // `minimumMatches`. The default behaviour (no override)
            // remains the strict "all alleles must be observed" rule
            // the notebook uses — preserves backwards compatibility for
            // any caller that hasn't specified a threshold.
            guard observedDiagnostics.count >= haplotype.effectiveMinimumMatches
                    || usesMCMAClassIGAGSpecificRescue(
                        locusDefinition: locusDefinition,
                        haplotype: haplotype,
                        observedDiagnostics: observedDiagnostics
                    ) else { return nil }
            return GenotypeHaplotypeMatchedDefinition(
                name: haplotype.name,
                diagnosticAlleles: haplotype.diagnosticAlleles,
                observedDiagnosticAlleles: observedDiagnostics
            )
        }
        matched = trimMCMClassIARescueOvercalls(
            matched,
            locusDefinition: locusDefinition
        )

        var haplotype1: String
        var haplotype2: String
        var status: GenotypeHaplotypeCallStatus
        var notes = ""

        if matched.isEmpty, !locusObservedInRun, observedGenotypes.isEmpty {
            haplotype1 = "Not assayed"
            haplotype2 = "Not assayed"
            status = .notAssayed
            notes = "\(locusDefinition.locus) was not observed anywhere in this run for the active definition set. Treat this as assay/reference coverage not available, not as a sample-level haplotype failure."
        } else if matched.isEmpty {
            if usesMCMUndercalledA1063SpecialCase(locusDefinition: locusDefinition, observedGenotypes: observedGenotypeSet) {
                haplotype1 = "A1_063"
                haplotype2 = "-"
                status = .specialCase
                notes = "Notebook-compatible MCM MHC-A special case: A1_063 diagnostic sequence observed without a full M1A/M2A/M3A match."
            } else {
                haplotype1 = "ERR: NO HAP"
                haplotype2 = "ERR: NO HAP"
                status = .noHaplotype
            }
        } else if matched.count == 1 {
            haplotype1 = matched[0].name
            if usesMCMUndercalledA1063SpecialCase(locusDefinition: locusDefinition, observedGenotypes: observedGenotypeSet),
               !["M1A", "M2A", "M3A"].contains(where: { matched[0].name.contains($0) }) {
                haplotype2 = "A1_063"
                status = .specialCase
                notes = "Notebook-compatible MCM MHC-A special case: A1_063 observed in addition to one non-M1/M2/M3 haplotype."
            } else {
                haplotype2 = "-"
                status = .called
            }
        } else if matched.count == 2 {
            haplotype1 = matched[0].name
            haplotype2 = matched[1].name
            status = .called
        } else {
            let joined = matched.map(\.name).joined(separator: ", ")
            haplotype1 = "ERR: TMH (\(joined))"
            haplotype2 = "ERR: TMH (\(joined))"
            status = .tooManyHaplotypes
        }

        if status != .notAssayed,
           diploidClassIILocusHasTooManyGenotypes(locusDefinition: locusDefinition, calls: calls) {
            haplotype1 = "ERR: TMG"
            haplotype2 = "ERR: TMG"
            status = .tooManyGenotypes
        }

        return GenotypeHaplotypeLocusCall(
            locus: locusDefinition.locus,
            sourceLocus: locusDefinition.sourceLocus,
            haplotype1: haplotype1,
            haplotype2: haplotype2,
            status: status,
            matchedHaplotypes: matched,
            observedGenotypeCount: observedGenotypes.count,
            observedGenotypes: observedGenotypes,
            notes: notes
        )
    }

    private static func usesMCMAClassIGAGSpecificRescue(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        haplotype: GenotypeHaplotypeDefinition,
        observedDiagnostics: [String]
    ) -> Bool {
        guard locusDefinition.sourceLocus == "Mafa-A",
              ["M1A", "M2A", "M3A"].contains(haplotype.name),
              !observedDiagnostics.isEmpty else {
            return false
        }
        let expectedFamily = String(haplotype.name.prefix(2))
        return observedDiagnostics.contains { allele in
            mcmFamilies(inAlleleName: allele) == Set([expectedFamily])
        }
    }

    private static func trimMCMClassIARescueOvercalls(
        _ matched: [GenotypeHaplotypeMatchedDefinition],
        locusDefinition: GenotypeHaplotypeLocusDefinition
    ) -> [GenotypeHaplotypeMatchedDefinition] {
        guard locusDefinition.sourceLocus == "Mafa-A",
              matched.count > 2 else {
            return matched
        }
        let definitionsByName = Dictionary(uniqueKeysWithValues: locusDefinition.haplotypes.map { ($0.name, $0) })
        let strict = matched.filter { match in
            guard let definition = definitionsByName[match.name] else { return true }
            return match.observedDiagnosticAlleles.count >= definition.effectiveMinimumMatches
        }
        guard strict.count >= 2 else {
            return matched
        }
        return Array(strict.prefix(2))
    }

    private static func mcmFamilies(inAlleleName allele: String) -> Set<String> {
        let pattern = #"M[1-7]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(allele.startIndex..<allele.endIndex, in: allele)
        return Set(regex.matches(in: allele, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: allele) else { return nil }
            return String(allele[tokenRange])
        })
    }

    private static func observedDefinitionLoci(
        calls: [ONTGenotypeCall],
        definitionSet: GenotypeHaplotypeDefinitionSet
    ) -> Set<String> {
        var observed = Set<String>()
        for call in calls {
            let raw = GenotypeHaplotypeLocusResolver.canonicalLocusName(call.locusGroup)
            for definition in definitionSet.locusDefinitions where
                raw == definition.locus
                    || raw == GenotypeHaplotypeLocusResolver.canonicalLocusName(definition.sourceLocus)
                    || GenotypeHaplotypeLocusResolver.diagnosticCall(call, belongsTo: definition) {
                observed.insert(definition.locus)
            }
        }
        return observed
    }

    private static func usesMCMUndercalledA1063SpecialCase(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        observedGenotypes: Set<String>
    ) -> Bool {
        locusDefinition.sourceLocus == "Mafa-A" && observedGenotypes.contains("05_M1M2M3_A1_063g")
    }

    private static func diploidClassIILocusHasTooManyGenotypes(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        calls: [ONTGenotypeCall]
    ) -> Bool {
        let definitionLocus = GenotypeHaplotypeLocusResolver.canonicalLocusName(locusDefinition.sourceLocus)
        let diploidLoci = Set(["MHC-DPA", "MHC-DPB", "MHC-DQA", "MHC-DQB", "MHC-DP", "MHC-DQ"])
        guard diploidLoci.contains(definitionLocus) else {
            return false
        }
        let rawCounts = Dictionary(grouping: calls.filter {
            GenotypeHaplotypeLocusResolver.rawCall($0, belongsTo: locusDefinition)
        }, by: { GenotypeHaplotypeLocusResolver.canonicalLocusName($0.locusGroup) })
        return rawCounts.values.contains { $0.count > 2 }
    }
}
