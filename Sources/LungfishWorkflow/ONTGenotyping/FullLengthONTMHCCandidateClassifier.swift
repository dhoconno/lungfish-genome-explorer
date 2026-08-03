import Foundation
import LungfishIO

public enum FullLengthONTMHCCandidateReferenceResolution: Equatable, Sendable {
    case resolved(MHCReferenceRecord)
    case unresolvedLocus(referenceName: String, sequenceLength: Int)
    case ambiguousReferenceClass(referenceName: String, locus: String, sequenceLength: Int)

    /// Exact reference identity expected in the reciprocal BAM's RNAME field.
    /// Resolved catalog records use their FASTA sequence ID, not the biological
    /// allele label used for provisional naming and localized ranking.
    public var referenceName: String {
        switch self {
        case .resolved(let record): record.sequenceID
        case .unresolvedLocus(let referenceName, _): referenceName
        case .ambiguousReferenceClass(let referenceName, _, _): referenceName
        }
    }

    var sequenceLength: Int {
        switch self {
        case .resolved(let record): record.sequenceLength
        case .unresolvedLocus(_, let sequenceLength): sequenceLength
        case .ambiguousReferenceClass(_, _, let sequenceLength): sequenceLength
        }
    }

    var resolvedRecord: MHCReferenceRecord? {
        guard case .resolved(let record) = self else { return nil }
        return record
    }
}

public struct FullLengthONTMHCCandidateAlignment: Equatable, Sendable {
    public let reference: FullLengthONTMHCCandidateReferenceResolution
    public let cigar: String
    public let nm: Int?
    public let mappingQuality: Int
    public let alignmentScore: Int
    public let evidence: ONTMHCEvidenceLocator
    public let isReverse: Bool

    public init(
        reference: FullLengthONTMHCCandidateReferenceResolution,
        cigar: String,
        nm: Int?,
        mappingQuality: Int,
        alignmentScore: Int,
        evidence: ONTMHCEvidenceLocator,
        isReverse: Bool = false
    ) {
        self.reference = reference
        self.cigar = cigar
        self.nm = nm
        self.mappingQuality = mappingQuality
        self.alignmentScore = alignmentScore
        self.evidence = evidence
        self.isReverse = isReverse
    }
}

public struct FullLengthONTMHCCandidateCluster: Equatable, Sendable {
    public let stableClusterID: String
    public let fastaRecordID: String
    public let sequenceSHA256: String
    public let sequenceLength: Int
    public let observations: [ONTMHCCandidateObservation]
    public let alignments: [FullLengthONTMHCCandidateAlignment]

    public init(
        stableClusterID: String,
        fastaRecordID: String,
        sequenceSHA256: String,
        sequenceLength: Int,
        observations: [ONTMHCCandidateObservation],
        alignments: [FullLengthONTMHCCandidateAlignment]
    ) {
        self.stableClusterID = stableClusterID
        self.fastaRecordID = fastaRecordID
        self.sequenceSHA256 = sequenceSHA256
        self.sequenceLength = sequenceLength
        self.observations = observations
        self.alignments = alignments
    }
}

public struct FullLengthONTMHCKnownReferenceCall: Equatable, Sendable {
    public let reference: MHCReferenceRecord
    public let cigar: String
    public let nm: Int?
    public let mappingQuality: Int
    public let alignmentScore: Int
    public let comparableBases: Int
    public let matchedBases: Int
    public let insertedBases: Int
    public let deletedBases: Int
    public let nonIntronIndelBases: Int
    public let longGapBases: Int
    public let shorterCoverage: Double
    public let identity: Double
    public let evidence: ONTMHCEvidenceLocator
}

public enum FullLengthONTMHCCandidateClassificationResult: Equatable, Sendable {
    case known([FullLengthONTMHCKnownReferenceCall])
    case candidate(ONTMHCCandidateRecord)
    case unnameable(ONTMHCUnnameableRecord)

    public var candidate: ONTMHCCandidateRecord? {
        guard case .candidate(let record) = self else { return nil }
        return record
    }
}

public enum FullLengthONTMHCCandidateClassifierError: Error, LocalizedError, Equatable, Sendable {
    case invalidCluster(field: String, value: String)
    case invalidObservation(stableClusterID: String, index: Int, field: String, value: String)
    case invalidAlignment(stableClusterID: String, index: Int, field: String, value: String)
    case arithmeticOverflow(stableClusterID: String, field: String)

    public var errorDescription: String? {
        switch self {
        case .invalidCluster(let field, let value):
            return "Invalid MHC candidate cluster \(field): \(value)."
        case .invalidObservation(let stableClusterID, let index, let field, let value):
            return "Invalid observation \(index) for MHC cluster '\(stableClusterID)' (\(field)): \(value)."
        case .invalidAlignment(let stableClusterID, let index, let field, let value):
            return "Invalid alignment \(index) for MHC cluster '\(stableClusterID)' (\(field)): \(value)."
        case .arithmeticOverflow(let stableClusterID, let field):
            return "Numeric overflow while computing \(field) for MHC cluster '\(stableClusterID)'."
        }
    }
}

public struct FullLengthONTMHCCandidateClassifier: Sendable {
    public static let defaultReciprocalBAMPath = "artifacts/alignments/unmatched-to-reference.bam"

    private struct Support: Sendable {
        let supportClass: ONTMHCCandidateSupportClass
        let independentSampleCount: Int
        let occurrenceCount: Int
        let totalClusterReads: Int
        let supportingSampleIDs: [String]
    }

    private struct AnalyzedAlignment: Sendable {
        let input: FullLengthONTMHCCandidateAlignment
        let metrics: FullLengthONTMHCSAMMetrics
        let longGapBases: Int
        let nonIntronIndelBases: Int
        let shorterCoverage: Double
        let identity: Double
        let cdnaInterpretation: FullLengthONTMHCCDNAStructuralInterpretation?
        let failure: Failure?
        let failedMetrics: [String: Double]

        var resolvedReference: MHCReferenceRecord? { input.reference.resolvedRecord }
        var localizedReferenceName: String {
            resolvedReference?.alleleName ?? input.reference.referenceName
        }
    }

    private enum Failure: Sendable {
        case insufficientAlignedBases
        case insufficientCoverage
        case insufficientIdentity
        case unresolvedLocus
        case ambiguousReferenceClass

        var reason: ONTMHCUnnameableReason {
            switch self {
            case .insufficientAlignedBases: .insufficientAlignedBases
            case .insufficientCoverage: .insufficientCoverage
            case .insufficientIdentity: .insufficientIdentity
            case .unresolvedLocus: .unresolvedLocus
            case .ambiguousReferenceClass: .ambiguousReferenceClass
            }
        }

    }

    public let thresholds: ONTMHCCandidateThresholds
    public let reciprocalBAMPath: String

    public init(
        thresholds: ONTMHCCandidateThresholds = .defaults,
        reciprocalBAMPath: String = Self.defaultReciprocalBAMPath
    ) {
        self.thresholds = thresholds
        self.reciprocalBAMPath = reciprocalBAMPath
    }

    public func classify(
        _ clusters: [FullLengthONTMHCCandidateCluster]
    ) throws -> [FullLengthONTMHCCandidateClassificationResult] {
        var seenStableIDs = Set<String>()
        for cluster in clusters {
            guard seenStableIDs.insert(cluster.stableClusterID).inserted else {
                throw FullLengthONTMHCCandidateClassifierError.invalidCluster(
                    field: "stableClusterID",
                    value: "duplicate '\(cluster.stableClusterID)'"
                )
            }
        }
        return try clusters
            .sorted { localizedStandardLessThan($0.stableClusterID, $1.stableClusterID) }
            .map(classify)
    }

    public func classify(
        _ cluster: FullLengthONTMHCCandidateCluster
    ) throws -> FullLengthONTMHCCandidateClassificationResult {
        let support = try validateClusterAndResolveSupport(cluster)
        let analyzed = try cluster.alignments.enumerated().map { index, alignment in
            try analyze(alignment, index: index, cluster: cluster)
        }
        guard !analyzed.isEmpty else {
            return .unnameable(try unnameableRecord(
                cluster: cluster,
                support: support,
                reason: .noAlignment,
                failedMetrics: [:],
                analyzed: [],
                selectedHit: nil
            ))
        }

        let eligible = analyzed.filter { $0.failure == nil }

        let eligibleZeroSNPGenomic = eligible.filter {
            $0.metrics.snps == 0 && $0.resolvedReference?.moleculeClass == .genomicDNA
        }
        let zeroSNPGenomic = bestTies(eligibleZeroSNPGenomic)
        let exactZeroSNPGenomic = bestTies(eligibleZeroSNPGenomic.filter {
            isExactEndToEndGenomicMatch($0, clusterLength: cluster.sequenceLength)
        })
        let partialZeroSNPGenomic = bestTies(eligibleZeroSNPGenomic.filter {
            isPartialEndCoverageGenomicMatch($0, clusterLength: cluster.sequenceLength)
        })
        if !exactZeroSNPGenomic.isEmpty {
            return .known(knownCalls(exactZeroSNPGenomic))
        }

        let rawExtensionHits = eligible.filter {
            $0.cdnaInterpretation?.relationship == .extension
        }
        let rawCohortExtensionGroups = Dictionary(grouping: cluster.observations.flatMap {
            $0.genotypingHitSummaries.flatMap(\.cdnaExtensionInterpretations)
        }, by: \.rawReferenceID)
        let cohortExtensions = rawCohortExtensionGroups.values.compactMap { values in
            values.min(by: isCohortInterpretationRankedBefore)
        }
        let extensionGroups = Dictionary(grouping: rawExtensionHits) {
            $0.resolvedReference?.sequenceID ?? $0.input.reference.referenceName
        }
        let withinReferenceReciprocalStrandConflict = extensionGroups.values.contains { group in
            guard let first = best(group) else { return false }
            return Set(group.filter { hasEquivalentBiologicalRank($0, first) }.map(\.input.isReverse)).count > 1
        }
        let extensionHits = extensionGroups.values.compactMap { best($0) }.sorted(by: isRankedBefore)
        let acrossReferenceReciprocalStrandConflict: Bool
        if let first = best(extensionHits) {
            acrossReferenceReciprocalStrandConflict = Set(
                extensionHits.filter { hasEquivalentBiologicalRank($0, first) }.map(\.input.isReverse)
            ).count > 1
        } else {
            acrossReferenceReciprocalStrandConflict = false
        }
        let withinReferenceCohortStrandConflict = rawCohortExtensionGroups.values.contains { group in
            guard let first = group.min(by: isCohortInterpretationRankedBefore) else { return false }
            return Set(group.filter {
                hasEquivalentCohortInterpretationRank($0, first)
            }.map(\.isReverse)).count > 1
        }
        let acrossReferenceCohortStrandConflict: Bool
        if let first = cohortExtensions.min(by: isCohortInterpretationRankedBefore) {
            acrossReferenceCohortStrandConflict = Set(
                cohortExtensions.filter {
                    hasEquivalentCohortInterpretationRank($0, first)
                }.map(\.isReverse)
            ).count > 1
        } else {
            acrossReferenceCohortStrandConflict = false
        }
        let reciprocalInterpretations = extensionHits.compactMap(extensionInterpretation)
        let combinedReferenceStrandConflict = Dictionary(
            grouping: cohortExtensions + reciprocalInterpretations,
            by: \.rawReferenceID
        ).values.contains { Set($0.map(\.isReverse)).count > 1 }
        if withinReferenceReciprocalStrandConflict
            || acrossReferenceReciprocalStrandConflict
            || withinReferenceCohortStrandConflict
            || acrossReferenceCohortStrandConflict
            || combinedReferenceStrandConflict {
            let closest = best(rawExtensionHits)
            return .unnameable(try unnameableRecord(
                cluster: cluster,
                support: support,
                reason: .ambiguousReferenceClass,
                failedMetrics: ["conflicting_cdna_strand": 1],
                analyzed: analyzed,
                selectedHit: closest
            ))
        }
        let interpretationByRawID = Dictionary(
            (cohortExtensions + reciprocalInterpretations).map { ($0.rawReferenceID, $0) },
            uniquingKeysWith: { cohort, _ in cohort }
        )
        let allExtensionInterpretations = interpretationByRawID.values.sorted {
            localizedStandardLessThan($0.rawReferenceID, $1.rawReferenceID)
        }
        if !allExtensionInterpretations.isEmpty {
            let eligibleGenomic = eligible.filter {
                $0.resolvedReference?.moleculeClass == .genomicDNA
            }
            let bestGenomicTies = bestTies(eligibleGenomic)
            let genomicLoci = Set(bestGenomicTies.compactMap { $0.resolvedReference?.locus })
            let cDNALoci = Set(allExtensionInterpretations.map(\.locus))
            if genomicLoci.isEmpty, cDNALoci.count > 1 {
                return .unnameable(try unnameableRecord(
                    cluster: cluster,
                    support: support,
                    reason: .unresolvedLocus,
                    failedMetrics: ["ambiguous_compatible_cdna_locus": 1],
                    analyzed: analyzed,
                    selectedHit: best(extensionHits) ?? best(eligible)
                ))
            }
            let resolvedGenomicLocus: String?
            if genomicLoci.count == 1 {
                resolvedGenomicLocus = genomicLoci.first
            } else if genomicLoci.count > 1,
                      cDNALoci.count == 1,
                      let unanimousCDNALocus = cDNALoci.first,
                      genomicLoci.contains(unanimousCDNALocus) {
                resolvedGenomicLocus = unanimousCDNALocus
            } else if genomicLoci.count > 1 {
                return .unnameable(try unnameableRecord(
                    cluster: cluster,
                    support: support,
                    reason: .unresolvedLocus,
                    failedMetrics: ["ambiguous_best_genomic_locus": 1],
                    analyzed: analyzed,
                    selectedHit: best(eligible)
                ))
            } else {
                resolvedGenomicLocus = nil
            }
            let comparisonHit = resolvedGenomicLocus.flatMap { locus in
                best(eligibleGenomic.filter { $0.resolvedReference?.locus == locus })
            } ?? best(extensionHits) ?? best(eligible)
            guard let comparisonHit else {
                return .unnameable(try unnameableRecord(
                    cluster: cluster,
                    support: support,
                    reason: .unresolvedLocus,
                    failedMetrics: ["missing_reciprocal_comparison": 1],
                    analyzed: analyzed,
                    selectedHit: nil
                ))
            }
            let allExtensionNames = Set(allExtensionInterpretations.map(\.alleleName))
                .sorted(by: localizedStandardLessThan)
            let namingExtensions = allExtensionInterpretations.filter {
                $0.locus == comparisonHit.resolvedReference!.locus
            }
            let namingExtensionNames = Set(namingExtensions.map(\.alleleName))
                .sorted(by: localizedStandardLessThan)
            let namingAlleleName = namingExtensionNames.count == 1
                ? namingExtensionNames[0]
                : comparisonHit.resolvedReference!.alleleName
            let classification: ONTMHCCandidateClassification = zeroSNPGenomic.isEmpty
                ? .extension
                : .partialExtension
            return .candidate(try candidateRecord(
                cluster: cluster,
                support: support,
                hit: comparisonHit,
                namingAlleleName: namingAlleleName,
                analyzed: analyzed,
                closestHits: eligibleGenomic.isEmpty ? (extensionHits.isEmpty ? [comparisonHit] : extensionHits) : eligibleGenomic,
                classification: classification,
                extensionOf: allExtensionNames,
                extensionInterpretations: allExtensionInterpretations,
                provisionalNamingAmbiguous: namingExtensionNames.count != 1
            ))
        }

        if !zeroSNPGenomic.isEmpty {
            if let partial = best(partialZeroSNPGenomic) {
                let partialLoci = Set(partialZeroSNPGenomic.compactMap { $0.resolvedReference?.locus })
                if partialLoci.count > 1 {
                    return .unnameable(try unnameableRecord(
                        cluster: cluster,
                        support: support,
                        reason: .unresolvedLocus,
                        failedMetrics: ["ambiguous_partial_extension_locus": 1],
                        analyzed: analyzed,
                        selectedHit: partial
                    ))
                }
                let extensionNames = Set(partialZeroSNPGenomic.compactMap {
                    $0.resolvedReference?.alleleName
                }).sorted(by: localizedStandardLessThan)
                return .candidate(try candidateRecord(
                    cluster: cluster,
                    support: support,
                    hit: partial,
                    namingAlleleName: extensionNames.count == 1
                        ? extensionNames[0]
                        : partial.resolvedReference!.alleleName,
                    analyzed: analyzed,
                    closestHits: eligibleZeroSNPGenomic,
                    classification: .partialExtension,
                    extensionOf: extensionNames,
                    extensionInterpretations: [],
                    provisionalNamingAmbiguous: extensionNames.count != 1
                ))
            }
            return .known(knownCalls(zeroSNPGenomic))
        }

        // Exact cDNA matches and zero-SNP indel-only relationships that do not
        // meet the stricter extension rule remain genotypes of the existing allele.
        let knownZeroSNP = bestTies(eligible.filter {
            if $0.resolvedReference?.moleculeClass == .cDNA {
                return $0.cdnaInterpretation?.relationship == .known
            }
            return $0.metrics.snps == 0
        })
        if !knownZeroSNP.isEmpty {
            return .known(knownCalls(knownZeroSNP))
        }

        let eligibleNovel = eligible.filter { $0.metrics.snps > 0 }
        let bestNovelTies = bestTies(eligibleNovel)
        let bestNovelGenomicLoci = Set(bestNovelTies.compactMap { hit in
            hit.resolvedReference?.moleculeClass == .genomicDNA ? hit.resolvedReference?.locus : nil
        })
        if bestNovelGenomicLoci.count > 1 {
            return .unnameable(try unnameableRecord(
                cluster: cluster,
                support: support,
                reason: .unresolvedLocus,
                failedMetrics: ["ambiguous_best_genomic_locus": 1],
                analyzed: analyzed,
                selectedHit: best(bestNovelTies)
            ))
        }
        if let novel = best(eligibleNovel) {
            return .candidate(try candidateRecord(
                cluster: cluster,
                support: support,
                hit: novel,
                namingAlleleName: novel.resolvedReference!.alleleName,
                analyzed: analyzed,
                closestHits: eligibleNovel,
                classification: .novel,
                extensionOf: [],
                extensionInterpretations: [],
                provisionalNamingAmbiguous: false
            ))
        }

        let closest = best(analyzed)!
        let failure = closest.failure ?? .unresolvedLocus
        return .unnameable(try unnameableRecord(
            cluster: cluster,
            support: support,
            reason: failure.reason,
            failedMetrics: closest.failedMetrics,
            analyzed: analyzed,
            selectedHit: closest
        ))
    }

    private func validateClusterAndResolveSupport(
        _ cluster: FullLengthONTMHCCandidateCluster
    ) throws -> Support {
        guard !cluster.stableClusterID.isEmpty else {
            throw FullLengthONTMHCCandidateClassifierError.invalidCluster(field: "stableClusterID", value: "empty")
        }
        guard !cluster.fastaRecordID.isEmpty else {
            throw FullLengthONTMHCCandidateClassifierError.invalidCluster(field: "fastaRecordID", value: "empty")
        }
        guard !cluster.sequenceSHA256.isEmpty else {
            throw FullLengthONTMHCCandidateClassifierError.invalidCluster(field: "sequenceSHA256", value: "empty")
        }
        guard cluster.sequenceLength > 0 else {
            throw FullLengthONTMHCCandidateClassifierError.invalidCluster(
                field: "sequenceLength",
                value: String(cluster.sequenceLength)
            )
        }
        guard !cluster.observations.isEmpty else {
            throw FullLengthONTMHCCandidateClassifierError.invalidCluster(field: "observations", value: "empty")
        }

        var sampleIDs = Set<String>()
        var totalClusterReads = 0
        var occurrenceCount = 0
        for (index, observation) in cluster.observations.enumerated() {
            guard observation.stableClusterID == cluster.stableClusterID else {
                throw invalidObservation(cluster, index, "stableClusterID", observation.stableClusterID)
            }
            guard !observation.sampleID.isEmpty else {
                throw invalidObservation(cluster, index, "sampleID", "empty")
            }
            guard !observation.readGroupID.isEmpty else {
                throw invalidObservation(cluster, index, "readGroupID", "empty")
            }
            guard observation.aggregatedSampleReadCount > 0 else {
                throw invalidObservation(
                    cluster,
                    index,
                    "aggregatedSampleReadCount",
                    String(observation.aggregatedSampleReadCount)
                )
            }
            guard !observation.sourceClusterIDs.isEmpty,
                  observation.sourceClusterIDs.allSatisfy({ !$0.isEmpty }),
                  Set(observation.sourceClusterIDs).count == observation.sourceClusterIDs.count else {
                throw invalidObservation(cluster, index, "sourceClusterIDs", "empty or duplicate source ID")
            }
            guard Set(observation.sourceClusterReadCounts.keys) == Set(observation.sourceClusterIDs),
                  observation.sourceClusterReadCounts.values.allSatisfy({ $0 > 0 }) else {
                throw invalidObservation(
                    cluster,
                    index,
                    "sourceClusterReadCounts",
                    "keys differ from sourceClusterIDs or a count is not positive"
                )
            }
            var sourceReadTotal = 0
            for readCount in observation.sourceClusterReadCounts.values {
                let sum = sourceReadTotal.addingReportingOverflow(readCount)
                guard !sum.overflow else {
                    throw FullLengthONTMHCCandidateClassifierError.arithmeticOverflow(
                        stableClusterID: cluster.stableClusterID,
                        field: "sourceClusterReadCounts"
                    )
                }
                sourceReadTotal = sum.partialValue
            }
            guard sourceReadTotal == observation.aggregatedSampleReadCount else {
                throw invalidObservation(
                    cluster,
                    index,
                    "aggregatedSampleReadCount",
                    "\(observation.aggregatedSampleReadCount) does not equal source total \(sourceReadTotal)"
                )
            }
            for locator in observation.evidence {
                try validate(locator: locator, cluster: cluster, observationIndex: index)
            }
            let summaryTargetNames = observation.genotypingHitSummaries.map(\.targetName)
            let expectedTargetNames = Set(observation.sourceClusterIDs.map {
                "\(observation.sampleID)|\($0)"
            })
            guard Set(summaryTargetNames).count == summaryTargetNames.count,
                  Set(summaryTargetNames).isSubset(of: expectedTargetNames) else {
                throw invalidObservation(
                    cluster,
                    index,
                    "genotypingHitSummaries.targetName",
                    "duplicate target or target outside the observation sample/source clusters"
                )
            }
            let sum = totalClusterReads.addingReportingOverflow(observation.aggregatedSampleReadCount)
            guard !sum.overflow else {
                throw FullLengthONTMHCCandidateClassifierError.arithmeticOverflow(
                    stableClusterID: cluster.stableClusterID,
                    field: "totalClusterReads"
                )
            }
            totalClusterReads = sum.partialValue
            let occurrenceSum = occurrenceCount.addingReportingOverflow(observation.sourceClusterIDs.count)
            guard !occurrenceSum.overflow else {
                throw FullLengthONTMHCCandidateClassifierError.arithmeticOverflow(
                    stableClusterID: cluster.stableClusterID,
                    field: "occurrenceCount"
                )
            }
            occurrenceCount = occurrenceSum.partialValue
            sampleIDs.insert(observation.sampleID)
        }

        let sortedSampleIDs = sampleIDs.sorted(by: localizedStandardLessThan)
        return Support(
            supportClass: sortedSampleIDs.count >= 2 ? .shared : .singleton,
            independentSampleCount: sortedSampleIDs.count,
            occurrenceCount: occurrenceCount,
            totalClusterReads: totalClusterReads,
            supportingSampleIDs: sortedSampleIDs
        )
    }

    private func analyze(
        _ alignment: FullLengthONTMHCCandidateAlignment,
        index: Int,
        cluster: FullLengthONTMHCCandidateCluster
    ) throws -> AnalyzedAlignment {
        guard alignment.reference.sequenceLength > 0 else {
            throw invalidAlignment(cluster, index, "reference.sequenceLength", String(alignment.reference.sequenceLength))
        }
        guard (0 ... 255).contains(alignment.mappingQuality) else {
            throw invalidAlignment(cluster, index, "mappingQuality", String(alignment.mappingQuality))
        }
        guard alignment.nm.map({ $0 >= 0 }) ?? true else {
            throw invalidAlignment(cluster, index, "nm", String(alignment.nm!))
        }
        try validate(locator: alignment.evidence, cluster: cluster, alignmentIndex: index)
        guard alignment.evidence.cigar == alignment.cigar else {
            throw invalidAlignment(cluster, index, "evidence.cigar", alignment.evidence.cigar)
        }
        guard alignment.evidence.queryName == cluster.stableClusterID else {
            throw invalidAlignment(cluster, index, "evidence.queryName", alignment.evidence.queryName)
        }
        guard alignment.evidence.referenceName == alignment.reference.referenceName else {
            throw invalidAlignment(cluster, index, "evidence.referenceName", alignment.evidence.referenceName)
        }
        guard alignment.evidence.bamPath == reciprocalBAMPath else {
            throw invalidAlignment(cluster, index, "evidence.bamPath", alignment.evidence.bamPath)
        }

        let metrics: FullLengthONTMHCSAMMetrics
        do {
            metrics = try FullLengthONTMHCSAMMetrics(cigar: alignment.cigar, nm: alignment.nm)
        } catch {
            throw invalidAlignment(cluster, index, "cigar", "\(alignment.cigar): \(error)")
        }
        guard metrics.comparableBases > 0 else {
            throw invalidAlignment(cluster, index, "comparableBases", "0")
        }
        guard metrics.querySpan <= cluster.sequenceLength else {
            throw invalidAlignment(cluster, index, "querySpan", String(metrics.querySpan))
        }
        let zeroBasedStart = alignment.evidence.referenceStart - 1
        let referenceEnd = zeroBasedStart.addingReportingOverflow(metrics.referenceSpan)
        guard !referenceEnd.overflow, referenceEnd.partialValue <= alignment.reference.sequenceLength else {
            throw invalidAlignment(cluster, index, "referenceSpan", String(metrics.referenceSpan))
        }

        let longGapBases = try intronSizedQueryInsertionBases(
            cigar: alignment.cigar,
            minimumLength: thresholds.minimumIntronGapBases,
            cluster: cluster,
            alignmentIndex: index
        )
        let allIndels = metrics.insertedBases.addingReportingOverflow(metrics.deletedBases)
        guard !allIndels.overflow else {
            throw FullLengthONTMHCCandidateClassifierError.arithmeticOverflow(
                stableClusterID: cluster.stableClusterID,
                field: "nonIntronIndelBases"
            )
        }
        let nonIntronIndelBases = allIndels.partialValue.subtractingReportingOverflow(longGapBases)
        guard !nonIntronIndelBases.overflow, nonIntronIndelBases.partialValue >= 0 else {
            throw invalidAlignment(cluster, index, "longGapBases", String(longGapBases))
        }

        let shorterLength = min(cluster.sequenceLength, alignment.reference.sequenceLength)
        let shorterCoverage = Double(metrics.comparableBases) / Double(shorterLength)
        let identity = Double(metrics.matches) / Double(metrics.comparableBases)
        guard shorterCoverage.isFinite, identity.isFinite else {
            throw invalidAlignment(cluster, index, "derivedMetrics", "non-finite")
        }

        var failedMetrics: [String: Double] = [:]
        if metrics.comparableBases < thresholds.minimumAlignedBases {
            failedMetrics["aligned_bases"] = Double(metrics.comparableBases)
            failedMetrics["minimum_aligned_bases"] = Double(thresholds.minimumAlignedBases)
        }
        if shorterCoverage < thresholds.minimumShorterCoverage {
            failedMetrics["shorter_coverage"] = shorterCoverage
            failedMetrics["minimum_shorter_coverage"] = thresholds.minimumShorterCoverage
        }
        if identity < thresholds.minimumIdentity {
            failedMetrics["identity"] = identity
            failedMetrics["minimum_identity"] = thresholds.minimumIdentity
        }

        let failure: Failure?
        if metrics.comparableBases < thresholds.minimumAlignedBases {
            failure = .insufficientAlignedBases
        } else if shorterCoverage < thresholds.minimumShorterCoverage {
            failure = .insufficientCoverage
        } else if identity < thresholds.minimumIdentity {
            failure = .insufficientIdentity
        } else {
            switch alignment.reference {
            case .resolved(let record) where record.locus.isEmpty || record.alleleName.isEmpty:
                failure = .unresolvedLocus
            case .resolved:
                failure = nil
            case .unresolvedLocus:
                failure = .unresolvedLocus
            case .ambiguousReferenceClass:
                failure = .ambiguousReferenceClass
            }
        }

        let cdnaInterpretation: FullLengthONTMHCCDNAStructuralInterpretation?
        if let reference = alignment.reference.resolvedRecord,
           reference.moleculeClass == .cDNA {
            cdnaInterpretation = try FullLengthONTMHCCDNAStructuralClassifier.classifyReciprocal(
                referenceSequenceID: reference.sequenceID,
                clusterID: cluster.stableClusterID,
                cDNAReferenceLength: reference.sequenceLength,
                clusterLength: cluster.sequenceLength,
                referenceStart: alignment.evidence.referenceStart,
                isReverse: alignment.isReverse,
                metrics: metrics
            )
        } else {
            cdnaInterpretation = nil
        }

        return AnalyzedAlignment(
            input: alignment,
            metrics: metrics,
            longGapBases: longGapBases,
            nonIntronIndelBases: nonIntronIndelBases.partialValue,
            shorterCoverage: shorterCoverage,
            identity: identity,
            cdnaInterpretation: cdnaInterpretation,
            failure: failure,
            failedMetrics: failedMetrics
        )
    }

    private func best(_ hits: [AnalyzedAlignment]) -> AnalyzedAlignment? {
        hits.min(by: isRankedBefore)
    }

    private func bestTies(_ hits: [AnalyzedAlignment]) -> [AnalyzedAlignment] {
        guard let bestHit = best(hits) else { return [] }
        let equallyBest = hits.filter { hasEquivalentBiologicalRank($0, bestHit) }
        var seenReferenceIDs = Set<String>()
        return equallyBest.sorted(by: isRankedBefore).filter { hit in
            guard let referenceID = hit.resolvedReference?.sequenceID else { return false }
            return seenReferenceIDs.insert(referenceID).inserted
        }
    }

    private func hasEquivalentBiologicalRank(
        _ lhs: AnalyzedAlignment,
        _ rhs: AnalyzedAlignment
    ) -> Bool {
        lhs.metrics.snps == rhs.metrics.snps
            && lhs.metrics.comparableBases == rhs.metrics.comparableBases
            && lhs.input.alignmentScore == rhs.input.alignmentScore
    }

    private func knownCalls(
        _ hits: [AnalyzedAlignment]
    ) -> [FullLengthONTMHCKnownReferenceCall] {
        hits.compactMap { hit in
            guard let reference = hit.resolvedReference else { return nil }
            return FullLengthONTMHCKnownReferenceCall(
                reference: reference,
                cigar: hit.input.cigar,
                nm: hit.input.nm,
                mappingQuality: hit.input.mappingQuality,
                alignmentScore: hit.input.alignmentScore,
                comparableBases: hit.metrics.comparableBases,
                matchedBases: hit.metrics.matches,
                insertedBases: hit.metrics.insertedBases,
                deletedBases: hit.metrics.deletedBases,
                nonIntronIndelBases: hit.nonIntronIndelBases,
                longGapBases: hit.longGapBases,
                shorterCoverage: hit.shorterCoverage,
                identity: hit.identity,
                evidence: hit.input.evidence
            )
        }.sorted {
            if $0.reference.alleleName != $1.reference.alleleName {
                return localizedStandardLessThan($0.reference.alleleName, $1.reference.alleleName)
            }
            return localizedStandardLessThan($0.reference.sequenceID, $1.reference.sequenceID)
        }
    }

    private func isRankedBefore(_ lhs: AnalyzedAlignment, _ rhs: AnalyzedAlignment) -> Bool {
        if lhs.metrics.snps != rhs.metrics.snps { return lhs.metrics.snps < rhs.metrics.snps }
        if lhs.metrics.comparableBases != rhs.metrics.comparableBases {
            return lhs.metrics.comparableBases > rhs.metrics.comparableBases
        }
        if lhs.input.alignmentScore != rhs.input.alignmentScore {
            return lhs.input.alignmentScore > rhs.input.alignmentScore
        }
        let nameOrder = lhs.localizedReferenceName.localizedStandardCompare(rhs.localizedReferenceName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.input.evidence.referenceName != rhs.input.evidence.referenceName {
            return localizedStandardLessThan(lhs.input.evidence.referenceName, rhs.input.evidence.referenceName)
        }
        if lhs.input.evidence.referenceStart != rhs.input.evidence.referenceStart {
            return lhs.input.evidence.referenceStart < rhs.input.evidence.referenceStart
        }
        return lhs.input.cigar < rhs.input.cigar
    }

    private func candidateRecord(
        cluster: FullLengthONTMHCCandidateCluster,
        support: Support,
        hit: AnalyzedAlignment,
        namingAlleleName: String,
        analyzed: [AnalyzedAlignment],
        closestHits: [AnalyzedAlignment],
        classification: ONTMHCCandidateClassification,
        extensionOf: [String],
        extensionInterpretations: [ONTMHCCDNAExtensionInterpretation],
        provisionalNamingAmbiguous: Bool
    ) throws -> ONTMHCCandidateRecord {
        let reference = hit.resolvedReference!
        let provisionalName: String
        switch classification {
        case .extension:
            provisionalName = "\(namingAlleleName)_ext"
        case .partialExtension:
            provisionalName = "\(namingAlleleName)_partial_ext"
        case .novel:
            precondition(hit.metrics.snps > 0, "Novel candidates must contain at least one SNP substitution")
            provisionalName = "\(reference.alleleName)_\(hit.metrics.snps)nt_nov"
        }
        let reciprocalHitSummary = try reciprocalHitSummary(
            cluster: cluster,
            analyzed: analyzed,
            closestHits: closestHits
        )
        guard reciprocalHitSummary.closestMatchTargetNames.contains(hit.input.evidence.referenceName) else {
            throw FullLengthONTMHCCandidateClassifierError.invalidCluster(
                field: "selectedEvidence.referenceName",
                value: hit.input.evidence.referenceName
            )
        }
        return ONTMHCCandidateRecord(
            stableClusterID: cluster.stableClusterID,
            provisionalName: provisionalName,
            locus: reference.locus,
            classification: classification,
            supportClass: support.supportClass,
            closestReferenceName: reference.alleleName,
            closestReferenceClass: reference.moleculeClass,
            snpCount: hit.metrics.snps,
            insertedBases: hit.metrics.insertedBases,
            deletedBases: hit.metrics.deletedBases,
            longGapBases: hit.longGapBases,
            comparableBases: hit.metrics.comparableBases,
            shorterCoverage: hit.shorterCoverage,
            identity: hit.identity,
            mappingQuality: hit.input.mappingQuality,
            alignmentScore: hit.input.alignmentScore,
            independentSampleCount: support.independentSampleCount,
            occurrenceCount: support.occurrenceCount,
            totalClusterReads: support.totalClusterReads,
            supportingSampleIDs: support.supportingSampleIDs,
            fastaRecordID: cluster.fastaRecordID,
            sequenceSHA256: cluster.sequenceSHA256,
            reciprocalHitSummary: reciprocalHitSummary,
            selectedEvidence: hit.input.evidence,
            selectedAlignmentIsReverse: hit.input.isReverse,
            extensionOf: extensionOf,
            extensionInterpretations: extensionInterpretations,
            provisionalNamingAmbiguous: provisionalNamingAmbiguous
        )
    }

    private func isExactEndToEndGenomicMatch(
        _ hit: AnalyzedAlignment,
        clusterLength: Int
    ) -> Bool {
        guard let reference = hit.resolvedReference,
              reference.moleculeClass == .genomicDNA else {
            return false
        }
        return hit.metrics.snps == 0
            && hit.input.evidence.referenceStart == 1
            && hit.metrics.referenceSpan == reference.sequenceLength
            && hit.metrics.querySpan == clusterLength
            && hit.metrics.insertedBases == 0
            && hit.metrics.deletedBases == 0
            && hit.metrics.skippedReferenceBases == 0
            && hit.metrics.softClippedBases == 0
            && hit.metrics.hardClippedBases == 0
    }

    private func isPartialEndCoverageGenomicMatch(
        _ hit: AnalyzedAlignment,
        clusterLength: Int
    ) -> Bool {
        guard let reference = hit.resolvedReference,
              reference.moleculeClass == .genomicDNA,
              hit.metrics.snps == 0,
              hit.metrics.insertedBases == 0,
              hit.metrics.deletedBases == 0,
              hit.metrics.skippedReferenceBases == 0 else {
            return false
        }
        return !isExactEndToEndGenomicMatch(hit, clusterLength: clusterLength)
    }

    private func extensionInterpretation(
        _ hit: AnalyzedAlignment
    ) -> ONTMHCCDNAExtensionInterpretation? {
        guard let structural = hit.cdnaInterpretation,
              let reference = hit.resolvedReference else { return nil }
        return ONTMHCCDNAExtensionInterpretation(
            rawReferenceID: reference.sequenceID,
            alleleName: reference.alleleName,
            locus: reference.locus,
            cDNAReferenceCoverage: structural.cDNAReferenceCoverage,
            clusterCoverage: structural.clusterCoverage,
            leadingClusterFlankBases: structural.leadingClusterFlankBases,
            trailingClusterFlankBases: structural.trailingClusterFlankBases,
            largestClusterStructuralSegmentBases: structural.largestClusterStructuralSegmentBases,
            largestCDNADeficitSegmentBases: structural.largestCDNADeficitSegmentBases,
            snpSubstitutions: structural.snpSubstitutions,
            ordinaryIndelBases: structural.ordinaryIndelBases,
            isReverse: structural.isReverse,
            alignmentScore: hit.input.alignmentScore,
            identity: hit.identity
        )
    }

    private func isCohortInterpretationRankedBefore(
        _ lhs: ONTMHCCDNAExtensionInterpretation,
        _ rhs: ONTMHCCDNAExtensionInterpretation
    ) -> Bool {
        if lhs.cDNAReferenceCoverage != rhs.cDNAReferenceCoverage {
            return lhs.cDNAReferenceCoverage > rhs.cDNAReferenceCoverage
        }
        if lhs.clusterCoverage != rhs.clusterCoverage {
            return lhs.clusterCoverage > rhs.clusterCoverage
        }
        if lhs.alignmentScore != rhs.alignmentScore {
            return lhs.alignmentScore > rhs.alignmentScore
        }
        if lhs.rawReferenceID != rhs.rawReferenceID {
            return localizedStandardLessThan(lhs.rawReferenceID, rhs.rawReferenceID)
        }
        return !lhs.isReverse && rhs.isReverse
    }

    private func hasEquivalentCohortInterpretationRank(
        _ lhs: ONTMHCCDNAExtensionInterpretation,
        _ rhs: ONTMHCCDNAExtensionInterpretation
    ) -> Bool {
        lhs.cDNAReferenceCoverage == rhs.cDNAReferenceCoverage
            && lhs.clusterCoverage == rhs.clusterCoverage
            && lhs.alignmentScore == rhs.alignmentScore
    }

    private func unnameableRecord(
        cluster: FullLengthONTMHCCandidateCluster,
        support: Support,
        reason: ONTMHCUnnameableReason,
        failedMetrics: [String: Double],
        analyzed: [AnalyzedAlignment],
        selectedHit: AnalyzedAlignment?
    ) throws -> ONTMHCUnnameableRecord {
        let reciprocalHitSummary = try reciprocalHitSummary(
            cluster: cluster,
            analyzed: analyzed,
            closestHits: selectedHit == nil ? [] : analyzed
        )
        if let selectedHit,
           !reciprocalHitSummary.closestMatchTargetNames.contains(selectedHit.input.evidence.referenceName) {
            throw FullLengthONTMHCCandidateClassifierError.invalidCluster(
                field: "selectedEvidence.referenceName",
                value: selectedHit.input.evidence.referenceName
            )
        }
        return ONTMHCUnnameableRecord(
            stableClusterID: cluster.stableClusterID,
            reason: reason,
            failedMetrics: failedMetrics,
            supportClass: support.supportClass,
            independentSampleCount: support.independentSampleCount,
            occurrenceCount: support.occurrenceCount,
            totalClusterReads: support.totalClusterReads,
            supportingSampleIDs: support.supportingSampleIDs,
            fastaRecordID: cluster.fastaRecordID,
            sequenceSHA256: cluster.sequenceSHA256,
            reciprocalHitSummary: reciprocalHitSummary,
            selectedEvidence: selectedHit?.input.evidence,
            selectedAlignmentIsReverse: selectedHit?.input.isReverse
        )
    }

    private func reciprocalHitSummary(
        cluster: FullLengthONTMHCCandidateCluster,
        analyzed: [AnalyzedAlignment],
        closestHits: [AnalyzedAlignment]
    ) throws -> ONTMHCReciprocalQueryHitSummary {
        struct LocatorIdentity: Hashable {
            let bamPath: String
            let queryName: String
            let referenceName: String
            let readGroupID: String?
            let referenceStart: Int
            let cigar: String

            init(_ locator: ONTMHCEvidenceLocator) {
                bamPath = locator.bamPath
                queryName = locator.queryName
                referenceName = locator.referenceName
                readGroupID = locator.readGroupID
                referenceStart = locator.referenceStart
                cigar = locator.cigar
            }
        }

        var seenLocators = Set<LocatorIdentity>()
        var targetAlignmentCounts: [String: Int] = [:]
        for hit in analyzed where seenLocators.insert(LocatorIdentity(hit.input.evidence)).inserted {
            targetAlignmentCounts[hit.input.evidence.referenceName, default: 0] += 1
        }
        let exactMatchTargetNames = Set(analyzed.lazy.filter {
            $0.failure == nil && $0.metrics.snps == 0
        }.map(\.input.evidence.referenceName)).sorted(by: localizedStandardLessThan)
        let closestMatchTargetNames: [String]
        if let closest = best(closestHits) {
            closestMatchTargetNames = Set(closestHits.lazy.filter {
                hasEquivalentBiologicalRank($0, closest)
            }.map(\.input.evidence.referenceName)).sorted(by: localizedStandardLessThan)
        } else {
            closestMatchTargetNames = []
        }
        return try ONTMHCReciprocalQueryHitSummary(
            bamPath: reciprocalBAMPath,
            queryName: cluster.stableClusterID,
            alignmentCount: targetAlignmentCounts.values.reduce(0, +),
            targetAlignmentCounts: targetAlignmentCounts,
            exactMatchTargetNames: exactMatchTargetNames,
            closestMatchTargetNames: closestMatchTargetNames
        )
    }

    private func intronSizedQueryInsertionBases(
        cigar: String,
        minimumLength: Int,
        cluster: FullLengthONTMHCCandidateCluster,
        alignmentIndex: Int
    ) throws -> Int {
        struct Operation {
            let length: Int
            let code: Character

            var isComparable: Bool {
                code == "=" || code == "X" || code == "M"
            }
        }

        var token = ""
        var operations: [Operation] = []
        for character in cigar {
            if character.isNumber {
                token.append(character)
                continue
            }
            guard let length = Int(token) else {
                throw invalidAlignment(cluster, alignmentIndex, "cigar", cigar)
            }
            operations.append(Operation(length: length, code: character))
            token = ""
        }

        func hasComparableContext(from insertionIndex: Int, step: Int) -> Bool {
            var index = insertionIndex + step
            while operations.indices.contains(index) {
                let operation = operations[index]
                if operation.isComparable {
                    return true
                }
                guard operation.code == "D" else {
                    return false
                }
                index += step
            }
            return false
        }

        var total = 0
        for index in operations.indices where operations[index].code == "I" {
            let operation = operations[index]
            guard operation.length >= minimumLength,
                  hasComparableContext(from: index, step: -1),
                  hasComparableContext(from: index, step: 1) else {
                continue
            }
            let sum = total.addingReportingOverflow(operation.length)
            guard !sum.overflow else {
                throw FullLengthONTMHCCandidateClassifierError.arithmeticOverflow(
                    stableClusterID: cluster.stableClusterID,
                    field: "longGapBases"
                )
            }
            total = sum.partialValue
        }
        return total
    }

    private func validate(
        locator: ONTMHCEvidenceLocator,
        cluster: FullLengthONTMHCCandidateCluster,
        observationIndex: Int
    ) throws {
        guard !locator.bamPath.isEmpty,
              !locator.queryName.isEmpty,
              !locator.referenceName.isEmpty,
              locator.referenceStart > 0,
              !locator.cigar.isEmpty else {
            throw invalidObservation(cluster, observationIndex, "evidence", "invalid locator")
        }
    }

    private func validate(
        locator: ONTMHCEvidenceLocator,
        cluster: FullLengthONTMHCCandidateCluster,
        alignmentIndex: Int
    ) throws {
        guard !locator.bamPath.isEmpty,
              !locator.queryName.isEmpty,
              !locator.referenceName.isEmpty,
              locator.referenceStart > 0,
              !locator.cigar.isEmpty else {
            throw invalidAlignment(cluster, alignmentIndex, "evidence", "invalid locator")
        }
    }

    private func invalidObservation(
        _ cluster: FullLengthONTMHCCandidateCluster,
        _ index: Int,
        _ field: String,
        _ value: String
    ) -> FullLengthONTMHCCandidateClassifierError {
        .invalidObservation(stableClusterID: cluster.stableClusterID, index: index, field: field, value: value)
    }

    private func invalidAlignment(
        _ cluster: FullLengthONTMHCCandidateCluster,
        _ index: Int,
        _ field: String,
        _ value: String
    ) -> FullLengthONTMHCCandidateClassifierError {
        .invalidAlignment(stableClusterID: cluster.stableClusterID, index: index, field: field, value: value)
    }
}

private func localizedStandardLessThan(_ lhs: String, _ rhs: String) -> Bool {
    lhs.localizedStandardCompare(rhs) == .orderedAscending
}
