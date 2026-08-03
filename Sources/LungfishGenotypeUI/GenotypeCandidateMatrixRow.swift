import Foundation
import LungfishIO

enum GenotypeCandidateMatrixRowID: Hashable, Equatable, Sendable {
    case known(locus: String, genotype: String)
    case candidate(stableClusterID: String)

    var deterministicSortKey: String {
        switch self {
        case let .known(locus, genotype):
            return "known\u{0}\(locus)\u{0}\(genotype)"
        case let .candidate(stableClusterID):
            return "candidate\u{0}\(stableClusterID)"
        }
    }
}

struct GenotypeCandidateMatrixRow: Equatable, Sendable {
    enum Population: Equatable, Sendable {
        case known
        case sharedCandidate
        case singletonCandidate
    }

    let id: GenotypeCandidateMatrixRowID
    let alleleName: String
    let locus: String
    let stableClusterID: String?
    let population: Population
    let tintCategory: ONTMHCCandidateTintCategory?
    let sampleSupport: [ONTGenotypeSampleSupport]
    let evidenceBySample: [String: [ONTMHCEvidenceLocator]]
    let candidate: ONTMHCCandidateRecord?
    let incompleteCandidateInterpretation: ONTMHCIncompleteCandidateInterpretation?

    var candidateClassification: ONTMHCCandidateClassification? {
        candidate?.classification ?? incompleteCandidateInterpretation?.classification
    }

    var isIncompleteReferenceSpanCandidate: Bool {
        incompleteCandidateInterpretation != nil
    }

    var genotype: String { alleleName }
    var sampleCount: Int { sampleSupport.count }
    var totalUniqueReads: Int { sampleSupport.reduce(0) { $0 + $1.passedUniqueReads } }
    var biologicalSortTieID: String { stableClusterID ?? id.deterministicSortKey }

    func support(for sample: String) -> ONTGenotypeSampleSupport? {
        sampleSupport.first { $0.sample == sample }
    }

    var sharedCall: ONTGenotypeSharedCall {
        ONTGenotypeSharedCall(locus: locus, genotype: alleleName, sampleSupport: sampleSupport)
    }

    static func known(_ call: ONTGenotypeSharedCall) -> Self {
        Self(
            id: .known(locus: call.locus, genotype: call.genotype),
            alleleName: call.genotype,
            locus: call.locus,
            stableClusterID: nil,
            population: .known,
            tintCategory: nil,
            sampleSupport: call.sampleSupport,
            evidenceBySample: [:],
            candidate: nil,
            incompleteCandidateInterpretation: nil
        )
    }
}

enum GenotypeCandidateMatrixProjection {
    static func rows(
        knownRows: [ONTGenotypeSharedCall],
        candidateDocument: ONTMHCCandidateAllelesDocument?,
        unnameableDocument: ONTMHCUnnameableClustersDocument? = nil,
        settings: ONTMHCCandidateDisplaySettings,
        usesBiologicalAlleleOrder: Bool = false
    ) -> [GenotypeCandidateMatrixRow] {
        var rows: [GenotypeCandidateMatrixRow] = settings.showKnown
            ? knownRows.map(GenotypeCandidateMatrixRow.known)
            : []

        if let candidateDocument {
            let observationsByCluster = Dictionary(grouping: candidateDocument.observations, by: \.stableClusterID)
            for candidate in candidateDocument.candidates where isVisible(candidate, settings: settings) {
                let observations = observationsByCluster[candidate.stableClusterID] ?? []
                let observationsBySample = Dictionary(grouping: observations, by: \.sampleID)
                let sampleSupport: [ONTGenotypeSampleSupport] = observationsBySample.map { sample, sampleObservations in
                    let reads = sampleObservations.reduce(0) { partial, observation in
                        partial + observation.aggregatedSampleReadCount
                    }
                    return ONTGenotypeSampleSupport(
                        sample: sample,
                        passedAlignments: reads,
                        passedUniqueReads: reads,
                        sampleUniqueRetainedReads: nil
                    )
                }.sorted { $0.sample.localizedStandardCompare($1.sample) == .orderedAscending }
                let evidenceBySample = observationsBySample.mapValues { observations in
                    observations.flatMap(\.evidence).sorted(by: evidenceComesBefore)
                }
                rows.append(GenotypeCandidateMatrixRow(
                    id: .candidate(stableClusterID: candidate.stableClusterID),
                    alleleName: candidate.provisionalName,
                    locus: candidate.locus,
                    stableClusterID: candidate.stableClusterID,
                    population: candidate.supportClass == .shared ? .sharedCandidate : .singletonCandidate,
                    tintCategory: tintCategory(for: candidate),
                    sampleSupport: sampleSupport,
                    evidenceBySample: evidenceBySample,
                    candidate: candidate,
                    incompleteCandidateInterpretation: nil
                ))
            }
        }

        if let unnameableDocument {
            let observationsByCluster = Dictionary(
                grouping: unnameableDocument.observations,
                by: \.stableClusterID
            )
            for record in unnameableDocument.clusters {
                guard record.reason == .incompleteReferenceSpan,
                      let interpretation = record.candidateInterpretation,
                      isVisible(record.supportClass, settings: settings) else {
                    continue
                }
                let observations = observationsByCluster[record.stableClusterID] ?? []
                let observationsBySample = Dictionary(grouping: observations, by: \.sampleID)
                let sampleSupport: [ONTGenotypeSampleSupport] = observationsBySample.map { sample, values in
                    let reads = values.reduce(0) {
                        $0 + $1.aggregatedSampleReadCount
                    }
                    return ONTGenotypeSampleSupport(
                        sample: sample,
                        passedAlignments: reads,
                        passedUniqueReads: reads,
                        sampleUniqueRetainedReads: nil
                    )
                }.sorted { $0.sample.localizedStandardCompare($1.sample) == .orderedAscending }
                let evidenceBySample = observationsBySample.mapValues { values in
                    values.flatMap(\.evidence).sorted(by: evidenceComesBefore)
                }
                rows.append(GenotypeCandidateMatrixRow(
                    id: .candidate(stableClusterID: record.stableClusterID),
                    alleleName: interpretation.provisionalName,
                    locus: interpretation.locus,
                    stableClusterID: record.stableClusterID,
                    population: record.supportClass == .shared
                        ? .sharedCandidate : .singletonCandidate,
                    tintCategory: tintCategory(
                        classification: interpretation.classification,
                        supportClass: record.supportClass
                    ),
                    sampleSupport: sampleSupport,
                    evidenceBySample: evidenceBySample,
                    candidate: nil,
                    incompleteCandidateInterpretation: interpretation
                ))
            }
        }

        return rows.sorted {
            rowComesBefore($0, $1, usesBiologicalAlleleOrder: usesBiologicalAlleleOrder)
        }
    }

    private static func isVisible(
        _ candidate: ONTMHCCandidateRecord,
        settings: ONTMHCCandidateDisplaySettings
    ) -> Bool {
        isVisible(candidate.supportClass, settings: settings)
    }

    private static func isVisible(
        _ supportClass: ONTMHCCandidateSupportClass,
        settings: ONTMHCCandidateDisplaySettings
    ) -> Bool {
        switch supportClass {
        case .shared: settings.showSharedCandidates
        case .singleton: settings.showSingletonCandidates
        }
    }

    private static func tintCategory(for candidate: ONTMHCCandidateRecord) -> ONTMHCCandidateTintCategory {
        tintCategory(
            classification: candidate.classification,
            supportClass: candidate.supportClass
        )
    }

    private static func tintCategory(
        classification: ONTMHCCandidateClassification,
        supportClass: ONTMHCCandidateSupportClass
    ) -> ONTMHCCandidateTintCategory {
        switch (classification, supportClass) {
        case (.novel, .shared): .sharedNovel
        case (.novel, .singleton): .singletonNovel
        case (.extension, .shared): .sharedExtension
        case (.extension, .singleton): .singletonExtension
        case (.partialExtension, .shared): .sharedExtension
        case (.partialExtension, .singleton): .singletonExtension
        }
    }

    private static func rowComesBefore(
        _ lhs: GenotypeCandidateMatrixRow,
        _ rhs: GenotypeCandidateMatrixRow,
        usesBiologicalAlleleOrder: Bool
    ) -> Bool {
        if usesBiologicalAlleleOrder {
            return MHCAlleleDisplayOrder.compare(
                lhs.alleleName,
                rhs.alleleName,
                lhsStableID: lhs.biologicalSortTieID,
                rhsStableID: rhs.biologicalSortTieID
            ) == .orderedAscending
        }
        let locusOrder = lhs.locus.localizedStandardCompare(rhs.locus)
        if locusOrder != .orderedSame { return locusOrder == .orderedAscending }
        let nameOrder = lhs.alleleName.localizedStandardCompare(rhs.alleleName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id.deterministicSortKey < rhs.id.deterministicSortKey
    }

    private static func evidenceComesBefore(_ lhs: ONTMHCEvidenceLocator, _ rhs: ONTMHCEvidenceLocator) -> Bool {
        let left = "\(lhs.bamPath)\u{0}\(lhs.queryName)\u{0}\(lhs.referenceName)\u{0}\(lhs.referenceStart)\u{0}\(lhs.cigar)"
        let right = "\(rhs.bamPath)\u{0}\(rhs.queryName)\u{0}\(rhs.referenceName)\u{0}\(rhs.referenceStart)\u{0}\(rhs.cigar)"
        return left < right
    }
}
