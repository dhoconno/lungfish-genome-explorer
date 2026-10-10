import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeResultBundleData: Codable, Equatable, Sendable {
    /// Portable result snapshot first; older results can use their explicitly recorded reference bundle.
    public var genotypeLocusDisplayOrder: [String]? {
        manifest.genotypeLocusDisplayOrder ?? ONTGenotypeResultBundle.referenceGenotypeLocusDisplayOrder(
            manifest: manifest, in: bundleURL
        )
    }

    public let bundleURL: URL
    public let manifest: ONTGenotypeResultBundleManifest
    public let artifacts: ONTGenotypeResultArtifacts
    public let stats: ONTGenotypeRunStats
    public let calls: [ONTGenotypeCall]
    public let samples: [ONTGenotypeSampleResult]
    public let haplotypeAnalysis: GenotypeHaplotypeAnalysis?
    public let mhcCandidates: ONTMHCCandidateAllelesDocument?
    public let mhcUnnameableClusters: ONTMHCUnnameableClustersDocument?
    public let mhcCandidateSequencesByStableClusterID: [String: String]
    public let mhcCandidateGenBankArtifactURLs: ONTMHCCandidateGenBankArtifactURLs
    public let mhcAlignmentArtifactURLs: ONTMHCAlignmentArtifactURLs
    public let mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact?
    public let integrityWarnings: [ONTGenotypeIntegrityWarning]
    public let referenceMetadata: ONTGenotypeReferenceMetadata?
    public let provisionalExon2SequencesByGenotype: [String: ONTGenotypeProvisionalExon2Sequence]
    public let provisionalExon2ArtifactURLs: ONTGenotypeProvisionalExon2ArtifactURLs
    public let reviewableRowCatalog: GenotypeReviewableRowCatalog?

    public var alignmentArtifactURLs: ONTMHCAlignmentArtifactURLs {
        mhcAlignmentArtifactURLs
    }

    public var hasNativeGenotypeMatrixContent: Bool {
        !calls.isEmpty || reviewableRowCatalog?.rows.isEmpty == false
    }

    public init(
        bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest,
        artifacts: ONTGenotypeResultArtifacts,
        stats: ONTGenotypeRunStats,
        calls: [ONTGenotypeCall],
        samples: [ONTGenotypeSampleResult],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil
    ) {
        self.init(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: artifacts,
            stats: stats,
            calls: calls,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            mhcCandidateSequencesByStableClusterID: [:],
            mhcReferenceVisualizations: nil,
            integrityWarnings: [],
            referenceMetadata: nil
        )
    }

    public init(
        bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest,
        artifacts: ONTGenotypeResultArtifacts,
        stats: ONTGenotypeRunStats,
        calls: [ONTGenotypeCall],
        samples: [ONTGenotypeSampleResult],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        mhcCandidates: ONTMHCCandidateAllelesDocument?,
        mhcUnnameableClusters: ONTMHCUnnameableClustersDocument?,
        mhcCandidateSequencesByStableClusterID: [String: String],
        mhcCandidateGenBankArtifactURLs: ONTMHCCandidateGenBankArtifactURLs = .empty,
        mhcAlignmentArtifactURLs: ONTMHCAlignmentArtifactURLs = .empty,
        mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact? = nil,
        integrityWarnings: [ONTGenotypeIntegrityWarning],
        referenceMetadata: ONTGenotypeReferenceMetadata?
    ) {
        self.init(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: artifacts,
            stats: stats,
            calls: calls,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis,
            mhcCandidates: mhcCandidates,
            mhcUnnameableClusters: mhcUnnameableClusters,
            mhcCandidateSequencesByStableClusterID: mhcCandidateSequencesByStableClusterID,
            mhcCandidateGenBankArtifactURLs: mhcCandidateGenBankArtifactURLs,
            mhcAlignmentArtifactURLs: mhcAlignmentArtifactURLs,
            mhcReferenceVisualizations: mhcReferenceVisualizations,
            integrityWarnings: integrityWarnings,
            referenceMetadata: referenceMetadata,
            provisionalExon2SequencesByGenotype: [:],
            provisionalExon2ArtifactURLs: .empty
        )
    }

    public init(
        bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest,
        artifacts: ONTGenotypeResultArtifacts,
        stats: ONTGenotypeRunStats,
        calls: [ONTGenotypeCall],
        samples: [ONTGenotypeSampleResult],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        mhcCandidates: ONTMHCCandidateAllelesDocument?,
        mhcUnnameableClusters: ONTMHCUnnameableClustersDocument?,
        mhcCandidateSequencesByStableClusterID: [String: String],
        mhcCandidateGenBankArtifactURLs: ONTMHCCandidateGenBankArtifactURLs,
        mhcAlignmentArtifactURLs: ONTMHCAlignmentArtifactURLs,
        mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact?,
        integrityWarnings: [ONTGenotypeIntegrityWarning],
        referenceMetadata: ONTGenotypeReferenceMetadata?,
        provisionalExon2SequencesByGenotype: [String: ONTGenotypeProvisionalExon2Sequence],
        provisionalExon2ArtifactURLs: ONTGenotypeProvisionalExon2ArtifactURLs,
        reviewableRowCatalog: GenotypeReviewableRowCatalog? = nil
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.manifest = manifest
        self.artifacts = artifacts
        self.stats = stats
        let stamp = ONTGenotypeReferenceRecordLocusStamp(calls: calls, samples: samples, manifest: manifest, referenceMetadata: referenceMetadata)
        (self.calls, self.samples) = (stamp.uniqueCalls, stamp.collapsedSamples)
        self.haplotypeAnalysis = haplotypeAnalysis
        self.mhcCandidates = mhcCandidates
        self.mhcUnnameableClusters = mhcUnnameableClusters
        self.mhcCandidateSequencesByStableClusterID = mhcCandidateSequencesByStableClusterID
        self.mhcCandidateGenBankArtifactURLs = mhcCandidateGenBankArtifactURLs
        self.mhcAlignmentArtifactURLs = mhcAlignmentArtifactURLs
        self.mhcReferenceVisualizations = mhcReferenceVisualizations
        self.integrityWarnings = stamp.merging(integrityWarnings + ONTGenotypeIntegrityWarning.duplicateCallRowsCollapsed(rowCount: calls.count, uniqueCount: self.calls.count))
        self.referenceMetadata = referenceMetadata
        self.provisionalExon2SequencesByGenotype = provisionalExon2SequencesByGenotype
        self.provisionalExon2ArtifactURLs = provisionalExon2ArtifactURLs
        self.reviewableRowCatalog = reviewableRowCatalog
    }

    public init(
        bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest,
        artifacts: ONTGenotypeResultArtifacts,
        stats: ONTGenotypeRunStats,
        calls: [ONTGenotypeCall],
        samples: [ONTGenotypeSampleResult],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        mhcCandidates: ONTMHCCandidateAllelesDocument?,
        mhcUnnameableClusters: ONTMHCUnnameableClustersDocument?,
        mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact? = nil,
        integrityWarnings: [ONTGenotypeIntegrityWarning],
        referenceMetadata: ONTGenotypeReferenceMetadata?
    ) {
        self.init(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: artifacts,
            stats: stats,
            calls: calls,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis,
            mhcCandidates: mhcCandidates,
            mhcUnnameableClusters: mhcUnnameableClusters,
            mhcCandidateSequencesByStableClusterID: [:],
            mhcReferenceVisualizations: mhcReferenceVisualizations,
            integrityWarnings: integrityWarnings,
            referenceMetadata: referenceMetadata
        )
    }

    public init(
        bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest,
        artifacts: ONTGenotypeResultArtifacts,
        stats: ONTGenotypeRunStats,
        calls: [ONTGenotypeCall],
        samples: [ONTGenotypeSampleResult],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        mhcCandidates: ONTMHCCandidateAllelesDocument?,
        mhcUnnameableClusters: ONTMHCUnnameableClustersDocument?,
        integrityWarnings: [ONTGenotypeIntegrityWarning],
        referenceMetadata: ONTGenotypeReferenceMetadata?
    ) {
        self.init(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: artifacts,
            stats: stats,
            calls: calls,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis,
            mhcCandidates: mhcCandidates,
            mhcUnnameableClusters: mhcUnnameableClusters,
            mhcCandidateSequencesByStableClusterID: [:],
            mhcReferenceVisualizations: nil,
            integrityWarnings: integrityWarnings,
            referenceMetadata: referenceMetadata
        )
    }

    private enum CodingKeys: String, CodingKey {
        case bundleURL
        case manifest
        case artifacts
        case stats
        case calls
        case samples
        case haplotypeAnalysis
        case mhcCandidates
        case mhcUnnameableClusters
        case mhcCandidateSequencesByStableClusterID
        case mhcCandidateGenBankArtifactURLs
        case mhcAlignmentArtifactURLs
        case mhcReferenceVisualizations
        case integrityWarnings
        case referenceMetadata
        case provisionalExon2SequencesByGenotype
        case provisionalExon2ArtifactURLs
        case reviewableRowCatalog
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleURL: try container.decode(URL.self, forKey: .bundleURL),
            manifest: try container.decode(ONTGenotypeResultBundleManifest.self, forKey: .manifest),
            artifacts: try container.decode(ONTGenotypeResultArtifacts.self, forKey: .artifacts),
            stats: try container.decode(ONTGenotypeRunStats.self, forKey: .stats),
            calls: try container.decode([ONTGenotypeCall].self, forKey: .calls),
            samples: try container.decode([ONTGenotypeSampleResult].self, forKey: .samples),
            haplotypeAnalysis: try container.decodeIfPresent(GenotypeHaplotypeAnalysis.self, forKey: .haplotypeAnalysis),
            mhcCandidates: try container.decodeIfPresent(ONTMHCCandidateAllelesDocument.self, forKey: .mhcCandidates),
            mhcUnnameableClusters: try container.decodeIfPresent(
                ONTMHCUnnameableClustersDocument.self,
                forKey: .mhcUnnameableClusters
            ),
            mhcCandidateSequencesByStableClusterID: try container.decodeIfPresent(
                [String: String].self,
                forKey: .mhcCandidateSequencesByStableClusterID
            ) ?? [:],
            mhcCandidateGenBankArtifactURLs: try container.decodeIfPresent(
                ONTMHCCandidateGenBankArtifactURLs.self,
                forKey: .mhcCandidateGenBankArtifactURLs
            ) ?? .empty,
            mhcAlignmentArtifactURLs: try container.decodeIfPresent(
                ONTMHCAlignmentArtifactURLs.self,
                forKey: .mhcAlignmentArtifactURLs
            ) ?? .empty,
            mhcReferenceVisualizations: try container.decodeIfPresent(
                ONTMHCReferenceVisualizationArtifact.self,
                forKey: .mhcReferenceVisualizations
            ),
            integrityWarnings: try container.decodeIfPresent(
                [ONTGenotypeIntegrityWarning].self,
                forKey: .integrityWarnings
            ) ?? [],
            referenceMetadata: try container.decodeIfPresent(
                ONTGenotypeReferenceMetadata.self,
                forKey: .referenceMetadata
            ),
            provisionalExon2SequencesByGenotype: try container.decodeIfPresent(
                [String: ONTGenotypeProvisionalExon2Sequence].self,
                forKey: .provisionalExon2SequencesByGenotype
            ) ?? [:],
            provisionalExon2ArtifactURLs: try container.decodeIfPresent(
                ONTGenotypeProvisionalExon2ArtifactURLs.self,
                forKey: .provisionalExon2ArtifactURLs
            ) ?? .empty,
            reviewableRowCatalog: try container.decodeIfPresent(
                GenotypeReviewableRowCatalog.self,
                forKey: .reviewableRowCatalog
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleURL, forKey: .bundleURL)
        try container.encode(manifest, forKey: .manifest)
        try container.encode(artifacts, forKey: .artifacts)
        try container.encode(stats, forKey: .stats)
        try container.encode(calls, forKey: .calls)
        try container.encode(samples, forKey: .samples)
        try container.encodeIfPresent(haplotypeAnalysis, forKey: .haplotypeAnalysis)
        try container.encodeIfPresent(mhcCandidates, forKey: .mhcCandidates)
        try container.encodeIfPresent(mhcUnnameableClusters, forKey: .mhcUnnameableClusters)
        try container.encode(
            mhcCandidateSequencesByStableClusterID,
            forKey: .mhcCandidateSequencesByStableClusterID
        )
        try container.encode(
            mhcCandidateGenBankArtifactURLs,
            forKey: .mhcCandidateGenBankArtifactURLs
        )
        try container.encode(
            mhcAlignmentArtifactURLs,
            forKey: .mhcAlignmentArtifactURLs
        )
        try container.encodeIfPresent(mhcReferenceVisualizations, forKey: .mhcReferenceVisualizations)
        try container.encode(integrityWarnings, forKey: .integrityWarnings)
        try container.encodeIfPresent(referenceMetadata, forKey: .referenceMetadata)
        try container.encode(
            provisionalExon2SequencesByGenotype,
            forKey: .provisionalExon2SequencesByGenotype
        )
        try container.encode(provisionalExon2ArtifactURLs, forKey: .provisionalExon2ArtifactURLs)
        try container.encodeIfPresent(reviewableRowCatalog, forKey: .reviewableRowCatalog)
    }

    public var sampleCount: Int {
        samples.count
    }

    public var callCount: Int {
        calls.count
    }

    public var qcStatusCounts: [ONTGenotypeQCStatus: Int] {
        Dictionary(grouping: samples, by: \.qcStatus).mapValues(\.count)
    }

    public var sampleNames: [String] {
        samples.map(\.sample)
    }

    public var locusSummaries: [ONTGenotypeLocusSummary] {
        locusSummaries(minimumSupportPercent: 0, denominator: .viewedLocus)
    }

    public func locusSummaries(
        minimumSupportPercent: Double,
        denominator: ONTGenotypeSupportDenominator
    ) -> [ONTGenotypeLocusSummary] {
        let filteredCalls = supportFilteredCalls(
            minimumSupportPercent: minimumSupportPercent,
            denominator: denominator
        )
        return makeLocusSummaries(from: filteredCalls)
    }

    public func sameLocusCoOccurrences(
        for selectedGenotype: String,
        minimumSupportPercent: Double = 0,
        denominator: ONTGenotypeSupportDenominator = .viewedLocus
    ) -> [ONTGenotypeCoOccurrence] {
        let filteredCalls = supportFilteredCalls(
            minimumSupportPercent: minimumSupportPercent,
            denominator: denominator
        )
        guard let selectedCall = filteredCalls.first(where: { $0.genotype == selectedGenotype }) else {
            return []
        }

        let locus = selectedCall.locusGroup
        let sameLocusCalls = filteredCalls.filter { $0.locusGroup == locus }
        let samplesByGenotype = Dictionary(grouping: sameLocusCalls, by: \.genotype)
            .mapValues { Set($0.map(\.sample)) }
        guard let selectedSamples = samplesByGenotype[selectedGenotype], !selectedSamples.isEmpty else {
            return []
        }
        let backgroundSamples = Set(sameLocusCalls.map(\.sample))

        return samplesByGenotype.compactMap { genotype, candidateSamples -> ONTGenotypeCoOccurrence? in
            guard genotype != selectedGenotype, !candidateSamples.isEmpty else { return nil }
            let sharedSamples = selectedSamples.intersection(candidateSamples)
            guard !sharedSamples.isEmpty else { return nil }
            let unionSamples = selectedSamples.union(candidateSamples)
            let probabilityCandidateGivenSelected = Double(sharedSamples.count) / Double(selectedSamples.count)
            let probabilitySelectedGivenCandidate = Double(sharedSamples.count) / Double(candidateSamples.count)
            let jaccard = Double(sharedSamples.count) / Double(unionSamples.count)
            let backgroundProbability = backgroundSamples.isEmpty
                ? 0
                : Double(candidateSamples.count) / Double(backgroundSamples.count)
            let lift = backgroundProbability > 0
                ? probabilityCandidateGivenSelected / backgroundProbability
                : nil
            return ONTGenotypeCoOccurrence(
                selectedGenotype: selectedGenotype,
                candidateGenotype: genotype,
                locus: locus,
                selectedSampleCount: selectedSamples.count,
                candidateSampleCount: candidateSamples.count,
                sharedSampleCount: sharedSamples.count,
                unionSampleCount: unionSamples.count,
                probabilityCandidateGivenSelected: probabilityCandidateGivenSelected,
                probabilitySelectedGivenCandidate: probabilitySelectedGivenCandidate,
                jaccard: jaccard,
                lift: lift,
                sharedSamples: Array(sharedSamples)
            )
        }.sorted { lhs, rhs in
            if lhs.probabilityCandidateGivenSelected != rhs.probabilityCandidateGivenSelected {
                return lhs.probabilityCandidateGivenSelected > rhs.probabilityCandidateGivenSelected
            }
            if lhs.sharedSampleCount != rhs.sharedSampleCount {
                return lhs.sharedSampleCount > rhs.sharedSampleCount
            }
            if lhs.jaccard != rhs.jaccard {
                return lhs.jaccard > rhs.jaccard
            }
            return lhs.candidateGenotype.localizedStandardCompare(rhs.candidateGenotype) == .orderedAscending
        }
    }

    public func anchorSummaries(
        minimumSupportPercent: Double = 0,
        denominator: ONTGenotypeSupportDenominator = .viewedLocus
    ) -> [ONTGenotypeAnchorSummary] {
        let filteredCalls = supportFilteredCalls(
            minimumSupportPercent: minimumSupportPercent,
            denominator: denominator
        )
        var callsByAnchor: [String: [ONTGenotypeCall]] = [:]
        var sourceByAnchor: [String: ONTGenotypeAnchorSource] = [:]

        for call in filteredCalls {
            let tokens = call.haplotypeTokens
            if tokens.isEmpty {
                callsByAnchor["Unanchored", default: []].append(call)
                sourceByAnchor["Unanchored"] = .unanchored
            } else {
                for token in tokens {
                    callsByAnchor[token, default: []].append(call)
                    sourceByAnchor[token] = .labelToken
                }
            }
        }

        return callsByAnchor.map { label, callsForAnchor in
            let sharedCalls = makeLocusSummaries(from: callsForAnchor).flatMap(\.sharedCalls)
            return ONTGenotypeAnchorSummary(
                label: label,
                source: sourceByAnchor[label] ?? .unanchored,
                loci: Array(Set(callsForAnchor.map(\.locusGroup))),
                sharedCalls: sharedCalls,
                sampleSupport: aggregateSampleSupport(callsForAnchor)
            )
        }.sorted { lhs, rhs in
            Self.anchorSortKey(lhs.label) < Self.anchorSortKey(rhs.label)
        }
    }

    public func supportFraction(
        for call: ONTGenotypeCall,
        denominator: ONTGenotypeSupportDenominator
    ) -> Double? {
        let denominatorValue: Int?
        switch denominator {
        case .viewedLocus:
            denominatorValue = GenotypeLocusDenominator(result: self).total(for: call)
        case .sampleRetained:
            denominatorValue = call.sampleUniqueRetainedReads
                ?? samples.first { $0.sample == call.sample }?.passedUniqueReads
        }

        guard let denominatorValue, denominatorValue > 0 else { return nil }
        return Double(call.passedUniqueReads) / Double(denominatorValue)
    }

    public func hiddenSupportCallCount(
        minimumSupportPercent: Double,
        denominator: ONTGenotypeSupportDenominator
    ) -> Int {
        guard minimumSupportPercent > 0 else { return 0 }
        return calls.count - supportFilteredCalls(
            minimumSupportPercent: minimumSupportPercent,
            denominator: denominator
        ).count
    }

    private func supportFilteredCalls(
        minimumSupportPercent: Double,
        denominator: ONTGenotypeSupportDenominator
    ) -> [ONTGenotypeCall] {
        guard minimumSupportPercent > 0 else { return calls }
        let threshold = minimumSupportPercent / 100
        switch denominator {
        case .viewedLocus:
            let denominators = GenotypeLocusDenominator(result: self)
            return calls.filter { call in
                guard let fraction = denominators.fraction(for: call) else { return false }
                return fraction >= threshold
            }
        case .sampleRetained:
            let retainedBySample = Dictionary(uniqueKeysWithValues: samples.map {
                ($0.sample, $0.passedUniqueReads)
            })
            return calls.filter { call in
                guard let denominatorValue = call.sampleUniqueRetainedReads ?? retainedBySample[call.sample],
                      denominatorValue > 0 else {
                    return false
                }
                return Double(call.passedUniqueReads) / Double(denominatorValue) >= threshold
            }
        }
    }

    private func makeLocusSummaries(from calls: [ONTGenotypeCall]) -> [ONTGenotypeLocusSummary] {
        let callsByLocus = Dictionary(grouping: calls, by: \.locusGroup)
        return callsByLocus.map { locus, callsForLocus in
            let callsByGenotype = Dictionary(grouping: callsForLocus, by: \.genotype)
            let sharedCalls = callsByGenotype.map { genotype, genotypeCalls in
                let support = genotypeCalls.map {
                    ONTGenotypeSampleSupport(
                        sample: $0.sample,
                        passedAlignments: $0.passedAlignments,
                        passedUniqueReads: $0.passedUniqueReads,
                        sampleUniqueRetainedReads: $0.sampleUniqueRetainedReads
                    )
                }
                return ONTGenotypeSharedCall(locus: locus, genotype: genotype, sampleSupport: support)
            }
            return ONTGenotypeLocusSummary(locus: locus, sharedCalls: sharedCalls)
        }.sorted { lhs, rhs in
            let lhsOrder = Self.locusSortRank(lhs.locus)
            let rhsOrder = Self.locusSortRank(rhs.locus)
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.locus.localizedStandardCompare(rhs.locus) == .orderedAscending
        }
    }

    private func aggregateSampleSupport(_ calls: [ONTGenotypeCall]) -> [ONTGenotypeSampleSupport] {
        struct MutableSupport {
            var alignments = 0
            var uniqueReads = 0
            var retainedReads: Int?
        }
        var supportBySample: [String: MutableSupport] = [:]
        for call in calls {
            var support = supportBySample[call.sample] ?? MutableSupport()
            support.alignments += call.passedAlignments
            support.uniqueReads += call.passedUniqueReads
            support.retainedReads = call.sampleUniqueRetainedReads ?? support.retainedReads
            supportBySample[call.sample] = support
        }
        return supportBySample.map { sample, support in
            ONTGenotypeSampleSupport(
                sample: sample,
                passedAlignments: support.alignments,
                passedUniqueReads: support.uniqueReads,
                sampleUniqueRetainedReads: support.retainedReads
            )
        }
    }

    private static func anchorSortKey(_ label: String) -> (Int, Int, String) {
        if label == "Unanchored" {
            return (1, Int.max, label)
        }
        if label.hasPrefix("M"),
           let value = Int(label.dropFirst()) {
            return (0, value, label)
        }
        return (0, Int.max - 1, label)
    }

    private static func locusSortRank(_ locus: String) -> Int {
        let uppercased = locus.uppercased()
        if uppercased == "MHC-A" { return 0 }
        if uppercased == "MHC-B" { return 1 }
        if uppercased.hasPrefix("MHC-DRB") { return 2 }
        if uppercased.hasPrefix("MHC-DQA") { return 3 }
        if uppercased.hasPrefix("MHC-DQB") { return 4 }
        if uppercased.hasPrefix("MHC-DPA") { return 5 }
        if uppercased.hasPrefix("MHC-DPB") { return 6 }
        if uppercased == "MHC-F" { return 7 }
        if uppercased == "MHC-G" || uppercased == "MHC-AG" { return 8 }
        return 100
    }
}

public extension ONTGenotypeResultBundleData {
    static func annotationSidecarURL(forBundleAt bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
    }

    static func loadOrCreateAnnotationSidecar(forBundleAt bundleURL: URL) throws -> GenotypeAnnotationSidecar {
        try loadAnnotationSidecarSnapshot(forBundleAt: bundleURL).sidecar
    }

    static func loadAnnotationSidecarSnapshot(
        forBundleAt bundleURL: URL
    ) throws -> GenotypeAnnotationSidecarSnapshot {
        if let data = try readAnnotationSidecarDataIfPresent(forBundleAt: bundleURL) {
            return GenotypeAnnotationSidecarSnapshot(
                sidecar: try GenotypeAnnotationSidecar.decode(data),
                revision: annotationSidecarRevision(for: data),
                data: data
            )
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return GenotypeAnnotationSidecarSnapshot(
            sidecar: .empty(generatedAt: formatter.string(from: Date())),
            revision: .absent,
            data: nil
        )
    }

    /// Read-only counterpart of `loadOrCreateAnnotationSidecar`. Returns an
    /// empty in-memory sidecar when the file is missing; never writes. Use
    /// this for CLI inspection commands that must not touch a possibly
    /// read-only bundle directory.
    static func loadAnnotationSidecarIfPresent(forBundleAt bundleURL: URL) throws -> GenotypeAnnotationSidecar {
        if let data = try readAnnotationSidecarDataIfPresent(forBundleAt: bundleURL) {
            return try GenotypeAnnotationSidecar.decode(data)
        }
        return GenotypeAnnotationSidecar.empty(generatedAt: "")
    }

    private static func readAnnotationSidecarDataIfPresent(forBundleAt bundleURL: URL) throws -> Data? {
        try GenotypeAnnotationPublicationFileAccess.readFileIfPresent(
            named: GenotypeAnnotationSidecar.filename,
            inBundleAt: bundleURL
        )
    }

    static func writeAnnotationSidecar(
        _ sidecar: GenotypeAnnotationSidecar,
        forBundleAt bundleURL: URL
    ) throws {
        try writeAnnotationSidecar(
            sidecar,
            expectedRevision: .absent,
            forBundleAt: bundleURL
        )
    }

    static func writeAnnotationSidecar(
        _ sidecar: GenotypeAnnotationSidecar,
        expectedRevision: GenotypeAnnotationSidecarRevision,
        forBundleAt bundleURL: URL
    ) throws {
        let publicationLock = try ONTGenotypeBundlePublicationLock.acquire(
            for: bundleURL
        )
        defer { publicationLock.release() }
        try writeAnnotationSidecar(
            sidecar,
            expectedRevision: expectedRevision,
            forBundleAt: bundleURL,
            assuming: publicationLock
        )
    }

    static func writeAnnotationSidecar(
        _ sidecar: GenotypeAnnotationSidecar,
        expectedRevision: GenotypeAnnotationSidecarRevision,
        forBundleAt bundleURL: URL,
        assuming publicationLock: ONTGenotypeBundlePublicationLock,
        precommitValidation: (() throws -> Void)? = nil,
        postRenameHook: (() throws -> Void)? = nil
    ) throws {
        var sidecar = sidecar
        try sidecar.promoteToCurrentSchema()
        try publishAnnotationSidecarData(
            sidecar.encoded(),
            expectedRevision: expectedRevision,
            forBundleAt: bundleURL,
            assuming: publicationLock,
            beforeRename: nil,
            precommitValidation: precommitValidation,
            postRenameHook: postRenameHook
        )
    }

    /// Restores the exact raw bytes captured before a failed multi-artifact
    /// transaction. The expected revision must identify the currently
    /// published sidecar, so rollback cannot erase a concurrent update.
    static func restoreAnnotationSidecarData(
        _ priorData: Data?,
        expectedRevision: GenotypeAnnotationSidecarRevision,
        forBundleAt bundleURL: URL,
        assuming publicationLock: ONTGenotypeBundlePublicationLock
    ) throws {
        try publishAnnotationSidecarData(
            priorData,
            expectedRevision: expectedRevision,
            forBundleAt: bundleURL,
            assuming: publicationLock,
            beforeRename: nil,
            precommitValidation: nil,
            postRenameHook: nil
        )
    }

    internal static func restoreAnnotationSidecarData(
        _ priorData: Data?,
        expectedRevision: GenotypeAnnotationSidecarRevision,
        forBundleAt bundleURL: URL,
        assuming publicationLock: ONTGenotypeBundlePublicationLock,
        beforeRename: (() throws -> Void)?
    ) throws {
        try publishAnnotationSidecarData(
            priorData,
            expectedRevision: expectedRevision,
            forBundleAt: bundleURL,
            assuming: publicationLock,
            beforeRename: beforeRename,
            precommitValidation: nil,
            postRenameHook: nil
        )
    }

    private static func publishAnnotationSidecarData(
        _ data: Data?,
        expectedRevision: GenotypeAnnotationSidecarRevision,
        forBundleAt bundleURL: URL,
        assuming publicationLock: ONTGenotypeBundlePublicationLock,
        beforeRename: (() throws -> Void)?,
        precommitValidation: (() throws -> Void)?,
        postRenameHook: (() throws -> Void)?
    ) throws {
        let expectedLockURL = ONTGenotypeBundlePublicationLock.lockURL(
            for: bundleURL
        ).standardizedFileURL
        guard publicationLock.lockURL.standardizedFileURL == expectedLockURL else {
            throw GenotypeAnnotationSidecarPublicationError
                .mismatchedPublicationLock(
                    expectedPath: expectedLockURL.path,
                    actualPath: publicationLock.lockURL.standardizedFileURL.path
                )
        }
        let directoryFD = bundleURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryFD >= 0 else {
            throw annotationSidecarPOSIXError(
                operation: "open bundle directory without following symbolic links",
                path: bundleURL.path
            )
        }
        defer { Darwin.close(directoryFD) }

        let filename = GenotypeAnnotationSidecar.filename
        _ = try GenotypeAnnotationPublicationFileAccess.entryKind(
            named: filename,
            inBundleAt: bundleURL,
            openedBundleDirectoryFD: directoryFD
        )

        let temporaryName = data.map { _ in
            ".\(filename).\(UUID().uuidString).tmp"
        }
        var temporaryFD: Int32 = -1
        if let temporaryName, let data {
            temporaryFD = temporaryName.withCString {
                Darwin.openat(
                    directoryFD,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o644)
                )
            }
            guard temporaryFD >= 0 else {
                throw annotationSidecarPOSIXError(
                    operation: "create atomic sidecar staging file",
                    path: bundleURL.appendingPathComponent(temporaryName).path
                )
            }
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = Darwin.write(
                        temporaryFD,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw annotationSidecarPOSIXError(
                            operation: "write atomic sidecar staging file",
                            path: bundleURL
                                .appendingPathComponent(temporaryName).path
                        )
                    }
                    offset += written
                }
            }
            guard Darwin.fsync(temporaryFD) == 0 else {
                throw annotationSidecarPOSIXError(
                    operation: "synchronize atomic sidecar staging file",
                    path: bundleURL.appendingPathComponent(temporaryName).path
                )
            }
        }
        var shouldRemoveTemporary = temporaryName != nil
        defer {
            if temporaryFD >= 0 {
                Darwin.close(temporaryFD)
            }
            if shouldRemoveTemporary, let temporaryName {
                temporaryName.withCString { _ = Darwin.unlinkat(directoryFD, $0, 0) }
            }
        }

        let currentData = try GenotypeAnnotationPublicationFileAccess
            .readFileIfPresent(
                named: filename,
                inBundleAt: bundleURL,
                openedBundleDirectoryFD: directoryFD
            )
        if let currentData {
            var current = try GenotypeAnnotationSidecar.decode(currentData)
            try current.promoteToCurrentSchema()
        }
        let actualRevision = currentData.map(annotationSidecarRevision(for:))
            ?? .absent
        guard actualRevision == expectedRevision else {
            throw GenotypeAnnotationSidecarPublicationError.staleRevision(
                expected: expectedRevision,
                actual: actualRevision
            )
        }
        try beforeRename?()
        try precommitValidation?()
        if let temporaryName {
            let renameResult = temporaryName.withCString { temporaryCString in
                filename.withCString { filenameCString in
                    Darwin.renameat(
                        directoryFD,
                        temporaryCString,
                        directoryFD,
                        filenameCString
                    )
                }
            }
            guard renameResult == 0 else {
                throw annotationSidecarPOSIXError(
                    operation: "atomically publish annotation sidecar",
                    path: annotationSidecarURL(forBundleAt: bundleURL).path
                )
            }
            shouldRemoveTemporary = false
        } else {
            let unlinkResult = filename.withCString {
                Darwin.unlinkat(directoryFD, $0, 0)
            }
            guard unlinkResult == 0 else {
                throw annotationSidecarPOSIXError(
                    operation: "atomically restore absent annotation sidecar",
                    path: annotationSidecarURL(forBundleAt: bundleURL).path
                )
            }
        }
        try postRenameHook?()
        guard Darwin.fsync(directoryFD) == 0 else {
            throw annotationSidecarPOSIXError(
                operation: "synchronize annotation sidecar directory",
                path: bundleURL.path
            )
        }
    }

    private static func annotationSidecarPOSIXError(
        operation: String,
        path: String,
        code: Int32 = errno
    ) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not \(operation) at \(path): \(String(cString: Darwin.strerror(code)))",
            ]
        )
    }

    private static func annotationSidecarRevision(
        for data: Data
    ) -> GenotypeAnnotationSidecarRevision {
        .sha256(
            SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }
}
