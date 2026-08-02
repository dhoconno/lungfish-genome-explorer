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
    let substitutionCount: Int
    let comparableBases: Int
    let identity: Double
    let shorterCoverage: Double
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
        case noPublishableObservedSequence(rawStableClusterID: String, readiness: String)
        case conflictingInterpretations(
            canonicalStableClusterID: String,
            rawStableClusterIDs: [String]
        )

        var errorDescription: String? {
            switch self {
            case .noPublishableObservedSequence(let id, let readiness):
                return "Named MHC candidate '\(id)' cannot be published because no resolved observed sequence is available (\(readiness))."
            case .conflictingInterpretations(let id, let rawIDs):
                return "Identical UTR-trimmed MHC sequence '\(id)' has conflicting biological interpretations across raw clusters: \(rawIDs.joined(separator: ", "))."
            }
        }
    }

    func aggregate(_ inputs: [Input]) throws -> [Output] {
        var bySequence: [String: [Input]] = [:]
        for input in inputs {
            guard input.canonicalization.referenceReadiness != .unavailable,
                  let external = input.canonicalization.externalSequence else {
                throw Error.noPublishableObservedSequence(
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
            let rawObservations = values.flatMap { input in
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
            }
            let observations = aggregateObservations(
                rawObservations,
                canonicalStableClusterID: canonicalID
            )
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
            let canonicalSubstitutionCount = representative.canonicalization.substitutionCount
            let canonicalProvisionalName = provisionalName(
                for: representative,
                substitutionCount: canonicalSubstitutionCount
            )
            let record = ONTMHCCandidateRecord(
                stableClusterID: canonicalID,
                sourceSequenceClusterIDs: rawIDs,
                representativeSourceSequenceClusterID: source.stableClusterID,
                provisionalName: canonicalProvisionalName,
                locus: source.locus,
                classification: source.classification,
                supportClass: sampleIDs.count >= 2 ? .shared : .singleton,
                closestReferenceName: source.closestReferenceName,
                closestReferenceClass: source.closestReferenceClass,
                snpCount: source.classification == .novel
                    ? canonicalSubstitutionCount
                    : source.snpCount,
                insertedBases: source.insertedBases,
                deletedBases: source.deletedBases,
                longGapBases: source.longGapBases,
                comparableBases: representative.canonicalization.comparableBases,
                shorterCoverage: representative.canonicalization.shorterCoverage,
                identity: representative.canonicalization.identity,
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
        let substitutionCount = input.canonicalization.substitutionCount
        return CandidateMergeKey(
            sequence: sequence,
            classification: record.classification.rawValue,
            locus: record.locus,
            provisionalName: provisionalName(
                for: input,
                substitutionCount: substitutionCount
            ),
            closestReferenceName: record.closestReferenceName,
            closestReferenceRawID: record.selectedEvidence.referenceName,
            closestReferenceClass: record.closestReferenceClass.rawValue,
            extensionOf: record.extensionOf.sorted(),
            provisionalNamingAmbiguous: record.provisionalNamingAmbiguous
        )
    }

    private func provisionalName(
        for input: Input,
        substitutionCount: Int
    ) -> String {
        guard input.record.classification == .novel else {
            return input.record.provisionalName
        }
        let expectedRawName = "\(input.record.closestReferenceName)_\(input.record.snpCount)nt_nov"
        guard input.record.provisionalName == expectedRawName else {
            // Only the substitution count is canonicalized. Preserve any other
            // provisional-name disagreement so merge validation still rejects
            // conflicting biological interpretations.
            return input.record.provisionalName
        }
        return "\(input.record.closestReferenceName)_\(substitutionCount)nt_nov"
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

    private func aggregateObservations(
        _ observations: [ONTMHCCandidateObservation],
        canonicalStableClusterID: String
    ) -> [ONTMHCCandidateObservation] {
        struct Key: Hashable {
            let sampleID: String
            let readGroupID: String
        }
        return Dictionary(grouping: observations) {
            Key(sampleID: $0.sampleID, readGroupID: $0.readGroupID)
        }.map { key, values in
            var sourceClusterReadCounts: [String: Int] = [:]
            var summaries: [ONTMHCGenotypingTargetHitSummary] = []
            for value in values {
                for (sourceID, count) in value.sourceClusterReadCounts {
                    sourceClusterReadCounts[sourceID, default: 0] += count
                }
                summaries.append(contentsOf: value.genotypingHitSummaries)
            }
            let sortedSummaries = summaries.sorted(by: genotypingSummaryLessThan)
            let uniqueSummaries = sortedSummaries.enumerated().compactMap { index, summary in
                index == 0 || sortedSummaries[index - 1] != summary ? summary : nil
            }
            let representativeRawID = values.sorted {
                if $0.aggregatedSampleReadCount != $1.aggregatedSampleReadCount {
                    return $0.aggregatedSampleReadCount > $1.aggregatedSampleReadCount
                }
                return $0.sourceSequenceClusterID < $1.sourceSequenceClusterID
            }[0].sourceSequenceClusterID
            return ONTMHCCandidateObservation(
                stableClusterID: canonicalStableClusterID,
                sourceSequenceClusterID: representativeRawID,
                sampleID: key.sampleID,
                readGroupID: key.readGroupID,
                sourceClusterIDs: sourceClusterReadCounts.keys.sorted(),
                sourceClusterReadCounts: sourceClusterReadCounts,
                aggregatedSampleReadCount: sourceClusterReadCounts.values.reduce(0, +),
                genotypingHitSummaries: uniqueSummaries
            )
        }.sorted(by: observationLessThan)
    }

    private func genotypingSummaryLessThan(
        _ lhs: ONTMHCGenotypingTargetHitSummary,
        _ rhs: ONTMHCGenotypingTargetHitSummary
    ) -> Bool {
        if lhs.targetName != rhs.targetName { return lhs.targetName < rhs.targetName }
        return lhs.bamPath < rhs.bamPath
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
