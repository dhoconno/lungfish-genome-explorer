import Foundation
import LungfishCore
import LungfishIO

public enum AIHaplotypingEvidenceError: Error, Equatable, LocalizedError, Sendable {
    case invalidChunkSize(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidChunkSize(let size):
            return "AI haplotyping evidence chunk size must be positive; got \(size)."
        }
    }
}

public enum AIHaplotypingEvidenceBuilder {
    public static func build(
        result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar?,
        mode: AIHaplotypingPromptMode,
        parentRevisionID: String?
    ) throws -> AIHaplotypingEvidenceRegistry {
        var samplesByID: [String: SampleEvidence] = [:]
        var lociByID: [String: LocusEvidence] = [:]
        var observationDrafts: [ObservationDraft] = []
        var currentCalls: [CurrentCallEvidence] = []
        var manualReviews: [ManualReviewEvidence] = []

        func recordSample(_ sample: String) -> String {
            let id = sampleID(for: sample)
            samplesByID[id] = SampleEvidence(id: id, sample: sample)
            return id
        }

        func recordLocus(_ locus: String) -> String {
            let id = locusID(for: locus)
            lociByID[id] = LocusEvidence(id: id, locus: locus)
            return id
        }

        for (index, call) in result.calls.enumerated() {
            let sample = normalizedSampleName(call.sample)
            let locus = GenotypeHaplotypeLocusResolver.canonicalLocusName(call.locusGroup)
            let sampleID = recordSample(sample)
            let locusID = recordLocus(locus)
            observationDrafts.append(ObservationDraft(
                originalIndex: index,
                baseID: "obs:\(sample):\(locus):\(call.genotype)",
                evidenceClass: .directObservation,
                sampleID: sampleID,
                locusID: locusID,
                genotype: call.genotype,
                passedAlignments: call.passedAlignments,
                passedUniqueReads: call.passedUniqueReads,
                sampleUniqueRetainedReads: call.sampleUniqueRetainedReads
            ))
        }

        if let analysis = result.haplotypeAnalysis {
            for sampleAnalysis in analysis.samples {
                let sample = normalizedSampleName(sampleAnalysis.sample)
                _ = recordSample(sample)
                for call in sampleAnalysis.calls {
                    let locus = GenotypeHaplotypeLocusResolver.canonicalLocusName(call.locus)
                    _ = recordLocus(locus)
                    currentCalls.append(CurrentCallEvidence(
                        id: "current:\(sample):\(locus):h1",
                        sample: sample,
                        locus: locus,
                        slot: "h1",
                        haplotypeLabel: call.haplotype1,
                        source: analysis.source,
                        parentRevisionID: parentRevisionID
                    ))
                    currentCalls.append(CurrentCallEvidence(
                        id: "current:\(sample):\(locus):h2",
                        sample: sample,
                        locus: locus,
                        slot: "h2",
                        haplotypeLabel: call.haplotype2,
                        source: analysis.source,
                        parentRevisionID: parentRevisionID
                    ))
                }
            }
        }

        for override in sidecar?.callOverrides ?? [] {
            let sample = normalizedSampleName(override.sample)
            let locus = GenotypeHaplotypeLocusResolver.canonicalLocusName(override.locus)
            _ = recordSample(sample)
            _ = recordLocus(locus)
            manualReviews.append(ManualReviewEvidence(
                id: "manual:\(sample):\(locus):\(override.slot.rawValue)",
                sample: sample,
                locus: locus,
                slot: override.slot.rawValue,
                overrideCall: override.overrideCall,
                rationale: override.rationale
            ))
        }

        return AIHaplotypingEvidenceRegistry(
            mode: mode,
            parentRevisionID: parentRevisionID,
            inputSnapshotDigest: inputSnapshotDigest(result: result, sidecar: sidecar),
            samples: Array(samplesByID.values),
            loci: Array(lociByID.values),
            observations: materializeObservationDrafts(observationDrafts),
            currentCalls: currentCalls,
            manualReviews: manualReviews
        )
    }

    private static func materializeObservationDrafts(_ drafts: [ObservationDraft]) -> [ObservationEvidence] {
        Dictionary(grouping: drafts, by: \.baseID)
            .flatMap { baseID, groupedDrafts -> [ObservationEvidence] in
                let sortedDrafts = groupedDrafts.sorted { lhs, rhs in
                    lexicographicallyPrecedes(lhs.sortKey, rhs.sortKey)
                }
                guard sortedDrafts.count > 1 else {
                    return sortedDrafts.map { $0.observation(id: baseID) }
                }
                return sortedDrafts.enumerated().map { offset, draft in
                    draft.observation(id: "\(baseID)#row-\(String(format: "%04d", offset + 1))")
                }
            }
            .sorted { $0.id < $1.id }
    }

    private static func inputSnapshotDigest(
        result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar?
    ) -> String {
        let activeAnalysisRevisionID = result.manifest.activeHaplotypeAnalysisRevisionID
            ?? result.haplotypeAnalysis?.analysisRevisionID
        let rawCalls = result.calls.map { call in
            RawCallSnapshot(
                sample: normalizedSampleName(call.sample),
                genotype: call.genotype,
                locus: GenotypeHaplotypeLocusResolver.canonicalLocusName(call.locusGroup),
                passedAlignments: call.passedAlignments,
                passedUniqueReads: call.passedUniqueReads,
                sampleTotalReads: call.sampleTotalReads,
                sampleUniqueRetainedReads: call.sampleUniqueRetainedReads,
                sampleUniqueRetainedPercent: call.sampleUniqueRetainedPercent,
                overallInputReads: call.overallInputReads,
                overallUniqueRetainedReads: call.overallUniqueRetainedReads,
                overallUniqueRetainedPercent: call.overallUniqueRetainedPercent
            )
        }.sorted()
        let overrides = (sidecar?.callOverrides ?? []).map { override in
            OverrideSnapshot(
                sample: normalizedSampleName(override.sample),
                locus: GenotypeHaplotypeLocusResolver.canonicalLocusName(override.locus),
                slot: override.slot.rawValue,
                originalCall: override.originalCall,
                overrideCall: override.overrideCall,
                reasonTag: override.reasonTag.rawValue,
                rationale: override.rationale,
                author: override.author,
                timestamp: override.timestamp
            )
        }.sorted()
        return AIHaplotypingCanonicalJSON.sha256Digest(of: InputSnapshot(
            activeAnalysisRevisionID: activeAnalysisRevisionID,
            rawCalls: rawCalls,
            callOverrides: overrides
        ))
    }

    private static func normalizedSampleName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sampleID(for sample: String) -> String {
        "sample:\(sample)"
    }

    private static func locusID(for locus: String) -> String {
        "locus:\(locus)"
    }

    private struct InputSnapshot: Encodable {
        let activeAnalysisRevisionID: String?
        let rawCalls: [RawCallSnapshot]
        let callOverrides: [OverrideSnapshot]
    }

    private struct ObservationDraft {
        let originalIndex: Int
        let baseID: String
        let evidenceClass: AIHaplotypingEvidenceClass
        let sampleID: String
        let locusID: String
        let genotype: String
        let passedAlignments: Int
        let passedUniqueReads: Int
        let sampleUniqueRetainedReads: Int?

        var sortKey: [String] {
            [
                sampleID,
                locusID,
                genotype,
                String(passedAlignments),
                String(passedUniqueReads),
                sampleUniqueRetainedReads.map(String.init) ?? "",
                String(originalIndex),
            ]
        }

        func observation(id: String) -> ObservationEvidence {
            ObservationEvidence(
                id: id,
                evidenceClass: evidenceClass,
                sampleID: sampleID,
                locusID: locusID,
                genotype: genotype,
                passedAlignments: passedAlignments,
                passedUniqueReads: passedUniqueReads,
                sampleUniqueRetainedReads: sampleUniqueRetainedReads
            )
        }
    }

    private struct RawCallSnapshot: Encodable, Comparable {
        let sample: String
        let genotype: String
        let locus: String
        let passedAlignments: Int
        let passedUniqueReads: Int
        let sampleTotalReads: Int?
        let sampleUniqueRetainedReads: Int?
        let sampleUniqueRetainedPercent: Double?
        let overallInputReads: Int?
        let overallUniqueRetainedReads: Int?
        let overallUniqueRetainedPercent: Double?

        static func < (lhs: RawCallSnapshot, rhs: RawCallSnapshot) -> Bool {
            lexicographicallyPrecedes(lhs.sortKey, rhs.sortKey)
        }

        private var sortKey: [String] {
            [
                sample,
                locus,
                genotype,
                String(passedAlignments),
                String(passedUniqueReads),
                sampleTotalReads.map(String.init) ?? "",
                sampleUniqueRetainedReads.map(String.init) ?? "",
                sampleUniqueRetainedPercent.map { String(describing: $0) } ?? "",
                overallInputReads.map(String.init) ?? "",
                overallUniqueRetainedReads.map(String.init) ?? "",
                overallUniqueRetainedPercent.map { String(describing: $0) } ?? "",
            ]
        }
    }

    private struct OverrideSnapshot: Encodable, Comparable {
        let sample: String
        let locus: String
        let slot: String
        let originalCall: String
        let overrideCall: String
        let reasonTag: String
        let rationale: String
        let author: String
        let timestamp: String

        static func < (lhs: OverrideSnapshot, rhs: OverrideSnapshot) -> Bool {
            lexicographicallyPrecedes(lhs.sortKey, rhs.sortKey)
        }

        private var sortKey: [String] {
            [
                sample,
                locus,
                slot,
                originalCall,
                overrideCall,
                reasonTag,
                rationale,
                author,
                timestamp,
            ]
        }
    }
}

public struct AIHaplotypingEvidenceChunker: Equatable, Sendable {
    public let maxObservationsPerChunk: Int

    public init(maxObservationsPerChunk: Int) {
        self.maxObservationsPerChunk = maxObservationsPerChunk
    }

    public func chunks(from registry: AIHaplotypingEvidenceRegistry) throws -> [AIHaplotypingEvidenceChunk] {
        guard maxObservationsPerChunk > 0 else {
            throw AIHaplotypingEvidenceError.invalidChunkSize(maxObservationsPerChunk)
        }

        let clusters = Dictionary(grouping: registry.observations.sorted(by: observationPrecedes(_:_:))) {
            EvidencePair(sampleID: $0.sampleID, locusID: $0.locusID)
        }
        .map { pair, observations in
            EvidenceCluster(pair: pair, observations: observations.sorted(by: observationPrecedes(_:_:)))
        }
        .sorted { lhs, rhs in
            lexicographicallyPrecedes(lhs.sortKey, rhs.sortKey)
        }

        var chunkObservationGroups: [[ObservationEvidence]] = []
        var currentObservations: [ObservationEvidence] = []
        for cluster in clusters {
            if !currentObservations.isEmpty,
               currentObservations.count + cluster.observations.count > maxObservationsPerChunk {
                chunkObservationGroups.append(currentObservations)
                currentObservations.removeAll()
            }
            currentObservations.append(contentsOf: cluster.observations)
        }
        if !currentObservations.isEmpty {
            chunkObservationGroups.append(currentObservations)
        }

        return chunkObservationGroups.enumerated().map { offset, chunkObservations in
            let observations = chunkObservations.sorted(by: observationPrecedes(_:_:))
            let pairs = Set(observations.map { EvidencePair(sampleID: $0.sampleID, locusID: $0.locusID) })
            let sampleIDs = Set(observations.map(\.sampleID))
            let locusIDs = Set(observations.map(\.locusID))
            let currentCalls = registry.currentCalls.filter {
                pairs.contains(EvidencePair(sampleID: sampleID(for: $0.sample), locusID: locusID(for: $0.locus)))
            }
            let manualReviews = registry.manualReviews.filter {
                pairs.contains(EvidencePair(sampleID: sampleID(for: $0.sample), locusID: locusID(for: $0.locus)))
            }
            let subregistry = AIHaplotypingEvidenceRegistry(
                schemaVersion: registry.schemaVersion,
                mode: registry.mode,
                parentRevisionID: registry.parentRevisionID,
                inputSnapshotDigest: registry.inputSnapshotDigest,
                samples: registry.samples.filter { sampleIDs.contains($0.id) },
                loci: registry.loci.filter { locusIDs.contains($0.id) },
                observations: observations,
                currentCalls: currentCalls,
                manualReviews: manualReviews
            )
            return AIHaplotypingEvidenceChunk(
                id: String(format: "chunk-%04d", offset + 1),
                registry: subregistry,
                allowedEvidenceIDs: subregistry.evidenceIDs
            )
        }
    }

    private func observationPrecedes(_ lhs: ObservationEvidence, _ rhs: ObservationEvidence) -> Bool {
        lexicographicallyPrecedes(observationSortKey(lhs), observationSortKey(rhs))
    }

    private func observationSortKey(_ observation: ObservationEvidence) -> [String] {
        [
            observation.locusID,
            observation.sampleID,
            observation.genotype,
            observation.id,
        ]
    }

    private func sampleID(for sample: String) -> String {
        "sample:\(sample)"
    }

    private func locusID(for locus: String) -> String {
        "locus:\(locus)"
    }

    private struct EvidencePair: Hashable {
        let sampleID: String
        let locusID: String
    }

    private struct EvidenceCluster {
        let pair: EvidencePair
        let observations: [ObservationEvidence]

        var sortKey: [String] {
            [pair.locusID, pair.sampleID]
        }
    }
}

private func lexicographicallyPrecedes(_ lhs: [String], _ rhs: [String]) -> Bool {
    for (left, right) in zip(lhs, rhs) {
        if left != right {
            return left < right
        }
    }
    return lhs.count < rhs.count
}
