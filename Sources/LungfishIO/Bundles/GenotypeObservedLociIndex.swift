import Foundation
import LungfishCore

/// Indexes the observed loci across a bundle's raw `ONTGenotypeCall` records.
///
/// The haplotype analysis only resolves loci that the active
/// `GenotypeHaplotypeDefinitionSet` defines (typically 7 loci for an MCM
/// MHC-exon2-miSeq run). Real ONT bundles often touch many more loci
/// (MHC-AG, MHC-70, MHC-E, MHC-F, MHC-I, etc.). This index merges the
/// analyzed locus list with the union of locus names that appear in the
/// raw calls so the viewport can render every locus the analyst expects
/// to see.
public struct GenotypeObservedLociIndex: Sendable, Equatable {
    public struct LocusSummary: Sendable, Equatable {
        public let locus: String
        public let sampleCount: Int
        public let totalReads: Int
        public let isAnalyzed: Bool

        public init(locus: String, sampleCount: Int, totalReads: Int, isAnalyzed: Bool) {
            self.locus = locus
            self.sampleCount = sampleCount
            self.totalReads = totalReads
            self.isAnalyzed = isAnalyzed
        }
    }

    /// Distinct locus names in canonical sort order, with analyzed loci
    /// first (in the order they appear in the analysis) followed by
    /// observation-only loci sorted alphabetically.
    public let loci: [String]
    public let summariesByLocus: [String: LocusSummary]
    public let observedCallsBySampleAndLocus: [String: [String: [ONTGenotypeCall]]]

    public init(
        loci: [String],
        summariesByLocus: [String: LocusSummary],
        observedCallsBySampleAndLocus: [String: [String: [ONTGenotypeCall]]]
    ) {
        self.loci = loci
        self.summariesByLocus = summariesByLocus
        self.observedCallsBySampleAndLocus = observedCallsBySampleAndLocus
    }

    public static func build(
        from result: ONTGenotypeResultBundleData
    ) -> GenotypeObservedLociIndex {
        let analyzedLoci: [String] = result.haplotypeAnalysis?.samples.first?.calls.map(\.locus) ?? []
        let analyzedSet = Set(analyzedLoci)
        var observedSet: [String: (samples: Set<String>, reads: Int)] = [:]
        var callsBySampleAndLocus: [String: [String: [ONTGenotypeCall]]] = [:]
        for call in result.calls {
            let locus = call.locusGroup
            var existing = observedSet[locus] ?? (samples: Set<String>(), reads: 0)
            existing.samples.insert(call.sample)
            existing.reads += max(0, call.passedUniqueReads)
            observedSet[locus] = existing
            callsBySampleAndLocus[call.sample, default: [:]][locus, default: []].append(call)
        }
        // Order: analyzed loci (in declaration order), then observed-only,
        // sorted alphabetically.
        let observedOnly = observedSet.keys.filter { !analyzedSet.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let orderedLoci = analyzedLoci + observedOnly
        var summaries: [String: LocusSummary] = [:]
        for locus in orderedLoci {
            let summary = observedSet[locus]
            summaries[locus] = LocusSummary(
                locus: locus,
                sampleCount: summary?.samples.count ?? 0,
                totalReads: summary?.reads ?? 0,
                isAnalyzed: analyzedSet.contains(locus)
            )
        }
        return GenotypeObservedLociIndex(
            loci: orderedLoci,
            summariesByLocus: summaries,
            observedCallsBySampleAndLocus: callsBySampleAndLocus
        )
    }
}
