import CryptoKit
import Foundation
import LungfishIO

enum FullLengthONTMHCReferenceReadiness: String, Codable, Equatable, Sendable {
    case referenceReady = "reference-ready"
    case incomplete = "not-reference-ready-incomplete"
    case unavailable = "not-reference-ready-unavailable"
}

struct FullLengthONTMHCCandidateCanonicalization: Sendable {
    let record: GenBankRecord
    let rawSequence: String
    let externalSequence: String?
    let trimRange: Range<Int>?
    let translationStatus: FullLengthONTMHCTranslationStatus
    let referenceReadiness: FullLengthONTMHCReferenceReadiness
}

struct FullLengthONTMHCCandidateCanonicalizer {
    struct Input: Sendable {
        let record: ONTMHCCandidateRecord
        let observations: [ONTMHCCandidateObservation]
        let canonicalization: FullLengthONTMHCCandidateCanonicalization
    }

    struct Output: Sendable {
        let record: ONTMHCCandidateRecord
        let observations: [ONTMHCCandidateObservation]
        let sequence: String
        let representativeCanonicalization: FullLengthONTMHCCandidateCanonicalization
        let rawInputs: [Input]
    }

    struct CandidateMergeKey: Hashable {
        let sequence: String
        let classification: String
        let locus: String
        let provisionalName: String
        let closestReferenceName: String
        let closestReferenceRawID: String
        let closestReferenceClass: String
        let extensionOf: [String]
        let provisionalNamingAmbiguous: Bool
    }

    enum Error: Swift.Error, LocalizedError, Equatable {
        case notReferenceReady(rawStableClusterID: String, readiness: String)
        case conflictingInterpretations(
            canonicalStableClusterID: String,
            rawStableClusterIDs: [String]
        )

        var errorDescription: String? {
            switch self {
            case .notReferenceReady(let id, let readiness):
                return "Named MHC candidate '\(id)' cannot be published because its UTR-trimmed genomic sequence is \(readiness)."
            case .conflictingInterpretations(let id, let rawIDs):
                return "Identical UTR-trimmed MHC sequence '\(id)' has conflicting biological interpretations across raw clusters: \(rawIDs.joined(separator: ", "))."
            }
        }
    }

    func aggregate(_ inputs: [Input]) throws -> [Output] {
        var bySequence: [String: [Input]] = [:]
        for input in inputs {
            guard input.canonicalization.referenceReadiness == .referenceReady,
                  let external = input.canonicalization.externalSequence else {
                throw Error.notReferenceReady(
                    rawStableClusterID: input.record.stableClusterID,
                    readiness: input.canonicalization.referenceReadiness.rawValue
                )
            }
            bySequence[normalized(external), default: []].append(input)
        }

        return try bySequence.map { sequence, values in
            let canonicalID = FullLengthONTMHCCandidateArtifactWriter.stableClusterID(for: sequence)
            let keyed = Dictionary(grouping: values, by: { mergeKey($0, sequence: sequence) })
            guard keyed.count == 1 else {
                throw Error.conflictingInterpretations(
                    canonicalStableClusterID: canonicalID,
                    rawStableClusterIDs: values.map(\.record.stableClusterID).sorted()
                )
            }
            let sorted = values.sorted(by: representativeLessThan)
            let representative = sorted[0]
            let rawIDs = values.map(\.record.stableClusterID).sorted()
            let observations = values.flatMap { input in
                input.observations.map { observation in
                    ONTMHCCandidateObservation(
                        stableClusterID: canonicalID,
                        sourceSequenceClusterID: input.record.stableClusterID,
                        sampleID: observation.sampleID,
                        readGroupID: observation.readGroupID,
                        sourceClusterIDs: observation.sourceClusterIDs,
                        sourceClusterReadCounts: observation.sourceClusterReadCounts,
                        aggregatedSampleReadCount: observation.aggregatedSampleReadCount,
                        genotypingHitSummaries: observation.genotypingHitSummaries
                    )
                }
            }.sorted(by: observationLessThan)
            let sampleIDs = Set(observations.map(\.sampleID)).sorted()
            let totalReads = observations.reduce(0) { $0 + $1.aggregatedSampleReadCount }
            let occurrenceCount = observations.reduce(0) {
                $0 + $1.sourceClusterIDs.count
            }
            let extensionInterpretations = mergedInterpretations(
                values.flatMap(\.record.extensionInterpretations),
                representative: representative.record.extensionInterpretations
            )
            let source = representative.record
            let record = ONTMHCCandidateRecord(
                stableClusterID: canonicalID,
                sourceSequenceClusterIDs: rawIDs,
                representativeSourceSequenceClusterID: source.stableClusterID,
                provisionalName: source.provisionalName,
                locus: source.locus,
                classification: source.classification,
                supportClass: sampleIDs.count >= 2 ? .shared : .singleton,
                closestReferenceName: source.closestReferenceName,
                closestReferenceClass: source.closestReferenceClass,
                snpCount: source.snpCount,
                insertedBases: source.insertedBases,
                deletedBases: source.deletedBases,
                longGapBases: source.longGapBases,
                comparableBases: source.comparableBases,
                shorterCoverage: source.shorterCoverage,
                identity: source.identity,
                mappingQuality: source.mappingQuality,
                alignmentScore: source.alignmentScore,
                independentSampleCount: sampleIDs.count,
                occurrenceCount: occurrenceCount,
                totalClusterReads: totalReads,
                supportingSampleIDs: sampleIDs,
                fastaRecordID: canonicalID,
                sequenceSHA256: sha256Hex(sequence),
                reciprocalHitSummary: source.reciprocalHitSummary,
                selectedEvidence: source.selectedEvidence,
                selectedAlignmentIsReverse: source.selectedAlignmentIsReverse,
                extensionOf: source.extensionOf.sorted(),
                extensionInterpretations: extensionInterpretations,
                provisionalNamingAmbiguous: source.provisionalNamingAmbiguous
            )
            return Output(
                record: record,
                observations: observations,
                sequence: sequence,
                representativeCanonicalization: representative.canonicalization,
                rawInputs: values.sorted { $0.record.stableClusterID < $1.record.stableClusterID }
            )
        }.sorted { $0.record.stableClusterID < $1.record.stableClusterID }
    }

    private func mergeKey(_ input: Input, sequence: String) -> CandidateMergeKey {
        let record = input.record
        return CandidateMergeKey(
            sequence: sequence,
            classification: record.classification.rawValue,
            locus: record.locus,
            provisionalName: record.provisionalName,
            closestReferenceName: record.closestReferenceName,
            closestReferenceRawID: record.selectedEvidence.referenceName,
            closestReferenceClass: record.closestReferenceClass.rawValue,
            extensionOf: record.extensionOf.sorted(),
            provisionalNamingAmbiguous: record.provisionalNamingAmbiguous
        )
    }

    private func representativeLessThan(_ lhs: Input, _ rhs: Input) -> Bool {
        if lhs.record.totalClusterReads != rhs.record.totalClusterReads {
            return lhs.record.totalClusterReads > rhs.record.totalClusterReads
        }
        return lhs.record.stableClusterID < rhs.record.stableClusterID
    }

    private func mergedInterpretations(
        _ values: [ONTMHCCDNAExtensionInterpretation],
        representative: [ONTMHCCDNAExtensionInterpretation]
    ) -> [ONTMHCCDNAExtensionInterpretation] {
        var byRawID: [String: ONTMHCCDNAExtensionInterpretation] = [:]
        for value in values.sorted(by: interpretationLessThan) {
            byRawID[value.rawReferenceID] = byRawID[value.rawReferenceID] ?? value
        }
        for value in representative {
            byRawID[value.rawReferenceID] = value
        }
        return byRawID.values.sorted {
            [$0.alleleName, $0.rawReferenceID]
                .lexicographicallyPrecedes([$1.alleleName, $1.rawReferenceID])
        }
    }

    private func interpretationLessThan(
        _ lhs: ONTMHCCDNAExtensionInterpretation,
        _ rhs: ONTMHCCDNAExtensionInterpretation
    ) -> Bool {
        if lhs.alignmentScore != rhs.alignmentScore {
            return lhs.alignmentScore > rhs.alignmentScore
        }
        if lhs.identity != rhs.identity {
            return lhs.identity > rhs.identity
        }
        if lhs.cDNAReferenceCoverage != rhs.cDNAReferenceCoverage {
            return lhs.cDNAReferenceCoverage > rhs.cDNAReferenceCoverage
        }
        return [lhs.alleleName, lhs.rawReferenceID]
            .lexicographicallyPrecedes([rhs.alleleName, rhs.rawReferenceID])
    }

    private func observationLessThan(
        _ lhs: ONTMHCCandidateObservation,
        _ rhs: ONTMHCCandidateObservation
    ) -> Bool {
        [
            lhs.stableClusterID, lhs.sampleID, lhs.readGroupID,
            lhs.sourceSequenceClusterID,
        ].lexicographicallyPrecedes([
            rhs.stableClusterID, rhs.sampleID, rhs.readGroupID,
            rhs.sourceSequenceClusterID,
        ])
    }

    private func normalized(_ sequence: String) -> String {
        sequence.filter { !$0.isWhitespace }.uppercased()
    }

    private func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
