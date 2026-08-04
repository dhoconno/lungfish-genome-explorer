import Foundation
import LungfishCore
import LungfishIO

struct GenotypeEffectiveHaplotypeKey: Hashable, Sendable {
    let sample: String
    let locus: String
    let slot: HaplotypeSlot
}

struct GenotypeEffectiveHaplotypeValue: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case pipeline
        case analystOverride
        case staleOverride
    }

    let baseline: String
    let effective: String
    let status: GenotypeHaplotypeCallStatus
    let source: Source
}

struct GenotypeEffectiveHaplotypeIdentity: Equatable, Sendable {
    let assayID: String
    let analysisRevisionID: String?
    let definitionSetID: String

    var sidecarIdentity:
        GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity {
        .init(
            assayID: assayID,
            analysisRevisionID: analysisRevisionID,
            definitionSetID: definitionSetID
        )
    }
}

struct GenotypeEffectiveHaplotypeLocusSnapshot: Equatable, Sendable {
    let sample: String
    let locus: String
    let h1: GenotypeEffectiveHaplotypeValue
    let h2: GenotypeEffectiveHaplotypeValue
    let status: GenotypeHaplotypeCallStatus
}

struct GenotypeEffectiveHaplotypeSampleSnapshot: Equatable, Sendable {
    let sample: String
    let loci: [GenotypeEffectiveHaplotypeLocusSnapshot]
}

/// Immutable read model for the pipeline haplotype calls and their effective
/// analyst overrides. Manual haplotype assignments intentionally do not
/// participate: those records belong to the genotype-only legacy workflow.
struct GenotypeEffectiveHaplotypeProjection: Equatable, Sendable {
    let identity: GenotypeEffectiveHaplotypeIdentity
    let orderedSamples: [String]
    let orderedLoci: [String]
    let values: [GenotypeEffectiveHaplotypeKey: GenotypeEffectiveHaplotypeValue]

    private let authoritativeOverrides: [
        GenotypeEffectiveHaplotypeKey: GenotypeAnnotationSidecar.CallOverride
    ]
    private let locusSnapshots: [LocusKey: GenotypeEffectiveHaplotypeLocusSnapshot]
    private let sampleSnapshots: [String: GenotypeEffectiveHaplotypeSampleSnapshot]

    init(
        analysis: GenotypeHaplotypeAnalysis,
        sidecar: GenotypeAnnotationSidecar
    ) {
        identity = GenotypeEffectiveHaplotypeIdentity(
            assayID: analysis.assayID,
            analysisRevisionID: analysis.analysisRevisionID,
            definitionSetID: analysis.definitionSetID
        )

        var orderedSamples: [String] = []
        orderedSamples.reserveCapacity(analysis.samples.count)
        var seenSamples = Set<String>()
        var orderedLoci: [String] = []
        var seenLoci = Set<String>()
        var baselineValues: [
            GenotypeEffectiveHaplotypeKey: GenotypeEffectiveHaplotypeValue
        ] = [:]
        var orderedLocusKeysBySample: [String: [LocusKey]] = [:]

        for sample in analysis.samples {
            if seenSamples.insert(sample.sample).inserted {
                orderedSamples.append(sample.sample)
            }
            for call in sample.calls {
                if seenLoci.insert(call.locus).inserted {
                    orderedLoci.append(call.locus)
                }
                let locusKey = LocusKey(sample: sample.sample, locus: call.locus)
                orderedLocusKeysBySample[sample.sample, default: []].append(locusKey)
                baselineValues[
                    GenotypeEffectiveHaplotypeKey(
                        sample: sample.sample,
                        locus: call.locus,
                        slot: .h1
                    )
                ] = GenotypeEffectiveHaplotypeValue(
                    baseline: call.haplotype1,
                    effective: call.haplotype1,
                    status: call.status,
                    source: .pipeline
                )
                baselineValues[
                    GenotypeEffectiveHaplotypeKey(
                        sample: sample.sample,
                        locus: call.locus,
                        slot: .h2
                    )
                ] = GenotypeEffectiveHaplotypeValue(
                    baseline: call.haplotype2,
                    effective: call.haplotype2,
                    status: call.status,
                    source: .pipeline
                )
            }
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let internetDateFormatter = ISO8601DateFormatter()
        internetDateFormatter.formatOptions = [.withInternetDateTime]

        var latestOverrides: [
            GenotypeEffectiveHaplotypeKey: IndexedOverride
        ] = [:]
        latestOverrides.reserveCapacity(sidecar.callOverrides.count)
        for (index, override) in sidecar.callOverrides.enumerated() {
            let key = GenotypeEffectiveHaplotypeKey(
                sample: override.sample,
                locus: override.locus,
                slot: override.slot
            )
            guard baselineValues[key] != nil,
                  !override.overrideCall.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  let date = fractionalFormatter.date(from: override.timestamp)
                    ?? internetDateFormatter.date(from: override.timestamp) else {
                continue
            }
            let candidate = IndexedOverride(
                entry: override,
                date: date,
                sidecarIndex: index,
                identityPriority: override.analysisIdentity
                    == identity.sidecarIdentity
                    ? 2
                    : (override.analysisIdentity == nil ? 1 : 0)
            )
            if let current = latestOverrides[key] {
                guard candidate.identityPriority
                        > current.identityPriority
                    || (
                        candidate.identityPriority
                            == current.identityPriority
                            && (
                                candidate.date > current.date
                                    || (
                                        candidate.date == current.date
                                            && candidate.sidecarIndex
                                                > current.sidecarIndex
                                    )
                            )
                    ) else {
                    continue
                }
            }
            latestOverrides[key] = candidate
        }

        var values = baselineValues
        for (key, indexedOverride) in latestOverrides {
            guard let baseline = baselineValues[key] else { continue }
            if let overrideIdentity =
                    indexedOverride.entry.analysisIdentity,
               overrideIdentity != identity.sidecarIdentity {
                values[key] = GenotypeEffectiveHaplotypeValue(
                    baseline: baseline.baseline,
                    effective: baseline.effective,
                    status: baseline.status,
                    source: .staleOverride
                )
                continue
            }
            let effective = indexedOverride.entry.overrideCall
            values[key] = GenotypeEffectiveHaplotypeValue(
                baseline: baseline.baseline,
                effective: effective,
                status: Self.overrideStatus(
                    effective: effective,
                    baseline: baseline.status
                ),
                source: .analystOverride
            )
        }

        var locusSnapshots: [
            LocusKey: GenotypeEffectiveHaplotypeLocusSnapshot
        ] = [:]
        locusSnapshots.reserveCapacity(analysis.samples.reduce(0) { $0 + $1.calls.count })
        for sample in analysis.samples {
            for call in sample.calls {
                let locusKey = LocusKey(sample: sample.sample, locus: call.locus)
                let h1Key = GenotypeEffectiveHaplotypeKey(
                    sample: sample.sample,
                    locus: call.locus,
                    slot: .h1
                )
                let h2Key = GenotypeEffectiveHaplotypeKey(
                    sample: sample.sample,
                    locus: call.locus,
                    slot: .h2
                )
                guard let h1 = values[h1Key], let h2 = values[h2Key] else {
                    continue
                }
                locusSnapshots[locusKey] = GenotypeEffectiveHaplotypeLocusSnapshot(
                    sample: sample.sample,
                    locus: call.locus,
                    h1: h1,
                    h2: h2,
                    status: Self.reduceLocusStatus(h1.status, h2.status)
                )
            }
        }

        var sampleSnapshots: [String: GenotypeEffectiveHaplotypeSampleSnapshot] = [:]
        sampleSnapshots.reserveCapacity(orderedSamples.count)
        for sample in orderedSamples {
            let snapshots = (orderedLocusKeysBySample[sample] ?? []).compactMap {
                locusSnapshots[$0]
            }
            sampleSnapshots[sample] = GenotypeEffectiveHaplotypeSampleSnapshot(
                sample: sample,
                loci: snapshots
            )
        }

        self.orderedSamples = orderedSamples
        self.orderedLoci = orderedLoci
        self.values = values
        self.authoritativeOverrides = latestOverrides.mapValues(\.entry)
        self.locusSnapshots = locusSnapshots
        self.sampleSnapshots = sampleSnapshots
    }

    func value(
        sample: String,
        locus: String,
        slot: HaplotypeSlot
    ) -> GenotypeEffectiveHaplotypeValue? {
        values[
            GenotypeEffectiveHaplotypeKey(
                sample: sample,
                locus: locus,
                slot: slot
            )
        ]
    }

    func hasOverride(
        sample: String,
        locus: String,
        slot: HaplotypeSlot
    ) -> Bool {
        guard let value = value(sample: sample, locus: locus, slot: slot) else {
            return false
        }
        return value.source != .pipeline
    }

    func authoritativeOverride(
        sample: String,
        locus: String,
        slot: HaplotypeSlot
    ) -> GenotypeAnnotationSidecar.CallOverride? {
        authoritativeOverrides[
            GenotypeEffectiveHaplotypeKey(
                sample: sample,
                locus: locus,
                slot: slot
            )
        ]
    }

    func snapshot(sample: String) -> GenotypeEffectiveHaplotypeSampleSnapshot? {
        sampleSnapshots[sample]
    }

    func snapshot(
        sample: String,
        locus: String
    ) -> GenotypeEffectiveHaplotypeLocusSnapshot? {
        locusSnapshots[LocusKey(sample: sample, locus: locus)]
    }

    private static func overrideStatus(
        effective: String,
        baseline: GenotypeHaplotypeCallStatus
    ) -> GenotypeHaplotypeCallStatus {
        let trimmed = effective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != GenotypeHaplotypeOverrideTargets.unresolved,
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
        if isUnresolvedStatus(h1) {
            return h1
        }
        if isUnresolvedStatus(h2) {
            return h2
        }
        if h1 == .notAssayed || h2 == .notAssayed {
            return .notAssayed
        }
        if h1 == .specialCase || h2 == .specialCase {
            return .specialCase
        }
        return .called
    }

    private static func isUnresolvedStatus(
        _ status: GenotypeHaplotypeCallStatus
    ) -> Bool {
        switch status {
        case .noHaplotype, .tooManyHaplotypes, .tooManyGenotypes:
            return true
        case .called, .notAssayed, .specialCase:
            return false
        }
    }

    private struct LocusKey: Hashable, Sendable {
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
