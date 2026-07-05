import Foundation
import LungfishCore

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
            let runStripped = GenotypeHaplotypeTokenNormalization.removingLeadingRunNumber(from: cleaned)
            insertTokenVariants(runStripped, into: &tokens)
            if let speciesFree = removingSpeciesPrefix(from: runStripped) {
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

    private static func removingSpeciesPrefix(from token: String) -> String? {
        let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let species = parts[0].lowercased()
        guard ["mafa", "mamu", "mane"].contains(species) else { return nil }
        return String(parts[1])
    }
}
