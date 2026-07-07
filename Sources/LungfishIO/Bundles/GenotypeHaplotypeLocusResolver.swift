import Foundation
import LungfishCore

public enum GenotypeHaplotypeLocusResolver {
    public static func metadataHaplotypeGroupLocus(for genotype: String) -> String? {
        pipeMetadataEvidenceLocus(for: genotype, key: "haplotype_groups")
    }

    public static func metadataSourceLocus(for genotype: String) -> String? {
        guard let value = pipeMetadataValue(for: genotype, key: "source_loci") else { return nil }
        let firstLocus = value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let firstLocus else { return nil }
        return canonicalLocusName(firstLocus)
    }

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
        if uppercased.hasPrefix("AG") {
            return "MHC-AG"
        }
        if uppercased == "A" || alleleToken(uppercased, belongsTo: "A") {
            return "MHC-A"
        }
        if uppercased == "B" || alleleToken(uppercased, belongsTo: "B") {
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

    public static func haplotypeEvidenceLocusName(_ rawLocus: String) -> String {
        let canonical = canonicalLocusName(rawLocus)
        let token = locusToken(fromCanonicalLocus: canonical)
        switch token {
        case "AG", "F", "G", "70":
            return "MHC-A"
        case "E":
            return "MHC-E"
        case "L":
            return "MHC-L"
        case "I", "J", "K", "S", "V":
            return "MHC-B"
        default:
            return canonical
        }
    }

    public static func isReportableHaplotypeLocus(_ rawLocus: String) -> Bool {
        let canonical = haplotypeEvidenceLocusName(rawLocus)
        return canonical != "MHC-L"
    }

    private static func locusToken(fromCanonicalLocus canonical: String) -> String {
        var token = canonical
        if token.uppercased().hasPrefix("MHC-") {
            token = String(token.dropFirst(4))
        }
        let separators = CharacterSet(charactersIn: "*_:")
        return token
            .components(separatedBy: separators)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
    }

    private static func alleleToken(_ token: String, belongsTo locus: Character) -> Bool {
        guard token.first == locus else { return false }
        let suffix = token.dropFirst()
        guard let first = suffix.first else { return true }
        return first.isNumber || first == "*"
    }

    public static func canonicalLocus(
        for call: ONTGenotypeCall,
        definitionSet: GenotypeHaplotypeDefinitionSet?
    ) -> String {
        if let groupLocus = metadataHaplotypeGroupLocus(for: call.genotype) {
            guard let definitionSet else { return groupLocus }
            if let definition = definitionSet.locusDefinitions.first(where: {
                locus($0, isCompatibleWith: groupLocus)
            }) {
                return definition.locus
            }
            return groupLocus
        }
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
        if let groupLocus = metadataHaplotypeGroupLocus(for: call.genotype),
           locus(definition, isCompatibleWith: groupLocus) {
            return true
        }
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

    private static func pipeMetadataEvidenceLocus(for genotype: String, key: String) -> String? {
        guard let value = pipeMetadataValue(for: genotype, key: key) else { return nil }
        let firstLocus = value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let firstLocus else { return nil }
        return haplotypeEvidenceLocusName(firstLocus)
    }

    private static func pipeMetadataValue(for genotype: String, key: String) -> String? {
        let prefix = "\(key)="
        return genotype
            .split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst()
            .compactMap { field -> String? in
                guard field.hasPrefix(prefix) else { return nil }
                return String(field.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first { !$0.isEmpty }
    }

    private static func locus(
        _ definition: GenotypeHaplotypeLocusDefinition,
        isCompatibleWith locus: String
    ) -> Bool {
        let candidate = canonicalLocusName(locus)
        return candidate == canonicalLocusName(definition.locus)
            || candidate == canonicalLocusName(definition.sourceLocus)
    }

    private static func speciesFreeToken(_ token: String) -> String? {
        let runStripped = GenotypeHaplotypeTokenNormalization.removingLeadingRunNumber(from: token)
        let parts = runStripped.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let species = parts[0].lowercased()
        guard ["mafa", "mamu", "mane"].contains(species) else { return nil }
        return String(parts[1])
    }
}
