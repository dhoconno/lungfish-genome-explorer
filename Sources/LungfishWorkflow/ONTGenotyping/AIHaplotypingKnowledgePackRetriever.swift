import Foundation

public enum AIHaplotypingKnowledgePackRetriever {
    public static func compact(
        _ pack: AIHaplotypingKnowledgePack,
        for registry: AIHaplotypingEvidenceRegistry,
        runContext: AIHaplotypingRunContext
    ) -> AIHaplotypingKnowledgePack {
        let observedRegions = chunkObservedRegions(registry: registry)
        let observedTerms = observedSearchTerms(
            registry: registry,
            runContext: runContext,
            observedRegions: observedRegions
        )
        let observedAlleleTerms = observedAlleleSearchTerms(registry: registry)
        let population = normalized(runContext.populationHint)
        let speciesPrefix = normalized(runContext.speciesPrefix)
        let framework = normalized(runContext.haplotypeFrameworkHint)

        var selectedDefinitions = pack.haplotypeBlockDefinitions.filter { definition in
            definitionMatchesContext(
                definition,
                observedRegions: observedRegions,
                observedTerms: observedTerms,
                population: population,
                speciesPrefix: speciesPrefix,
                framework: framework
            )
        }

        if selectedDefinitions.isEmpty && observedRegions.isEmpty {
            selectedDefinitions = pack.haplotypeBlockDefinitions.filter {
                normalized($0.populationID) == population
                    || normalized($0.speciesPrefix) == speciesPrefix
                    || normalized($0.frameworkID) == framework
            }
        }

        let selectedLabels = Set(
            selectedDefinitions.flatMap { definition in
                [definition.displayLabel, definition.reportLabel]
            }.map(normalized)
        )
        let selectedAlleles = pack.alleleRecords.filter {
            alleleRecordMatches($0, observedTerms: observedAlleleTerms, selectedLabels: selectedLabels)
        }

        return AIHaplotypingKnowledgePack(
            id: pack.id,
            version: pack.version,
            sources: pack.sources,
            populationProfiles: pack.populationProfiles,
            alleleRecords: selectedAlleles,
            haplotypeBlockDefinitions: selectedDefinitions,
            markerRules: pack.markerRules,
            analystGuidance: pack.analystGuidance,
            digest: pack.digest
        )
    }

    private static func definitionMatchesContext(
        _ definition: AIHaplotypingHaplotypeBlockDefinition,
        observedRegions: Set<String>,
        observedTerms: Set<String>,
        population: String,
        speciesPrefix: String,
        framework: String
    ) -> Bool {
        let hasSpecificPopulation = !population.isEmpty
            && population != "unknown"
            && population != "other-macaque"
        let matchesPopulation: Bool
        if hasSpecificPopulation {
            matchesPopulation = normalized(definition.populationID) == population
                || normalized(definition.frameworkID) == framework
        } else {
            matchesPopulation = normalized(definition.populationID) == population
                || normalized(definition.speciesPrefix) == speciesPrefix
                || normalized(definition.frameworkID) == framework
        }
        guard matchesPopulation else { return false }

        let regionMatches = observedRegions.contains(canonicalRegion(definition.region))
        if regionMatches { return true }

        if observedTerms.contains(normalized(definition.displayLabel))
            || observedTerms.contains(normalized(definition.reportLabel)) {
            return true
        }
        return definition.definingMarkers.contains { marker in
            observedTerms.contains(normalized(marker.marker))
                || observedTerms.contains(normalized(marker.locus))
                || observedRegions.contains(canonicalRegion(marker.locus))
        }
    }

    private static func alleleRecordMatches(
        _ record: AIHaplotypingAlleleRecord,
        observedTerms: Set<String>,
        selectedLabels: Set<String>
    ) -> Bool {
        if record.haplotypes.map(normalized).contains(where: selectedLabels.contains) {
            return true
        }
        let recordTerms = alleleRecordSearchTerms(record)
        return observedTerms.contains { observedTerm in
            recordTerms.contains { recordTerm in
                alleleTerm(observedTerm, matchesRecordTerm: recordTerm)
            }
        }
    }

    private static func observedSearchTerms(
        registry: AIHaplotypingEvidenceRegistry,
        runContext: AIHaplotypingRunContext,
        observedRegions: Set<String>
    ) -> Set<String> {
        var terms = Set<String>()
        for value in [
            runContext.speciesPrefix,
            runContext.populationHint,
            runContext.assayResolution,
            runContext.haplotypeFrameworkHint,
            runContext.haplotypeDefinitionSetID,
            runContext.haplotypeAssayID,
        ].compactMap({ $0 }) {
            terms.formUnion(Self.terms(from: value))
        }
        for value in observedRegions {
            terms.formUnion(Self.terms(from: value))
        }
        for observation in registry.observations {
            terms.formUnion(Self.terms(from: observation.genotype))
        }
        for call in registry.currentCalls {
            terms.formUnion(Self.terms(from: call.haplotypeLabel))
            terms.formUnion(Self.terms(from: call.locus))
        }
        for review in registry.manualReviews {
            terms.formUnion(Self.terms(from: review.overrideCall))
            terms.formUnion(Self.terms(from: review.locus))
        }
        return terms
    }

    private static func chunkObservedRegions(registry: AIHaplotypingEvidenceRegistry) -> Set<String> {
        var regions = Set(registry.loci.map { canonicalRegion($0.locus) })
        for observation in registry.observations {
            let genotype = normalized(observation.genotype)
            if genotype.contains("_ag") || genotype.contains("-ag") {
                regions.insert("mhc-ag")
            }
            if genotype.contains("mhc-e") || genotype.contains("mafa-e") || genotype.contains("mamu-e") {
                regions.insert("mhc-e")
            }
        }
        return regions.filter { !$0.isEmpty }
    }

    private static func observedAlleleSearchTerms(registry: AIHaplotypingEvidenceRegistry) -> Set<String> {
        var terms = Set<String>()
        for observation in registry.observations {
            terms.formUnion(Self.alleleSearchTerms(from: observation.genotype))
        }
        for call in registry.currentCalls {
            terms.formUnion(Self.alleleSearchTerms(from: call.haplotypeLabel))
        }
        for review in registry.manualReviews {
            terms.formUnion(Self.alleleSearchTerms(from: review.overrideCall))
        }
        return terms
    }

    private static func alleleRecordSearchTerms(_ record: AIHaplotypingAlleleRecord) -> Set<String> {
        var terms = Set<String>()
        for value in [
            record.id,
            record.officialDesignation,
            record.accession,
            record.previousName,
        ].compactMap({ $0 }) {
            let cleaned = normalized(value)
            if !cleaned.isEmpty {
                terms.insert(cleaned)
                terms.formUnion(alleleDesignationPrefixes(from: cleaned))
            }
        }
        return terms
    }

    private static func alleleSearchTerms(from value: String) -> Set<String> {
        let cleaned = normalized(value)
        guard !cleaned.isEmpty else { return [] }
        var result = Set<String>([cleaned])
        let separators = CharacterSet(charactersIn: "_|,;()[]{} \t\n\r")
        let pieces = cleaned
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for piece in pieces where piece.contains("*") {
            result.insert(piece)
            result.formUnion(alleleDesignationPrefixes(from: piece))
        }
        return result
    }

    private static func alleleDesignationPrefixes(from value: String) -> Set<String> {
        let cleaned = normalized(value)
        guard cleaned.contains("*") else { return [] }
        let parts = cleaned.split(separator: ":", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return [cleaned] }
        var result = Set<String>([cleaned])
        for endIndex in 2...parts.count {
            result.insert(parts.prefix(endIndex).joined(separator: ":"))
        }
        return result
    }

    private static func alleleTerm(_ observedTerm: String, matchesRecordTerm recordTerm: String) -> Bool {
        if observedTerm == recordTerm {
            return true
        }
        guard observedTerm.contains("*") || recordTerm.contains("*") else {
            return false
        }
        return recordTerm.hasPrefix("\(observedTerm):")
            || observedTerm.hasPrefix("\(recordTerm):")
    }

    private static func terms(from value: String) -> Set<String> {
        let cleaned = normalized(value)
        guard !cleaned.isEmpty else { return [] }
        var result = Set<String>([cleaned])
        let separators = CharacterSet(charactersIn: "_-|,;:*/()[]{} ")
        let pieces = cleaned
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        result.formUnion(pieces)

        let withoutRunNumber = cleaned.replacingOccurrences(
            of: #"^\d+[_-]"#,
            with: "",
            options: .regularExpression
        )
        if withoutRunNumber != cleaned {
            result.insert(withoutRunNumber)
            result.formUnion(terms(from: withoutRunNumber))
        }
        if cleaned.hasSuffix("g") {
            result.insert(String(cleaned.dropLast()))
        }
        if let range = cleaned.range(of: #"g\d*$"#, options: .regularExpression) {
            result.insert(String(cleaned[..<range.lowerBound]))
        }
        return result
    }

    private static func canonicalRegion(_ value: String) -> String {
        let normalizedValue = normalized(value)
        if normalizedValue.hasPrefix("mhc-dpa") { return "mhc-dpa" }
        if normalizedValue.hasPrefix("mhc-dpb") { return "mhc-dpb" }
        if normalizedValue.hasPrefix("mhc-dqa") { return "mhc-dqa" }
        if normalizedValue.hasPrefix("mhc-dqb") { return "mhc-dqb" }
        if normalizedValue.hasPrefix("mhc-dp") { return "mhc-dp" }
        if normalizedValue.hasPrefix("mhc-dq") { return "mhc-dq" }
        if normalizedValue.hasPrefix("mhc-drb") { return "mhc-drb" }
        if normalizedValue.hasPrefix("mhc-ag") { return "mhc-ag" }
        if normalizedValue.hasPrefix("mhc-a") { return "mhc-a" }
        if normalizedValue.hasPrefix("mhc-b") { return "mhc-b" }
        return normalizedValue
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
