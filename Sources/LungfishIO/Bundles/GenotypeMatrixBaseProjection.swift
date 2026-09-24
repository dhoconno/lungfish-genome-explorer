import Foundation

/// Immutable scientific inputs for the comparison matrix. Expensive support
/// denominators are computed once; threshold drafts only derive visible rows.
public struct GenotypeMatrixBaseProjection: Sendable {
    public struct KnownOccurrence: Sendable {
        public let call: ONTGenotypeCall
        public let support: ONTGenotypeSampleSupport
        public let viewedLocusDenominator: Int
        public let sampleRetainedDenominator: Int?

        public func supportFraction(for denominator: ONTGenotypeSupportDenominator) -> Double? {
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

    /// Matrix visibility thresholds.
    ///
    /// Every percent threshold is a per-sample READ FRACTION, applied cell by
    /// cell to known and candidate rows alike (GEN-06, decision D14). With the
    /// `.viewedLocus` basis the denominator is `GenotypeLocusDenominator`, the
    /// sample's unique retained reads at the allele's source locus (GEN-05,
    /// D13). Prevalence across animals is a separate control,
    /// `minimumPrevalencePercent` ("Seen in at least N% of animals").
    public struct Filter: Codable, Equatable, Sendable {
        public var globalMinimumPercent: Double
        public var globalDenominator: ONTGenotypeSupportDenominator
        public var matrixMinimumReads: Int
        public var matrixMinimumPercent: Double
        public var matrixDenominator: ONTGenotypeSupportDenominator
        /// Hide a row unless its visible, positive cells cover at least this
        /// percent of the logical sample roster. 0 turns the control off.
        public var minimumPrevalencePercent: Double

        public static let unfiltered = Self()

        public var hasActiveNumericThresholds: Bool {
            globalMinimumPercent > 0
                || matrixMinimumReads > 0
                || matrixMinimumPercent > 0
                || minimumPrevalencePercent > 0
        }

        public init(
            globalMinimumPercent: Double = 0,
            globalDenominator: ONTGenotypeSupportDenominator = .viewedLocus,
            matrixMinimumReads: Int = 0,
            matrixMinimumPercent: Double = 0,
            matrixDenominator: ONTGenotypeSupportDenominator = .viewedLocus,
            minimumPrevalencePercent: Double = 0
        ) {
            self.globalMinimumPercent = max(0, globalMinimumPercent)
            self.globalDenominator = globalDenominator
            self.matrixMinimumReads = max(0, matrixMinimumReads)
            self.matrixMinimumPercent = max(0, matrixMinimumPercent)
            self.matrixDenominator = matrixDenominator
            self.minimumPrevalencePercent = max(0, min(100, minimumPrevalencePercent))
        }

        private enum CodingKeys: String, CodingKey {
            case globalMinimumPercent, globalDenominator, matrixMinimumReads
            case matrixMinimumPercent, matrixDenominator, minimumPrevalencePercent
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                globalMinimumPercent: try container.decode(Double.self, forKey: .globalMinimumPercent),
                globalDenominator: try container.decode(ONTGenotypeSupportDenominator.self, forKey: .globalDenominator),
                matrixMinimumReads: try container.decode(Int.self, forKey: .matrixMinimumReads),
                matrixMinimumPercent: try container.decode(Double.self, forKey: .matrixMinimumPercent),
                matrixDenominator: try container.decode(ONTGenotypeSupportDenominator.self, forKey: .matrixDenominator),
                minimumPrevalencePercent: try container.decodeIfPresent(
                    Double.self, forKey: .minimumPrevalencePercent
                ) ?? 0
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(globalMinimumPercent, forKey: .globalMinimumPercent)
            try container.encode(globalDenominator, forKey: .globalDenominator)
            try container.encode(matrixMinimumReads, forKey: .matrixMinimumReads)
            try container.encode(matrixMinimumPercent, forKey: .matrixMinimumPercent)
            try container.encode(matrixDenominator, forKey: .matrixDenominator)
            // Omitted when off so captures made before the control existed
            // re-encode byte for byte.
            if minimumPrevalencePercent > 0 {
                try container.encode(minimumPrevalencePercent, forKey: .minimumPrevalencePercent)
            }
        }

        /// Whether one cell's read fraction passes both percent thresholds.
        public func admitsReadFraction(
            _ fraction: (ONTGenotypeSupportDenominator) -> Double?
        ) -> Bool {
            if globalMinimumPercent > 0 {
                guard let value = fraction(globalDenominator), value >= globalMinimumPercent / 100 else {
                    return false
                }
            }
            if matrixMinimumPercent > 0 {
                guard let value = fraction(matrixDenominator), value >= matrixMinimumPercent / 100 else {
                    return false
                }
            }
            return true
        }

        /// Whether a row seen (positive and visible) in `supportingSamples`
        /// passes the prevalence control over the logical roster.
        public func admitsPrevalence(supportingSamples: Set<String>, logicalSamples: Set<String>) -> Bool {
            guard minimumPrevalencePercent > 0 else { return true }
            guard let prevalence = GenotypeMatrixBaseProjection.prevalenceFraction(
                supportingSamples: supportingSamples,
                logicalSamples: logicalSamples
            ) else { return false }
            return prevalence >= minimumPrevalencePercent / 100
        }
    }

    public struct Derived: Sendable {
        public let rows: [GenotypeCandidateMatrixRow]
        public let totalRowCount: Int
        public let hiddenCellCount: Int
    }

    public struct CellIdentity: Hashable, Sendable {
        public let locus: String
        public let genotype: String
        public let sample: String
        public let stableClusterID: String?
        public init(locus: String, genotype: String, sample: String, stableClusterID: String?) {
            self.locus = locus; self.genotype = genotype; self.sample = sample; self.stableClusterID = stableClusterID
        }
    }

    public struct ScientificIdentity: Equatable, Sendable {
        public let calls: [ONTGenotypeCall]
        public let samples: [ONTGenotypeSampleResult]
        public let candidateDocument: ONTMHCCandidateAllelesDocument?
        public let unnameableDocument: ONTMHCUnnameableClustersDocument?
        public let logicalSampleNames: [String]
        public let showKnown: Bool
        public let showSharedCandidates: Bool
        public let showSingletonCandidates: Bool
        public let usesBiologicalAlleleOrder: Bool
        public let locusDisplayOrder: [String]?
        public let usesNumericReferenceOrder: Bool
    }

    public let knownOccurrences: [KnownOccurrence]
    public let scientificIdentity: ScientificIdentity

    private let candidateRows: [GenotypeCandidateMatrixRow]
    private let candidateCellFractions:
        [ONTGenotypeSupportDenominator: [CandidateCell: Double]]
    private let supportFractionsByDenominator:
        [ONTGenotypeSupportDenominator: [CellIdentity: Double]]
    private let logicalSampleNames: Set<String>
    private let candidateCellCount: Int
    private let totalRowCount: Int
    private let candidateSettings: ONTMHCCandidateDisplaySettings
    private let usesBiologicalAlleleOrder: Bool
    private let locusDisplayOrder: [String]?
    private let usesNumericReferenceOrder: Bool

    public init(
        calls: [ONTGenotypeCall],
        samples: [ONTGenotypeSampleResult],
        candidateDocument: ONTMHCCandidateAllelesDocument?,
        unnameableDocument: ONTMHCUnnameableClustersDocument? = nil,
        logicalSampleNames: [String],
        candidateSettings: ONTMHCCandidateDisplaySettings,
        usesBiologicalAlleleOrder: Bool = false,
        locusDisplayOrder: [String]? = nil,
        usesNumericReferenceOrder: Bool = false
    ) {
        // GEN-05 (D13): one per-source-locus denominator, shared with the
        // haplotype caller, the evidence pane and the Excel filter.
        let locusDenominator = GenotypeLocusDenominator(
            calls: calls,
            candidateDocument: candidateDocument,
            unnameableDocument: unnameableDocument
        )

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
                viewedLocusDenominator: locusDenominator.total(for: call),
                sampleRetainedDenominator: call.sampleUniqueRetainedReads
                    ?? retainedBySample[call.sample]
            )
        }

        self.logicalSampleNames = Set(logicalSampleNames)
        self.candidateSettings = candidateSettings
        self.usesBiologicalAlleleOrder = usesBiologicalAlleleOrder
        self.locusDisplayOrder = locusDisplayOrder
        self.usesNumericReferenceOrder = usesNumericReferenceOrder
        candidateRows = GenotypeCandidateMatrixProjection.rows(
            knownRows: [],
            candidateDocument: candidateDocument,
            unnameableDocument: unnameableDocument,
            settings: candidateSettings,
            usesBiologicalAlleleOrder: usesBiologicalAlleleOrder,
            locusDisplayOrder: locusDisplayOrder,
            usesNumericReferenceOrder: usesNumericReferenceOrder
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
        // GEN-06 (D14): a candidate cell's percent is its read fraction in
        // that sample, with the same denominators as known alleles.
        var candidateViewed: [CandidateCell: Double] = [:]
        var candidateRetained: [CandidateCell: Double] = [:]
        func recordCandidate(
            stableClusterID: String,
            locus: String,
            genotype: String,
            observations: [(sample: String, reads: Int)]
        ) {
            var readsBySample: [String: Int] = [:]
            for observation in observations {
                readsBySample[observation.sample, default: 0] += max(0, observation.reads)
            }
            for (sample, reads) in readsBySample {
                let cell = CandidateCell(stableClusterID: stableClusterID, sample: sample)
                let identity = CellIdentity(
                    locus: locus,
                    genotype: genotype,
                    sample: sample,
                    stableClusterID: stableClusterID
                )
                if let fraction = locusDenominator.fraction(reads: reads, sample: sample, sourceLocus: locus) {
                    candidateViewed[cell] = fraction
                    viewedFractions[identity] = fraction
                }
                if let retained = retainedBySample[sample], retained > 0 {
                    let fraction = Double(reads) / Double(retained)
                    candidateRetained[cell] = fraction
                    retainedFractions[identity] = fraction
                }
            }
        }
        if let candidateDocument {
            let observationsByCluster = Dictionary(
                grouping: candidateDocument.observations,
                by: \.stableClusterID
            )
            for candidate in candidateDocument.candidates {
                recordCandidate(
                    stableClusterID: candidate.stableClusterID,
                    locus: candidate.locus,
                    genotype: candidate.provisionalName,
                    observations: (observationsByCluster[candidate.stableClusterID] ?? [])
                        .map { ($0.sampleID, $0.aggregatedSampleReadCount) }
                )
            }
        }
        if let unnameableDocument {
            let observationsByCluster = Dictionary(
                grouping: unnameableDocument.observations,
                by: \.stableClusterID
            )
            for record in unnameableDocument.clusters {
                guard let interpretation = record.candidateInterpretation else { continue }
                recordCandidate(
                    stableClusterID: record.stableClusterID,
                    locus: interpretation.locus,
                    genotype: interpretation.provisionalName,
                    observations: (observationsByCluster[record.stableClusterID] ?? [])
                        .map { ($0.sampleID, $0.aggregatedSampleReadCount) }
                )
            }
        }
        candidateCellFractions = [
            .viewedLocus: candidateViewed,
            .sampleRetained: candidateRetained,
        ]
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
            usesBiologicalAlleleOrder: usesBiologicalAlleleOrder,
            locusDisplayOrder: locusDisplayOrder,
            usesNumericReferenceOrder: usesNumericReferenceOrder
        )
    }

    public func derive(_ filter: Filter) -> Derived {
        let filteredOccurrences = knownOccurrences.filter { occurrence in
            guard filter.admitsReadFraction({ occurrence.supportFraction(for: $0) }) else {
                return false
            }
            return filter.matrixMinimumReads == 0
                || occurrence.call.passedUniqueReads >= filter.matrixMinimumReads
        }

        let knownRows: [ONTGenotypeSharedCall]
        if candidateSettings.showKnown {
            let grouped = Dictionary(grouping: filteredOccurrences) {
                KnownRow(locus: $0.call.locusGroup, genotype: $0.call.genotype)
            }
            knownRows = grouped.compactMap { identity, occurrences in
                guard filter.admitsPrevalence(
                    supportingSamples: Set(occurrences.filter { $0.call.passedUniqueReads > 0 }.map(\.call.sample)),
                    logicalSamples: logicalSampleNames
                ) else {
                    return nil
                }
                return ONTGenotypeSharedCall(
                    locus: identity.locus,
                    genotype: identity.genotype,
                    sampleSupport: occurrences.map(\.support)
                )
            }
        } else {
            knownRows = []
        }

        var candidateRows = self.candidateRows
        if filter.hasActiveNumericThresholds {
            candidateRows = candidateRows.compactMap { row in
                let support = row.sampleSupport.filter { cell in
                    if filter.matrixMinimumReads > 0, cell.passedUniqueReads < filter.matrixMinimumReads {
                        return false
                    }
                    guard let stableClusterID = row.stableClusterID else { return true }
                    let key = CandidateCell(stableClusterID: stableClusterID, sample: cell.sample)
                    return filter.admitsReadFraction { candidateCellFractions[$0]?[key] }
                }
                guard !support.isEmpty,
                      filter.admitsPrevalence(
                        supportingSamples: Set(support.filter { $0.passedUniqueReads > 0 }.map(\.sample)),
                        logicalSamples: logicalSampleNames
                      ) else {
                    return nil
                }
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
            usesBiologicalAlleleOrder: usesBiologicalAlleleOrder,
            locusDisplayOrder: locusDisplayOrder,
            usesNumericReferenceOrder: usesNumericReferenceOrder
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

    /// Prevalence ("Seen in at least N% of animals"): positive supporting
    /// samples over the full logical sample roster. Only the separate
    /// prevalence control uses it; it is never a percent-of-reads basis.
    public static func prevalenceFraction(supportingSamples: Set<String>, logicalSamples: Set<String>) -> Double? {
        guard !logicalSamples.isEmpty else { return nil }
        return Double(supportingSamples.intersection(logicalSamples).count) / Double(logicalSamples.count)
    }

    public func supportFractions(
        for denominator: ONTGenotypeSupportDenominator
    ) -> [CellIdentity: Double] {
        supportFractionsByDenominator[denominator] ?? [:]
    }

    private func rowComesBefore(
        _ lhs: GenotypeCandidateMatrixRow,
        _ rhs: GenotypeCandidateMatrixRow
    ) -> Bool {
        if usesNumericReferenceOrder, locusDisplayOrder == nil,
           let order = GenotypeReferenceNumericPrefixOrder.compare(lhs.genotype, rhs.genotype), order != .orderedSame {
            return order == .orderedAscending
        }
        if usesBiologicalAlleleOrder || locusDisplayOrder != nil {
            return MHCAlleleDisplayOrder.compare(
                MHCReferenceGenotypeDisplay.alleleName(for: lhs.alleleName),
                MHCReferenceGenotypeDisplay.alleleName(for: rhs.alleleName),
                lhsStableID: lhs.biologicalSortTieID,
                rhsStableID: rhs.biologicalSortTieID,
                locusDisplayOrder: locusDisplayOrder
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
    struct KnownRow: Hashable {
        let locus: String
        let genotype: String
    }

    struct CandidateCell: Hashable {
        let stableClusterID: String
        let sample: String
    }
}
