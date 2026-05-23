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

public enum GenotypeHaplotypeCallStatus: String, Codable, Equatable, Sendable {
    case called
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
        let callsBySample = Dictionary(grouping: filteredCalls, by: \.sample)
        let samples = callsBySample.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map { sample in
            let sampleCalls = callsBySample[sample] ?? []
            return GenotypeHaplotypeSampleAnalysis(
                sample: sample,
                calls: definitionSet.locusDefinitions.map { definition in
                    callHaplotype(locusDefinition: definition, calls: sampleCalls)
                }
            )
        }
        return GenotypeHaplotypeAnalysis(
            assayID: definitionSet.assayID,
            definitionSetID: definitionSet.id,
            definitionSetName: definitionSet.displayName,
            speciesName: definitionSet.speciesName,
            generatedAt: generatedAt,
            samples: samples
        )
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
        for call in calls {
            sampleTotals[call.sample, default: 0] += max(0, call.passedUniqueReads)
            sampleLocusTotals[call.sample, default: [:]][call.locusGroup, default: 0] += max(0, call.passedUniqueReads)
        }
        // Resolve the canonical inspector locus name (e.g. "MHC-A") for a
        // raw call's locusGroup so the per-locus EQ overrides find their
        // target. Build the mapping from both directions so the lookup
        // works whether the bundle exposes raw "Mafa-A" / "MHC-A" / the
        // canonical name directly: try locusGroup as-is, then look it up
        // by sourceLocus, then fall through to locusGroup itself.
        let canonicalByGroup: [String: String] = Dictionary(
            uniqueKeysWithValues: definitionSet.locusDefinitions.flatMap {
                [($0.locus, $0.locus), ($0.sourceLocus, $0.locus)]
            }
        )
        return calls.filter { call in
            let sampleTotal = sampleTotals[call.sample] ?? 0
            let locusTotal = sampleLocusTotals[call.sample]?[call.locusGroup] ?? 0
            let canonicalLocus = canonicalByGroup[call.locusGroup] ?? call.locusGroup
            return !evaluator.isLowSupport(
                reads: call.passedUniqueReads,
                sampleTotal: sampleTotal,
                locusTotal: locusTotal,
                locus: canonicalLocus
            )
        }
    }

    private static func callHaplotype(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        calls: [ONTGenotypeCall]
    ) -> GenotypeHaplotypeLocusCall {
        let alleleText = calls.map(\.genotype).joined(separator: "\n")
        let observedGenotypes = calls
            .filter { genotype($0.genotype, belongsTo: locusDefinition.sourceLocus) }
            .map(\.genotype)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        let matched = locusDefinition.haplotypes.compactMap { haplotype -> GenotypeHaplotypeMatchedDefinition? in
            let observedDiagnostics = haplotype.diagnosticAlleles.filter { alleleText.contains($0) }
            // Haplotypes can opt into a "K of N" rule by setting
            // `minimumMatches`. The default behaviour (no override)
            // remains the strict "all alleles must be observed" rule
            // the notebook uses — preserves backwards compatibility for
            // any caller that hasn't specified a threshold.
            guard observedDiagnostics.count >= haplotype.effectiveMinimumMatches else { return nil }
            return GenotypeHaplotypeMatchedDefinition(
                name: haplotype.name,
                diagnosticAlleles: haplotype.diagnosticAlleles,
                observedDiagnosticAlleles: observedDiagnostics
            )
        }

        var haplotype1: String
        var haplotype2: String
        var status: GenotypeHaplotypeCallStatus
        var notes = ""

        if matched.isEmpty {
            if usesMCMUndercalledA1063SpecialCase(locusDefinition: locusDefinition, alleleText: alleleText) {
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
            if usesMCMUndercalledA1063SpecialCase(locusDefinition: locusDefinition, alleleText: alleleText),
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

        if diploidClassIILocusHasTooManyGenotypes(locusDefinition: locusDefinition, calls: calls) {
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

    private static func usesMCMUndercalledA1063SpecialCase(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        alleleText: String
    ) -> Bool {
        locusDefinition.sourceLocus == "Mafa-A" && alleleText.contains("05_M1M2M3_A1_063g")
    }

    private static func diploidClassIILocusHasTooManyGenotypes(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        calls: [ONTGenotypeCall]
    ) -> Bool {
        let diploidTokens = ["DPA", "DPB", "DQA", "DQB"]
        guard let token = diploidTokens.first(where: { locusDefinition.sourceLocus.contains($0) }) else {
            return false
        }
        return calls.filter { $0.genotype.contains(token) }.count > 2
    }

    private static func genotype(_ genotype: String, belongsTo sourceLocus: String) -> Bool {
        guard let locusToken = sourceLocus.split(separator: "-").last.map(String.init) else {
            return false
        }
        return genotype.contains(locusToken)
    }
}
