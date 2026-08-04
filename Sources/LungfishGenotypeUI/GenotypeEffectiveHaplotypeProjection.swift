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
        let resolution = GenotypeEffectiveCallAuthority.resolve(
            analysis: analysis,
            sidecar: sidecar
        )
        identity = .init(
            assayID: resolution.identity.assayID,
            analysisRevisionID: resolution.identity.analysisRevisionID,
            definitionSetID: resolution.identity.definitionSetID
        )
        orderedSamples = resolution.orderedSamples
        orderedLoci = resolution.orderedLoci

        var values: [
            GenotypeEffectiveHaplotypeKey: GenotypeEffectiveHaplotypeValue
        ] = [:]
        var authoritativeOverrides: [
            GenotypeEffectiveHaplotypeKey:
                GenotypeAnnotationSidecar.CallOverride
        ] = [:]
        var orderedLocusKeysBySample: [String: [LocusKey]] = [:]
        for sample in analysis.samples {
            for call in sample.calls {
                let locusKey = LocusKey(
                    sample: sample.sample,
                    locus: call.locus
                )
                orderedLocusKeysBySample[sample.sample, default: []]
                    .append(locusKey)
                for slot in HaplotypeSlot.allCases {
                    guard let resolved = resolution.value(
                        sample: sample.sample,
                        locus: call.locus,
                        slot: slot
                    ) else {
                        continue
                    }
                    let key = GenotypeEffectiveHaplotypeKey(
                        sample: sample.sample,
                        locus: call.locus,
                        slot: slot
                    )
                    values[key] = .init(
                        baseline: resolved.baseline,
                        effective: resolved.effective,
                        status: resolved.status,
                        source: Self.source(resolved.source)
                    )
                    authoritativeOverrides[key] =
                        resolved.authoritativeOverride
                }
            }
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
                guard let resolvedLocus = resolution.locusValue(
                    sample: sample.sample,
                    locus: call.locus
                ) else {
                    continue
                }
                locusSnapshots[locusKey] = GenotypeEffectiveHaplotypeLocusSnapshot(
                    sample: sample.sample,
                    locus: call.locus,
                    h1: h1,
                    h2: h2,
                    status: resolvedLocus.status
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

        self.values = values
        self.authoritativeOverrides = authoritativeOverrides
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

    private static func source(
        _ source: GenotypeEffectiveCallAuthority.Source
    ) -> GenotypeEffectiveHaplotypeValue.Source {
        switch source {
        case .pipeline: .pipeline
        case .analystOverride: .analystOverride
        case .staleOverride: .staleOverride
        }
    }

    private struct LocusKey: Hashable, Sendable {
        let sample: String
        let locus: String
    }
}
