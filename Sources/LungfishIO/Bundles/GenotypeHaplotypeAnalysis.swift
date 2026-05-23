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

    public init(
        id: String,
        assayID: String,
        displayName: String,
        speciesName: String,
        speciesCode: String,
        prefix: String,
        locusDefinitions: [GenotypeHaplotypeLocusDefinition]
    ) {
        self.id = id
        self.assayID = assayID
        self.displayName = displayName
        self.speciesName = speciesName
        self.speciesCode = speciesCode
        self.prefix = prefix
        self.locusDefinitions = locusDefinitions
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

    public init(name: String, diagnosticAlleles: [String], colorTokenIndex: Int? = nil) {
        self.name = name
        self.diagnosticAlleles = diagnosticAlleles
        self.colorTokenIndex = colorTokenIndex ?? HaplotypeColorToken.assigned(forName: name).canonicalIndex
    }

    private enum CodingKeys: String, CodingKey {
        case name, diagnosticAlleles, colorTokenIndex
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
        let callsBySample = Dictionary(grouping: calls, by: \.sample)
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
            guard observedDiagnostics.count == haplotype.diagnosticAlleles.count else { return nil }
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
