import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeCall: Codable, Equatable, Sendable {
    public let sample: String
    public let genotype: String
    public let passedAlignments: Int
    public let passedUniqueReads: Int
    public let sampleTotalReads: Int?
    public let sampleUniqueRetainedReads: Int?
    public let sampleUniqueRetainedPercent: Double?
    public let overallInputReads: Int?
    public let overallUniqueRetainedReads: Int?
    public let overallUniqueRetainedPercent: Double?
    /// The references this row cannot be told apart from. Nil for ordinary
    /// rows and for older bundles.
    ///
    /// Amplicon results: the reference held identical sequences (including
    /// reverse complements), collapsed onto this row's genotype before
    /// mapping. Lists every member of that ambiguity group, this genotype
    /// first, and the other members are not calls.
    ///
    /// Full-length results: every reference that tied for this call's best
    /// hit in one of its clusters, sorted. Each tied reference is its own call
    /// with the full cluster reads, so the read totals count such a group
    /// once (`GenotypeLocusDenominator.knownReadTotals`, D2).
    public let ambiguousWith: [String]?
    /// Full-length ONT only. Indel bases in the zero-SNP hit
    /// behind this known call (largest over its clusters). Nil for amplicon
    /// calls and for older bundles.
    public let indelBases: Int?

    /// A known full-length call whose hit carries indels.
    /// It stays a known call, but needs review.
    public var needsIndelReview: Bool {
        (indelBases ?? 0) > 0
    }

    public init(
        sample: String,
        genotype: String,
        passedAlignments: Int,
        passedUniqueReads: Int,
        sampleTotalReads: Int?,
        sampleUniqueRetainedReads: Int?,
        sampleUniqueRetainedPercent: Double?,
        overallInputReads: Int?,
        overallUniqueRetainedReads: Int?,
        overallUniqueRetainedPercent: Double?,
        ambiguousWith: [String]? = nil,
        indelBases: Int? = nil
    ) {
        self.sample = sample
        self.genotype = genotype
        self.passedAlignments = passedAlignments
        self.passedUniqueReads = passedUniqueReads
        self.sampleTotalReads = sampleTotalReads
        self.sampleUniqueRetainedReads = sampleUniqueRetainedReads
        self.sampleUniqueRetainedPercent = sampleUniqueRetainedPercent
        self.overallInputReads = overallInputReads
        self.overallUniqueRetainedReads = overallUniqueRetainedReads
        self.overallUniqueRetainedPercent = overallUniqueRetainedPercent
        self.ambiguousWith = ambiguousWith
        self.indelBases = indelBases
    }

    public var haplotypeTokens: [String] {
        Self.inferHaplotypeTokens(from: genotype)
    }

    public var locusToken: String? {
        Self.inferLocusToken(from: genotype)
    }

    /// The call's source locus (`source_loci` metadata first, the allele name
    /// otherwise). This is the grouping key of the per-source-locus read
    /// denominator, see `GenotypeLocusDenominator`.
    public var locusGroup: String {
        Self.sourceLocusGroup(forLocusToken: locusToken ?? "")
    }

    /// Canonical source-locus group for a locus token or label. Idempotent:
    /// passing an existing `locusGroup` returns it unchanged, so candidate
    /// locus labels and call groups land on the same key.
    public static func sourceLocusGroup(forLocusToken rawToken: String) -> String {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return "Unknown" }
        if token.caseInsensitiveCompare("Unknown") == .orderedSame { return "Unknown" }
        if let classIILocusGroup = preciseClassIILocusGroup(from: token) {
            return classIILocusGroup
        }
        if token.uppercased().hasPrefix("KIR-") { return token.uppercased() }
        return GenotypeHaplotypeLocusResolver.canonicalLocusName(token)
    }

    private static func genotypeParts(_ genotype: String) -> [String] {
        var parts = genotype
            .split(separator: "_", omittingEmptySubsequences: true)
            .map(String.init)
        if let first = parts.first, first.allSatisfy(\.isNumber) {
            parts.removeFirst()
        }
        return parts
    }

    private static func inferHaplotypeTokens(from genotype: String) -> [String] {
        guard let first = genotypeParts(genotype).first else { return [] }
        var matches: [String] = []
        var seen = Set<String>()
        var index = first.startIndex
        while index < first.endIndex {
            guard first[index] == "M" else {
                index = first.index(after: index)
                continue
            }
            var end = first.index(after: index)
            let numberStart = end
            while end < first.endIndex, first[end].isNumber {
                end = first.index(after: end)
            }
            if numberStart < end {
                let token = String(first[index..<end])
                if seen.insert(token).inserted {
                    matches.append(token)
                }
                index = end
            } else {
                index = first.index(after: index)
            }
        }
        return matches
    }

    private static func inferLocusToken(from genotype: String) -> String? {
        if let sourceLocus = MHCReferenceGenotypeDisplay.sourceLocus(for: genotype) {
            return sourceLocus
        }
        let parts = genotypeParts(genotype)
        guard !parts.isEmpty else { return nil }
        // A numeric sort prefix plus an opaque identifier is not an allele:
        // control names such as 16_A102 must not become a numbered MHC-A locus.
        if let prefix = genotype.split(separator: "_").first,
           prefix.allSatisfy(\.isNumber), parts.count == 1,
           !parts[0].contains("*") {
            return "Unknown"
        }
        if !inferHaplotypeTokens(from: genotype).isEmpty, parts.count > 1 {
            return cleanLocusToken(parts[1])
        }
        if isSpeciesToken(parts[0]), parts.count > 1 {
            return cleanLocusToken(parts[1])
        }
        return cleanLocusToken(parts[0])
    }

    private static func cleanLocusToken(_ token: String) -> String {
        let aliasFree = token.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) ?? token
        return aliasFree.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSpeciesToken(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "mafa", "mamu", "mane", "mafu", "mnem", "mfas", "mton", "mleu", "mthi",
            "macaque", "macaca",
        ].contains(normalized)
    }

    private static func preciseClassIILocusGroup(from token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let speciesFree = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? trimmed
        let uppercased = speciesFree.uppercased()
        for prefix in ["DQA", "DQB", "DPA", "DPB"] where uppercased.hasPrefix(prefix) {
            let suffix = uppercased.dropFirst(prefix.count)
            guard suffix.first?.isNumber == true else { return nil }
            let digits = suffix.prefix(while: \.isNumber)
            return "MHC-\(prefix)\(digits)"
        }
        return nil
    }
}
