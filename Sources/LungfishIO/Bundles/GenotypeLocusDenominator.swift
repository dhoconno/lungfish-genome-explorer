import Foundation

/// The one read denominator behind every "percent of locus" number
/// (GEN-05, decision D13).
///
/// A locus percentage is an allele's unique retained reads divided by the
/// unique retained reads of the same sample at the same **source locus**
/// (`source_loci` metadata when the reference carries it, otherwise the
/// locus parsed from the allele name). Haplotype groups are never pooled:
/// MHC-G, MHC-AG and MHC-E are each normalized on their own even when the
/// reference files them all under `haplotype_groups=MHC-A`, because source
/// loci can differ in depth by orders of magnitude.
///
/// The genotype matrix, the haplotype evidence pane, the haplotype caller's
/// dropout filter and the Excel filter all read this type, so the same allele
/// shows the same percentage everywhere.
public struct GenotypeLocusDenominator: Sendable, Equatable {
    /// Short basis label for threshold controls, workbooks and provenance.
    public static let basisLabel = "per source locus"
    /// One-sentence basis statement for workbooks and provenance.
    public static let basisDescription =
        "Unique retained reads of the same sample at the same source locus "
        + "(known alleles plus candidate clusters at that locus)"

    public struct Key: Hashable, Sendable {
        public let sample: String
        public let sourceLocus: String

        public init(sample: String, sourceLocus: String) {
            self.sample = GenotypeLocusDenominator.normalizedSample(sample)
            self.sourceLocus = GenotypeLocusDenominator.sourceLocus(forLocusLabel: sourceLocus)
        }
    }

    private let totals: [Key: Int]

    /// Builds the denominators from known calls and, when present, the reads
    /// of candidate clusters (novel alleles and interpreted incomplete
    /// clusters) observed at the same source locus.
    public init(
        calls: [ONTGenotypeCall],
        candidateDocument: ONTMHCCandidateAllelesDocument? = nil,
        unnameableDocument: ONTMHCUnnameableClustersDocument? = nil
    ) {
        var totals: [Key: Int] = [:]
        totals.reserveCapacity(calls.count)
        for call in calls {
            totals[Key(sample: call.sample, sourceLocus: call.locusGroup), default: 0]
                += max(0, call.passedUniqueReads)
        }
        if let candidateDocument {
            let locusByCluster = Dictionary(
                candidateDocument.candidates.map { ($0.stableClusterID, $0.locus) },
                uniquingKeysWith: { first, _ in first }
            )
            for observation in candidateDocument.observations {
                guard let locus = locusByCluster[observation.stableClusterID] else { continue }
                totals[Key(sample: observation.sampleID, sourceLocus: locus), default: 0]
                    += max(0, observation.aggregatedSampleReadCount)
            }
        }
        if let unnameableDocument {
            let locusByCluster = Dictionary(
                unnameableDocument.clusters.compactMap { record in
                    record.candidateInterpretation.map { (record.stableClusterID, $0.locus) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            for observation in unnameableDocument.observations {
                guard let locus = locusByCluster[observation.stableClusterID] else { continue }
                totals[Key(sample: observation.sampleID, sourceLocus: locus), default: 0]
                    += max(0, observation.aggregatedSampleReadCount)
            }
        }
        self.totals = totals
    }

    public init(result: ONTGenotypeResultBundleData) {
        self.init(
            calls: result.calls,
            candidateDocument: result.mhcCandidates,
            unnameableDocument: result.mhcUnnameableClusters
        )
    }

    /// The source-locus key for a call: `source_loci` metadata first, the
    /// allele name otherwise (the same key the matrix groups rows by).
    public static func sourceLocus(for call: ONTGenotypeCall) -> String {
        call.locusGroup
    }

    /// Canonical source-locus key for a raw locus label such as a candidate's
    /// `MHC-A1` or a call's `locusGroup`. Idempotent.
    public static func sourceLocus(forLocusLabel label: String) -> String {
        ONTGenotypeCall.sourceLocusGroup(forLocusToken: label)
    }

    public static func normalizedSample(_ sample: String) -> String {
        let cleaned = sample
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? sample : cleaned
    }

    public func total(sample: String, sourceLocus: String) -> Int {
        totals[Key(sample: sample, sourceLocus: sourceLocus)] ?? 0
    }

    public func total(for call: ONTGenotypeCall) -> Int {
        total(sample: call.sample, sourceLocus: call.locusGroup)
    }

    /// `reads / total`, or nil when the sample has no reads at that locus.
    public func fraction(reads: Int, sample: String, sourceLocus: String) -> Double? {
        let denominator = total(sample: sample, sourceLocus: sourceLocus)
        guard denominator > 0 else { return nil }
        return Double(reads) / Double(denominator)
    }

    public func fraction(for call: ONTGenotypeCall) -> Double? {
        fraction(reads: call.passedUniqueReads, sample: call.sample, sourceLocus: call.locusGroup)
    }
}
