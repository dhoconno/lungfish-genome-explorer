import Foundation
import LungfishIO

/// Immutable scientific inputs for the comparison matrix. Expensive support
/// denominators are computed once; threshold drafts only derive visible rows.
struct GenotypeMatrixBaseProjection: Sendable {
    struct KnownOccurrence: Sendable {
        let call: ONTGenotypeCall
        let support: ONTGenotypeSampleSupport
        let viewedLocusDenominator: Int
        let sampleRetainedDenominator: Int?

        func supportFraction(for denominator: ONTGenotypeSupportDenominator) -> Double? {
            let denominatorValue: Int?
            switch denominator {
            case .viewedLocus:
                denominatorValue = viewedLocusDenominator
            case .sampleRetained:
                denominatorValue = sampleRetainedDenominator
            }
            guard let denominatorValue, denominatorValue > 0 else { return nil }
            return Double(call.passedUniqueReads) / Double(denominatorValue)
        }
    }

    struct Filter: Equatable, Sendable {
        var globalMinimumPercent: Double
        var globalDenominator: ONTGenotypeSupportDenominator
        var matrixMinimumReads: Int
        var matrixMinimumPercent: Double
        var matrixDenominator: ONTGenotypeSupportDenominator

        static let unfiltered = Self()

        init(
            globalMinimumPercent: Double = 0,
            globalDenominator: ONTGenotypeSupportDenominator = .viewedLocus,
            matrixMinimumReads: Int = 0,
            matrixMinimumPercent: Double = 0,
            matrixDenominator: ONTGenotypeSupportDenominator = .viewedLocus
        ) {
            self.globalMinimumPercent = max(0, globalMinimumPercent)
            self.globalDenominator = globalDenominator
            self.matrixMinimumReads = max(0, matrixMinimumReads)
            self.matrixMinimumPercent = max(0, matrixMinimumPercent)
            self.matrixDenominator = matrixDenominator
        }
    }

    struct Derived: Sendable {
        let rows: [GenotypeCandidateMatrixRow]
        let totalRowCount: Int
        let hiddenCellCount: Int
    }

    struct CellIdentity: Hashable, Sendable {
        let locus: String
        let genotype: String
        let sample: String
        let stableClusterID: String?
    }

    struct ScientificIdentity: Equatable, Sendable {
        let calls: [ONTGenotypeCall]
        let samples: [ONTGenotypeSampleResult]
        let candidateDocument: ONTMHCCandidateAllelesDocument?
        let unnameableDocument: ONTMHCUnnameableClustersDocument?
        let logicalSampleNames: [String]
        let showKnown: Bool
        let showSharedCandidates: Bool
        let showSingletonCandidates: Bool
        let usesBiologicalAlleleOrder: Bool
    }

    let knownOccurrences: [KnownOccurrence]
    let scientificIdentity: ScientificIdentity

    private let candidateRows: [GenotypeCandidateMatrixRow]
    private let supportFractionsByDenominator:
        [ONTGenotypeSupportDenominator: [CellIdentity: Double]]
    private let logicalSampleNames: Set<String>
    private let candidateCellCount: Int
    private let totalRowCount: Int
    private let candidateSettings: ONTMHCCandidateDisplaySettings
    private let usesBiologicalAlleleOrder: Bool

    init(
        calls: [ONTGenotypeCall],
        samples: [ONTGenotypeSampleResult],
        candidateDocument: ONTMHCCandidateAllelesDocument?,
        unnameableDocument: ONTMHCUnnameableClustersDocument? = nil,
        logicalSampleNames: [String],
        candidateSettings: ONTMHCCandidateDisplaySettings,
        usesBiologicalAlleleOrder: Bool = false
    ) {
        var viewedLocusDenominators: [SupportBucket: Int] = [:]
        viewedLocusDenominators.reserveCapacity(calls.count)
        for call in calls {
            viewedLocusDenominators[
                SupportBucket(sample: call.sample, locus: call.locusGroup),
                default: 0
            ] += call.passedUniqueReads
        }

        var retainedBySample: [String: Int] = [:]
        retainedBySample.reserveCapacity(samples.count)
        for sample in samples where retainedBySample[sample.sample] == nil {
            retainedBySample[sample.sample] = sample.passedUniqueReads
        }

        knownOccurrences = calls.map { call in
            KnownOccurrence(
                call: call,
                support: ONTGenotypeSampleSupport(
                    sample: call.sample,
                    passedAlignments: call.passedAlignments,
                    passedUniqueReads: call.passedUniqueReads,
                    sampleUniqueRetainedReads: call.sampleUniqueRetainedReads
                ),
                viewedLocusDenominator: viewedLocusDenominators[
                    SupportBucket(sample: call.sample, locus: call.locusGroup),
                    default: 0
                ],
                sampleRetainedDenominator: call.sampleUniqueRetainedReads
                    ?? retainedBySample[call.sample]
            )
        }

        self.logicalSampleNames = Set(logicalSampleNames)
        self.candidateSettings = candidateSettings
        self.usesBiologicalAlleleOrder = usesBiologicalAlleleOrder
        candidateRows = GenotypeCandidateMatrixProjection.rows(
            knownRows: [],
            candidateDocument: candidateDocument,
            unnameableDocument: unnameableDocument,
            settings: candidateSettings,
            usesBiologicalAlleleOrder: usesBiologicalAlleleOrder
        )
        let candidateCells = candidateDocument.map { document in
            Set(document.observations.map {
                CandidateCell(stableClusterID: $0.stableClusterID, sample: $0.sampleID)
            })
        } ?? []
        let interpretedClusterIDs = Set(unnameableDocument?.clusters.compactMap {
            $0.candidateInterpretation == nil ? nil : $0.stableClusterID
        } ?? [])
        let incompleteCandidateCells = Set((unnameableDocument?.observations ?? []).compactMap {
            interpretedClusterIDs.contains($0.stableClusterID)
                ? CandidateCell(stableClusterID: $0.stableClusterID, sample: $0.sampleID)
                : nil
        })
        candidateCellCount = candidateCells.union(incompleteCandidateCells).count
        var viewedFractions: [CellIdentity: Double] = [:]
        var retainedFractions: [CellIdentity: Double] = [:]
        for occurrence in knownOccurrences {
            let identity = CellIdentity(
                locus: occurrence.call.locusGroup,
                genotype: occurrence.call.genotype,
                sample: occurrence.call.sample,
                stableClusterID: nil
            )
            if viewedFractions[identity] == nil,
               let fraction = occurrence.supportFraction(for: .viewedLocus) {
                viewedFractions[identity] = fraction
            }
            if retainedFractions[identity] == nil,
               let fraction = occurrence.supportFraction(for: .sampleRetained) {
                retainedFractions[identity] = fraction
            }
        }
        let eligibleSampleCount = Set(logicalSampleNames).count
        if eligibleSampleCount > 0, let candidateDocument {
            let observationsByCluster = Dictionary(
                grouping: candidateDocument.observations,
                by: \.stableClusterID
            )
            for candidate in candidateDocument.candidates {
                let supportingSamples = Set(
                    (observationsByCluster[candidate.stableClusterID] ?? [])
                        .map(\.sampleID)
                )
                let populationFraction =
                    Double(supportingSamples.count) / Double(eligibleSampleCount)
                for sample in supportingSamples {
                    let identity = CellIdentity(
                        locus: candidate.locus,
                        genotype: candidate.provisionalName,
                        sample: sample,
                        stableClusterID: candidate.stableClusterID
                    )
                    viewedFractions[identity] = populationFraction
                    retainedFractions[identity] = populationFraction
                }
            }
        }
        if eligibleSampleCount > 0, let unnameableDocument {
            let observationsByCluster = Dictionary(
                grouping: unnameableDocument.observations,
                by: \.stableClusterID
            )
            for record in unnameableDocument.clusters {
                guard let interpretation = record.candidateInterpretation else { continue }
                let supportingSamples = Set(
                    (observationsByCluster[record.stableClusterID] ?? []).map(\.sampleID)
                )
                let populationFraction =
                    Double(supportingSamples.count) / Double(eligibleSampleCount)
                for sample in supportingSamples {
                    let identity = CellIdentity(
                        locus: interpretation.locus,
                        genotype: interpretation.provisionalName,
                        sample: sample,
                        stableClusterID: record.stableClusterID
                    )
                    viewedFractions[identity] = populationFraction
                    retainedFractions[identity] = populationFraction
                }
            }
        }
        supportFractionsByDenominator = [
            .viewedLocus: viewedFractions,
            .sampleRetained: retainedFractions,
        ]
        totalRowCount = Set(calls.map {
            KnownRow(locus: $0.locusGroup, genotype: $0.genotype)
        }).count + (candidateDocument?.candidates.count ?? 0)
            + interpretedClusterIDs.count
        scientificIdentity = ScientificIdentity(
            calls: calls,
            samples: samples,
            candidateDocument: candidateDocument,
            unnameableDocument: unnameableDocument,
            logicalSampleNames: logicalSampleNames,
            showKnown: candidateSettings.showKnown,
            showSharedCandidates: candidateSettings.showSharedCandidates,
            showSingletonCandidates: candidateSettings.showSingletonCandidates,
            usesBiologicalAlleleOrder: usesBiologicalAlleleOrder
        )
    }

    func derive(_ filter: Filter) -> Derived {
        let globalThreshold = filter.globalMinimumPercent / 100
        let matrixThreshold = filter.matrixMinimumPercent / 100
        let filteredOccurrences = knownOccurrences.filter { occurrence in
            if globalThreshold > 0 {
                guard let fraction = occurrence.supportFraction(for: filter.globalDenominator),
                      fraction >= globalThreshold else {
                    return false
                }
            }
            if matrixThreshold > 0 {
                guard let fraction = occurrence.supportFraction(for: filter.matrixDenominator),
                      fraction >= matrixThreshold else {
                    return false
                }
            }
            return filter.matrixMinimumReads == 0
                || occurrence.call.passedUniqueReads >= filter.matrixMinimumReads
        }

        let knownRows: [ONTGenotypeSharedCall]
        if candidateSettings.showKnown {
            let grouped = Dictionary(grouping: filteredOccurrences) {
                KnownRow(locus: $0.call.locusGroup, genotype: $0.call.genotype)
            }
            knownRows = grouped.map { identity, occurrences in
                ONTGenotypeSharedCall(
                    locus: identity.locus,
                    genotype: identity.genotype,
                    sampleSupport: occurrences.map(\.support)
                )
            }
        } else {
            knownRows = []
        }

        var candidateRows = self.candidateRows
        if globalThreshold > 0 || matrixThreshold > 0 || filter.matrixMinimumReads > 0 {
            candidateRows = candidateRows.compactMap { row in
                if globalThreshold > 0 {
                    guard let fraction = candidatePopulationFraction(for: row),
                          fraction >= globalThreshold else {
                        return nil
                    }
                }
                if matrixThreshold > 0 {
                    guard let fraction = candidatePopulationFraction(for: row),
                          fraction >= matrixThreshold else {
                        return nil
                    }
                }
                let support = filter.matrixMinimumReads > 0
                    ? row.sampleSupport.filter {
                        $0.passedUniqueReads >= filter.matrixMinimumReads
                    }
                    : row.sampleSupport
                guard !support.isEmpty else { return nil }
                return GenotypeCandidateMatrixRow(
                    id: row.id,
                    alleleName: row.alleleName,
                    locus: row.locus,
                    stableClusterID: row.stableClusterID,
                    population: row.population,
                    tintCategory: row.tintCategory,
                    sampleSupport: support,
                    evidenceBySample: row.evidenceBySample,
                    candidate: row.candidate,
                    incompleteCandidateInterpretation: row.incompleteCandidateInterpretation
                )
            }
        }

        let projectedRows = GenotypeCandidateMatrixProjection.rows(
            knownRows: knownRows,
            candidateDocument: nil,
            settings: candidateSettings,
            usesBiologicalAlleleOrder: usesBiologicalAlleleOrder
        ) + candidateRows
        let sortedRows = projectedRows.sorted(by: rowComesBefore)
        let visibleCellCount = sortedRows.reduce(0) { $0 + $1.sampleCount }
        return Derived(
            rows: sortedRows,
            totalRowCount: totalRowCount,
            hiddenCellCount: max(
                0,
                knownOccurrences.count + candidateCellCount - visibleCellCount
            )
        )
    }

    private func candidatePopulationFraction(for row: GenotypeCandidateMatrixRow) -> Double? {
        guard !logicalSampleNames.isEmpty else { return nil }
        let supportingSamples = Set(row.sampleSupport.map(\.sample))
            .intersection(logicalSampleNames)
        return Double(supportingSamples.count) / Double(logicalSampleNames.count)
    }

    func supportFractions(
        for denominator: ONTGenotypeSupportDenominator
    ) -> [CellIdentity: Double] {
        supportFractionsByDenominator[denominator] ?? [:]
    }

    private func rowComesBefore(
        _ lhs: GenotypeCandidateMatrixRow,
        _ rhs: GenotypeCandidateMatrixRow
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
}

private extension GenotypeMatrixBaseProjection {
    struct SupportBucket: Hashable {
        let sample: String
        let locus: String
    }

    struct KnownRow: Hashable {
        let locus: String
        let genotype: String
    }

    struct CandidateCell: Hashable {
        let stableClusterID: String
        let sample: String
    }
}
