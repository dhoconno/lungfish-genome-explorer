import Foundation
import LungfishCore

/// IO-owned authority for resolving pipeline haplotype calls and persisted
/// overrides. UI projections and headless cohort evaluation consume this same
/// result so identity, timestamp, stale-record, and per-slot status rules
/// cannot drift between surfaces.
public enum GenotypeEffectiveCallAuthority {
    public struct Target: Hashable, Sendable {
        public let sample: String
        public let locus: String
        public let slot: HaplotypeSlot

        public init(sample: String, locus: String, slot: HaplotypeSlot) {
            self.sample = sample
            self.locus = locus
            self.slot = slot
        }
    }

    public enum Source: Equatable, Sendable {
        case pipeline
        case analystOverride
        case staleOverride
    }

    public struct SlotValue: Equatable, Sendable {
        public let baseline: String
        public let effective: String
        public let status: GenotypeHaplotypeCallStatus
        public let source: Source
        public let authoritativeOverride:
            GenotypeAnnotationSidecar.CallOverride?
    }

    public struct LocusValue: Equatable, Sendable {
        public let sample: String
        public let locus: String
        public let h1: SlotValue
        public let h2: SlotValue
        public let status: GenotypeHaplotypeCallStatus
    }

    public struct Resolution: Equatable, Sendable {
        public let identity:
            GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity
        public let orderedSamples: [String]
        public let orderedLoci: [String]
        public let values: [Target: SlotValue]

        fileprivate let locusValues: [LocusTarget: LocusValue]

        fileprivate init(
            identity: GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity,
            orderedSamples: [String],
            orderedLoci: [String],
            values: [Target: SlotValue],
            locusValues: [LocusTarget: LocusValue]
        ) {
            self.identity = identity
            self.orderedSamples = orderedSamples
            self.orderedLoci = orderedLoci
            self.values = values
            self.locusValues = locusValues
        }

        public func value(
            sample: String,
            locus: String,
            slot: HaplotypeSlot
        ) -> SlotValue? {
            values[.init(sample: sample, locus: locus, slot: slot)]
        }

        public func locusValue(
            sample: String,
            locus: String
        ) -> LocusValue? {
            locusValues[.init(sample: sample, locus: locus)]
        }
    }

    public static func resolve(
        analysis: GenotypeHaplotypeAnalysis,
        sidecar: GenotypeAnnotationSidecar
    ) -> Resolution {
        let identity = GenotypeAnnotationSidecar
            .CallOverrideAnalysisIdentity(
                assayID: analysis.assayID,
                analysisRevisionID: analysis.analysisRevisionID,
                definitionSetID: analysis.definitionSetID
            )
        var orderedSamples: [String] = []
        var orderedLoci: [String] = []
        var seenSamples = Set<String>()
        var seenLoci = Set<String>()
        var baselines: [Target: SlotValue] = [:]

        for sample in analysis.samples {
            if seenSamples.insert(sample.sample).inserted {
                orderedSamples.append(sample.sample)
            }
            for call in sample.calls {
                if seenLoci.insert(call.locus).inserted {
                    orderedLoci.append(call.locus)
                }
                baselines[.init(
                    sample: sample.sample,
                    locus: call.locus,
                    slot: .h1
                )] = .init(
                    baseline: call.haplotype1,
                    effective: call.haplotype1,
                    status: call.status,
                    source: .pipeline,
                    authoritativeOverride: nil
                )
                baselines[.init(
                    sample: sample.sample,
                    locus: call.locus,
                    slot: .h2
                )] = .init(
                    baseline: call.haplotype2,
                    effective: call.haplotype2,
                    status: call.status,
                    source: .pipeline,
                    authoritativeOverride: nil
                )
            }
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        var latest: [Target: IndexedOverride] = [:]
        latest.reserveCapacity(sidecar.callOverrides.count)
        for (index, entry) in sidecar.callOverrides.enumerated() {
            let target = Target(
                sample: entry.sample,
                locus: entry.locus,
                slot: entry.slot
            )
            guard baselines[target] != nil,
                  !entry.overrideCall.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  let date = fractional.date(from: entry.timestamp)
                    ?? internet.date(from: entry.timestamp) else {
                continue
            }
            let candidate = IndexedOverride(
                entry: entry,
                date: date,
                sidecarIndex: index,
                identityPriority: entry.analysisIdentity == identity
                    ? 2
                    : (entry.analysisIdentity == nil ? 1 : 0)
            )
            if let current = latest[target],
               !precedes(current, candidate) {
                continue
            }
            latest[target] = candidate
        }

        var values = baselines
        for (target, indexed) in latest {
            guard let baseline = baselines[target] else { continue }
            let entry = indexed.entry
            if let overrideIdentity = entry.analysisIdentity,
               overrideIdentity != identity {
                values[target] = .init(
                    baseline: baseline.baseline,
                    effective: baseline.effective,
                    status: baseline.status,
                    source: .staleOverride,
                    authoritativeOverride: entry
                )
            } else {
                values[target] = .init(
                    baseline: baseline.baseline,
                    effective: entry.overrideCall,
                    status: overrideStatus(
                        effective: entry.overrideCall,
                        baseline: baseline.status
                    ),
                    source: .analystOverride,
                    authoritativeOverride: entry
                )
            }
        }

        var loci: [LocusTarget: LocusValue] = [:]
        for sample in analysis.samples {
            for call in sample.calls {
                let h1Target = Target(
                    sample: sample.sample,
                    locus: call.locus,
                    slot: .h1
                )
                let h2Target = Target(
                    sample: sample.sample,
                    locus: call.locus,
                    slot: .h2
                )
                guard let h1 = values[h1Target],
                      let h2 = values[h2Target] else {
                    continue
                }
                loci[.init(sample: sample.sample, locus: call.locus)] =
                    .init(
                        sample: sample.sample,
                        locus: call.locus,
                        h1: h1,
                        h2: h2,
                        status: reduceLocusStatus(h1.status, h2.status)
                    )
            }
        }
        return Resolution(
            identity: identity,
            orderedSamples: orderedSamples,
            orderedLoci: orderedLoci,
            values: values,
            locusValues: loci
        )
    }

    private static func precedes(
        _ lhs: IndexedOverride,
        _ rhs: IndexedOverride
    ) -> Bool {
        if lhs.identityPriority != rhs.identityPriority {
            return lhs.identityPriority < rhs.identityPriority
        }
        if lhs.date != rhs.date {
            return lhs.date < rhs.date
        }
        return lhs.sidecarIndex < rhs.sidecarIndex
    }

    private static func overrideStatus(
        effective: String,
        baseline: GenotypeHaplotypeCallStatus
    ) -> GenotypeHaplotypeCallStatus {
        let trimmed = effective.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed != "?",
              !trimmed.hasPrefix("ERR:") else {
            switch baseline {
            case .noHaplotype, .tooManyHaplotypes, .tooManyGenotypes:
                return baseline
            case .called, .notAssayed, .specialCase:
                return .noHaplotype
            }
        }
        return .called
    }

    private static func reduceLocusStatus(
        _ h1: GenotypeHaplotypeCallStatus,
        _ h2: GenotypeHaplotypeCallStatus
    ) -> GenotypeHaplotypeCallStatus {
        if isUnresolved(h1) { return h1 }
        if isUnresolved(h2) { return h2 }
        if h1 == .notAssayed || h2 == .notAssayed { return .notAssayed }
        if h1 == .specialCase || h2 == .specialCase { return .specialCase }
        return .called
    }

    private static func isUnresolved(
        _ status: GenotypeHaplotypeCallStatus
    ) -> Bool {
        switch status {
        case .noHaplotype, .tooManyHaplotypes, .tooManyGenotypes:
            true
        case .called, .notAssayed, .specialCase:
            false
        }
    }

    fileprivate struct LocusTarget: Hashable, Sendable {
        let sample: String
        let locus: String
    }

    private struct IndexedOverride: Sendable {
        let entry: GenotypeAnnotationSidecar.CallOverride
        let date: Date
        let sidecarIndex: Int
        let identityPriority: Int
    }
}
