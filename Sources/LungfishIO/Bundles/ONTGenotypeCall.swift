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
    /// In amplicon results the reference held identical sequences (including
    /// reverse complements), collapsed onto this row's genotype before
    /// mapping. The list holds every member of that ambiguity group, this
    /// genotype first, and the other members are not calls.
    ///
    /// In full-length results the list holds every reference that tied for
    /// this call's best hit in one of its clusters, sorted. Each tied
    /// reference is its own call with the full cluster reads, so the read
    /// totals count such a group once (`GenotypeLocusDenominator.knownReadTotals`, D2).
    public let ambiguousWith: [String]?
    /// Full-length ONT only. Indel bases in the zero-SNP hit
    /// behind this known call (largest over its clusters). Nil for amplicon
    /// calls and for older bundles.
    public let indelBases: Int?
    /// The source locus the result's reference record names for this call's
    /// genotype (N9). Nil unless `ONTGenotypeResultBundleData` stamped it.
    ///
    /// A full-length call carries its reference sequence ID, for example the
    /// IPD accession NHP01270, so the genotype alone names no locus. The
    /// result's reference record does ("Mafa-A2*05:25:01:01"), and the
    /// result stamps that locus here when it is built. The value is never
    /// encoded, so encoded calls and goldens stay as they were and a decoded
    /// result stamps again from its reference metadata.
    public private(set) var sourceLocus: String? = nil

    private enum CodingKeys: String, CodingKey {
        case sample, genotype, passedAlignments, passedUniqueReads
        case sampleTotalReads, sampleUniqueRetainedReads, sampleUniqueRetainedPercent
        case overallInputReads, overallUniqueRetainedReads, overallUniqueRetainedPercent
        case ambiguousWith, indelBases
    }

    /// A known full-length call whose hit carries indels.
    /// It stays a known call, but needs review.
    public var needsIndelReview: Bool {
        (indelBases ?? 0) > 0
    }

    /// The other calls of the same animal this call shares its reads with
    /// (D2). A full-length result gives each equal-best reference of a cluster
    /// its own call with the full cluster reads and the tie list in
    /// `ambiguousWith`, so the partners are the listed references that are
    /// themselves calls of the animal, in the list's order. An ordinary call
    /// has none, and so does an amplicon row whose list names the references
    /// collapsed onto it before mapping, because those are not calls.
    public func sharedReadPartners(in sampleCalls: [ONTGenotypeCall]) -> [String] {
        guard let ambiguousWith else { return [] }
        let animalGenotypes = Set(sampleCalls.lazy.filter { $0.sample == sample }.map(\.genotype))
        return ambiguousWith.filter { $0 != genotype && animalGenotypes.contains($0) }
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
        indelBases: Int? = nil,
        sourceLocus: String? = nil
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
        self.sourceLocus = sourceLocus
    }

    /// The same call with its source locus taken from the reference record
    /// (N9). Every stored field keeps its value.
    public func withSourceLocus(_ sourceLocus: String?) -> ONTGenotypeCall {
        var copy = self
        copy.sourceLocus = sourceLocus
        return copy
    }

    public var haplotypeTokens: [String] {
        Self.inferHaplotypeTokens(from: genotype)
    }

    public var locusToken: String? {
        Self.inferLocusToken(from: genotype)
    }

    /// The call's source locus. The locus the result stamped from the
    /// reference record comes first (N9), then `source_loci` metadata, then
    /// the allele name. This is the grouping key of the per-source-locus
    /// read denominator, see `GenotypeLocusDenominator`.
    public var locusGroup: String {
        if let sourceLocus { return Self.sourceLocusGroup(forLocusToken: sourceLocus) }
        return genotypeLocusGroup
    }

    /// The source locus the genotype string alone names, ignoring any stamp.
    /// It is the locus every result used before N9, so annotations saved
    /// against an accession's pseudo-locus (MHC-NHP01270) still find the
    /// call through it (`GenotypeMatrixTargetLocusAlias`).
    public var genotypeLocusGroup: String {
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
