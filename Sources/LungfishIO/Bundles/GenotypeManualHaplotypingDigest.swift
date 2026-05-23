import Foundation
import LungfishCore

/// Aggregates per-locus genotype observations from a bundle's call set.
///
/// The Audit lens uses this to populate the manual-haplotyping panel: for
/// each (locus, genotype) the digest records the number of samples sharing
/// the genotype and the total number of supporting reads. The CLI can
/// reuse the same digest to surface observed genotypes in headless flows.
public struct GenotypeManualHaplotypingDigest: Sendable, Equatable {
    public struct GenotypeObservation: Sendable, Equatable {
        public let locus: String
        public let genotype: String
        public let sampleCount: Int
        public let totalReads: Int
        public let sampleIds: [String]

        public init(locus: String, genotype: String,
                    sampleCount: Int, totalReads: Int,
                    sampleIds: [String]) {
            self.locus = locus
            self.genotype = genotype
            self.sampleCount = sampleCount
            self.totalReads = totalReads
            self.sampleIds = sampleIds
        }
    }

    public let observations: [GenotypeObservation]

    public init(observations: [GenotypeObservation]) {
        self.observations = observations
    }

    /// Builds a digest from a flat sequence of `ONTGenotypeCall` records.
    /// `locusFor` lets the caller plug in any locus-inference function; if
    /// nil, the call's `locusGroup` is used.
    public static func build(
        from calls: [ONTGenotypeCall],
        locusFor: ((ONTGenotypeCall) -> String)? = nil
    ) -> GenotypeManualHaplotypingDigest {
        struct Key: Hashable { let locus: String; let genotype: String }
        var bucket: [Key: (samples: Set<String>, reads: Int)] = [:]
        for call in calls {
            let locus = locusFor?(call) ?? call.locusGroup
            let key = Key(locus: locus, genotype: call.genotype)
            var entry = bucket[key] ?? (samples: Set<String>(), reads: 0)
            entry.samples.insert(call.sample)
            entry.reads += max(0, call.passedUniqueReads)
            bucket[key] = entry
        }
        let observations = bucket.map { (key, value) in
            GenotypeObservation(
                locus: key.locus,
                genotype: key.genotype,
                sampleCount: value.samples.count,
                totalReads: value.reads,
                sampleIds: value.samples.sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
            )
        }
        .sorted { lhs, rhs in
            if lhs.locus != rhs.locus {
                return lhs.locus.localizedStandardCompare(rhs.locus) == .orderedAscending
            }
            if lhs.totalReads != rhs.totalReads {
                return lhs.totalReads > rhs.totalReads
            }
            return lhs.genotype.localizedStandardCompare(rhs.genotype) == .orderedAscending
        }
        return GenotypeManualHaplotypingDigest(observations: observations)
    }
}
