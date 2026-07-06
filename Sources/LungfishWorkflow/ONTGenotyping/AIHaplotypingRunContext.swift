import Foundation
import LungfishIO

public struct AIHaplotypingRunContext: Codable, Equatable, Sendable {
    public let speciesPrefix: String
    public let populationHint: String
    public let assayResolution: String
    public let workflowKind: String
    public let haplotypeFrameworkHint: String
    public let haplotypeDefinitionSetID: String?
    public let haplotypeAssayID: String?
    public let observedRegions: [String]
    public let notes: [String]

    public init(
        speciesPrefix: String,
        populationHint: String,
        assayResolution: String,
        workflowKind: String,
        haplotypeFrameworkHint: String,
        haplotypeDefinitionSetID: String?,
        haplotypeAssayID: String?,
        observedRegions: [String],
        notes: [String]
    ) {
        self.speciesPrefix = speciesPrefix
        self.populationHint = populationHint
        self.assayResolution = assayResolution
        self.workflowKind = workflowKind
        self.haplotypeFrameworkHint = haplotypeFrameworkHint
        self.haplotypeDefinitionSetID = haplotypeDefinitionSetID
        self.haplotypeAssayID = haplotypeAssayID
        self.observedRegions = observedRegions.sorted()
        self.notes = notes
    }

    public static func infer(from result: ONTGenotypeResultBundleData) -> AIHaplotypingRunContext {
        let definitionSetID = trimmed(result.manifest.haplotypeDefinitionSetID)
            ?? trimmed(result.haplotypeAnalysis?.definitionSetID)
        let assayID = trimmed(result.manifest.haplotypeAssayID)
            ?? trimmed(result.haplotypeAnalysis?.assayID)
        let genotypes = result.calls.map(\.genotype)
        let speciesPrefix = inferSpeciesPrefix(
            genotypes: genotypes,
            definitionSetID: definitionSetID,
            speciesName: result.haplotypeAnalysis?.speciesName
        )
        let populationHint = inferPopulationHint(
            speciesPrefix: speciesPrefix,
            definitionSetID: definitionSetID,
            genotypes: genotypes
        )
        let assayResolution = inferAssayResolution(
            assayID: assayID,
            definitionSetID: definitionSetID,
            genotypes: genotypes
        )
        let frameworkHint = inferFrameworkHint(populationHint: populationHint, speciesPrefix: speciesPrefix)
        let observedRegions = Set(result.calls.map { region(for: $0) })
            .filter { !$0.isEmpty && $0 != "Unknown" }
        return AIHaplotypingRunContext(
            speciesPrefix: speciesPrefix,
            populationHint: populationHint,
            assayResolution: assayResolution,
            workflowKind: result.manifest.kind,
            haplotypeFrameworkHint: frameworkHint,
            haplotypeDefinitionSetID: definitionSetID,
            haplotypeAssayID: assayID,
            observedRegions: Array(observedRegions),
            notes: notes(
                populationHint: populationHint,
                assayResolution: assayResolution,
                observedRegions: observedRegions,
                definitionSetID: definitionSetID
            )
        )
    }

    private static func inferSpeciesPrefix(
        genotypes: [String],
        definitionSetID: String?,
        speciesName: String?
    ) -> String {
        let joined = ([definitionSetID, speciesName].compactMap { $0 } + genotypes)
            .joined(separator: " ")
        if joined.range(of: "Mamu", options: .caseInsensitive) != nil
            || joined.range(of: "mulatta", options: .caseInsensitive) != nil {
            return "Mamu"
        }
        if joined.range(of: "Mafa", options: .caseInsensitive) != nil
            || joined.range(of: "cynomolgus", options: .caseInsensitive) != nil
            || joined.range(of: "mauritian", options: .caseInsensitive) != nil {
            return "Mafa"
        }
        return "unknown"
    }

    private static func inferPopulationHint(
        speciesPrefix: String,
        definitionSetID: String?,
        genotypes: [String]
    ) -> String {
        let joined = ([definitionSetID].compactMap { $0 } + genotypes).joined(separator: " ")
        if joined.range(of: "mauritian", options: .caseInsensitive) != nil
            || joined.range(of: "M1M2M3", options: .caseInsensitive) != nil
            || joined.range(of: "MCM", options: .caseInsensitive) != nil {
            return "mcm"
        }
        if speciesPrefix == "Mamu" {
            return "indian-rhesus"
        }
        if speciesPrefix == "Mafa" {
            return "other-macaque"
        }
        return "unknown"
    }

    private static func inferAssayResolution(
        assayID: String?,
        definitionSetID: String?,
        genotypes: [String]
    ) -> String {
        let joined = ([assayID, definitionSetID].compactMap { $0 } + genotypes).joined(separator: " ")
        if joined.range(of: "full-length", options: .caseInsensitive) != nil
            || joined.range(of: "full_length", options: .caseInsensitive) != nil
            || joined.contains("*") {
            return "full_length_or_high_resolution"
        }
        if joined.range(of: "miseq", options: .caseInsensitive) != nil
            || joined.range(of: "short-exon", options: .caseInsensitive) != nil
            || joined.range(of: "short_exon", options: .caseInsensitive) != nil
            || joined.range(of: "156bp", options: .caseInsensitive) != nil
            || joined.range(of: "g1", options: .caseInsensitive) != nil
            || joined.range(of: "g2", options: .caseInsensitive) != nil
            || joined.range(of: "g3", options: .caseInsensitive) != nil {
            return "short_exon_amplicon"
        }
        return "unknown"
    }

    private static func inferFrameworkHint(populationHint: String, speciesPrefix: String) -> String {
        switch populationHint {
        case "mcm":
            return "mcm-m1-m7"
        case "indian-rhesus":
            return "indian-rhesus-regional-blocks"
        default:
            if speciesPrefix == "Mamu" {
                return "indian-rhesus-regional-blocks"
            }
            return "population-specific-or-provisional"
        }
    }

    private static func region(for call: ONTGenotypeCall) -> String {
        GenotypeHaplotypeLocusResolver.haplotypeEvidenceLocusName(call.locusGroup)
    }

    private static func notes(
        populationHint: String,
        assayResolution: String,
        observedRegions: Set<String>,
        definitionSetID: String?
    ) -> [String] {
        var notes: [String] = []
        if populationHint == "mcm" {
            notes.append("MCM context: use M1-M7 extended haplotypes as the primary framework and treat new whole-MHC haplotypes as unlikely without strong multi-region evidence.")
        }
        if populationHint == "indian-rhesus" {
            notes.append("Indian rhesus context: use regional block labels rather than forcing whole-MHC haplotypes.")
        }
        if assayResolution == "full_length_or_high_resolution" {
            notes.append("Detected full-length or high-resolution allele nomenclature; do not split familiar report haplotypes only because a subtle private full-length variant is present.")
        }
        if observedRegions.contains("MHC-A") {
            notes.append("MHC-A haplotypes may be supported by mapped class-I neighborhood evidence such as AG and G markers when the markers cohere.")
        }
        if let definitionSetID {
            notes.append("Active haplotype definition set: \(definitionSetID).")
        }
        return notes
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
