import Foundation
import LungfishIO

public enum FullLengthONTMHCCandidateReferenceResolution: Equatable, Sendable {
    case resolved(MHCReferenceRecord)
    case unresolvedLocus(referenceName: String, sequenceLength: Int)
    case ambiguousReferenceClass(referenceName: String, locus: String, sequenceLength: Int)

    public var referenceName: String {
        switch self {
        case .resolved(let record): record.alleleName
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

    public init(
        reference: FullLengthONTMHCCandidateReferenceResolution,
        cigar: String,
        nm: Int?,
        mappingQuality: Int,
        alignmentScore: Int,
        evidence: ONTMHCEvidenceLocator
    ) {
        self.reference = reference
        self.cigar = cigar
        self.nm = nm
        self.mappingQuality = mappingQuality
        self.alignmentScore = alignmentScore
        self.evidence = evidence
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

public enum FullLengthONTMHCCandidateClassificationResult: Equatable, Sendable {
    case known(referenceAllele: String)
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
        let failure: Failure?

        var resolvedReference: MHCReferenceRecord? { input.reference.resolvedRecord }
        var localizedReferenceName: String { input.reference.referenceName }
    }

    private enum Failure: Sendable {
        case insufficientAlignedBases(actual: Double, minimum: Double)
        case insufficientCoverage(actual: Double, minimum: Double)
        case insufficientIdentity(actual: Double, minimum: Double)
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

        var failedMetrics: [String: Double] {
            switch self {
            case .insufficientAlignedBases(let actual, let minimum):
                ["aligned_bases": actual, "minimum_aligned_bases": minimum]
            case .insufficientCoverage(let actual, let minimum):
                ["shorter_coverage": actual, "minimum_shorter_coverage": minimum]
            case .insufficientIdentity(let actual, let minimum):
                ["identity": actual, "minimum_identity": minimum]
            case .unresolvedLocus, .ambiguousReferenceClass:
                [:]
            }
        }
    }

    public let thresholds: ONTMHCCandidateThresholds

    public init(thresholds: ONTMHCCandidateThresholds = .defaults) {
        self.thresholds = thresholds
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
            return .unnameable(unnameableRecord(
                cluster: cluster,
                support: support,
                reason: .noAlignment,
                failedMetrics: [:],
                evidence: []
            ))
        }

        let eligible = analyzed.filter { $0.failure == nil }

        if let knownGenomic = best(eligible.filter {
            $0.metrics.snps == 0 && $0.resolvedReference?.moleculeClass == .genomicDNA
        }) {
            return .known(referenceAllele: knownGenomic.resolvedReference!.alleleName)
        }

        if let extensionHit = best(eligible.filter { isExactCDNAExtension($0, cluster: cluster) }) {
            return .candidate(candidateRecord(
                cluster: cluster,
                support: support,
                hit: extensionHit,
                classification: .extension
            ))
        }

        // Exact cDNA matches and zero-SNP indel-only relationships that do not
        // meet the stricter extension rule remain genotypes of the existing allele.
        if let knownZeroSNP = best(eligible.filter { $0.metrics.snps == 0 }) {
            return .known(referenceAllele: knownZeroSNP.resolvedReference!.alleleName)
        }

        if let novel = best(eligible.filter { $0.metrics.snps > 0 }) {
            return .candidate(candidateRecord(
                cluster: cluster,
                support: support,
                hit: novel,
                classification: .novel
            ))
        }

        let closest = best(analyzed)!
        let failure = closest.failure ?? .unresolvedLocus
        return .unnameable(unnameableRecord(
            cluster: cluster,
            support: support,
            reason: failure.reason,
            failedMetrics: failure.failedMetrics,
            evidence: analyzed.map(\.input.evidence)
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
            guard observation.aggregatedSampleReadCount >= 0 else {
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
                  observation.sourceClusterReadCounts.values.allSatisfy({ $0 >= 0 }) else {
                throw invalidObservation(
                    cluster,
                    index,
                    "sourceClusterReadCounts",
                    "keys differ from sourceClusterIDs or a count is negative"
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

        let failure: Failure?
        if metrics.comparableBases < thresholds.minimumAlignedBases {
            failure = .insufficientAlignedBases(
                actual: Double(metrics.comparableBases),
                minimum: Double(thresholds.minimumAlignedBases)
            )
        } else if shorterCoverage < thresholds.minimumShorterCoverage {
            failure = .insufficientCoverage(actual: shorterCoverage, minimum: thresholds.minimumShorterCoverage)
        } else if identity < thresholds.minimumIdentity {
            failure = .insufficientIdentity(actual: identity, minimum: thresholds.minimumIdentity)
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

        return AnalyzedAlignment(
            input: alignment,
            metrics: metrics,
            longGapBases: longGapBases,
            nonIntronIndelBases: nonIntronIndelBases.partialValue,
            shorterCoverage: shorterCoverage,
            identity: identity,
            failure: failure
        )
    }

    private func isExactCDNAExtension(
        _ hit: AnalyzedAlignment,
        cluster: FullLengthONTMHCCandidateCluster
    ) -> Bool {
        guard let reference = hit.resolvedReference,
              reference.moleculeClass == .cDNA,
              hit.metrics.snps == 0,
              hit.metrics.comparableBases == reference.sequenceLength,
              hit.identity == 1,
              hit.longGapBases > 0,
              hit.nonIntronIndelBases == 0,
              hit.metrics.deletedBases == 0,
              hit.metrics.skippedReferenceBases == 0,
              hit.metrics.softClippedBases == 0,
              hit.metrics.querySpan == cluster.sequenceLength else {
            return false
        }
        return true
    }

    private func best(_ hits: [AnalyzedAlignment]) -> AnalyzedAlignment? {
        hits.min(by: isRankedBefore)
    }

    private func isRankedBefore(_ lhs: AnalyzedAlignment, _ rhs: AnalyzedAlignment) -> Bool {
        if lhs.metrics.snps != rhs.metrics.snps { return lhs.metrics.snps < rhs.metrics.snps }
        if lhs.metrics.comparableBases != rhs.metrics.comparableBases {
            return lhs.metrics.comparableBases > rhs.metrics.comparableBases
        }
        if lhs.nonIntronIndelBases != rhs.nonIntronIndelBases {
            return lhs.nonIntronIndelBases < rhs.nonIntronIndelBases
        }
        if lhs.input.alignmentScore != rhs.input.alignmentScore {
            return lhs.input.alignmentScore > rhs.input.alignmentScore
        }
        if lhs.input.mappingQuality != rhs.input.mappingQuality {
            return lhs.input.mappingQuality > rhs.input.mappingQuality
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
        classification: ONTMHCCandidateClassification
    ) -> ONTMHCCandidateRecord {
        let reference = hit.resolvedReference!
        let provisionalName: String
        switch classification {
        case .extension:
            provisionalName = "\(reference.alleleName)_ext"
        case .novel:
            precondition(hit.metrics.snps > 0, "Novel candidates must contain at least one SNP substitution")
            provisionalName = "\(reference.alleleName)_\(hit.metrics.snps)nt_nov"
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
            selectedEvidence: hit.input.evidence
        )
    }

    private func unnameableRecord(
        cluster: FullLengthONTMHCCandidateCluster,
        support: Support,
        reason: ONTMHCUnnameableReason,
        failedMetrics: [String: Double],
        evidence: [ONTMHCEvidenceLocator]
    ) -> ONTMHCUnnameableRecord {
        ONTMHCUnnameableRecord(
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
            evidence: evidence
        )
    }

    private func intronSizedQueryInsertionBases(
        cigar: String,
        minimumLength: Int,
        cluster: FullLengthONTMHCCandidateCluster,
        alignmentIndex: Int
    ) throws -> Int {
        var token = ""
        var total = 0
        for character in cigar {
            if character.isNumber {
                token.append(character)
                continue
            }
            guard let length = Int(token) else {
                throw invalidAlignment(cluster, alignmentIndex, "cigar", cigar)
            }
            if character == "I", length >= minimumLength {
                let sum = total.addingReportingOverflow(length)
                guard !sum.overflow else {
                    throw FullLengthONTMHCCandidateClassifierError.arithmeticOverflow(
                        stableClusterID: cluster.stableClusterID,
                        field: "longGapBases"
                    )
                }
                total = sum.partialValue
            }
            token = ""
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
