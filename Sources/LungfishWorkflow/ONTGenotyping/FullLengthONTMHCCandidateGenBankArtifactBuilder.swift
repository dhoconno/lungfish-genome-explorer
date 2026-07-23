import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

struct FullLengthONTMHCCandidateGenBankArtifactBuilder {
    enum Subject: Sendable {
        case candidate(ONTMHCCandidateRecord)
        case unnameable(ONTMHCUnnameableRecord)

        var stableClusterID: String {
            switch self {
            case .candidate(let value): value.stableClusterID
            case .unnameable(let value): value.stableClusterID
            }
        }

        var displayName: String {
            switch self {
            case .candidate(let value): value.provisionalName
            case .unnameable(let value): value.stableClusterID
            }
        }

        var definition: String {
            switch self {
            case .candidate(let value):
                return "\(value.provisionalName); Lungfish full-length ONT MHC candidate"
            case .unnameable(let value):
                return "\(value.stableClusterID); un-nameable MHC cluster (\(value.reason.rawValue))"
            }
        }

        var supportClass: ONTMHCCandidateSupportClass {
            switch self {
            case .candidate(let value): value.supportClass
            case .unnameable(let value): value.supportClass
            }
        }

        var supportingSampleIDs: [String] {
            switch self {
            case .candidate(let value): value.supportingSampleIDs
            case .unnameable(let value): value.supportingSampleIDs
            }
        }

        var independentSampleCount: Int {
            switch self {
            case .candidate(let value): value.independentSampleCount
            case .unnameable(let value): value.independentSampleCount
            }
        }

        var occurrenceCount: Int {
            switch self {
            case .candidate(let value): value.occurrenceCount
            case .unnameable(let value): value.occurrenceCount
            }
        }

        var totalClusterReads: Int {
            switch self {
            case .candidate(let value): value.totalClusterReads
            case .unnameable(let value): value.totalClusterReads
            }
        }

        var sequenceSHA256: String? {
            switch self {
            case .candidate(let value): value.sequenceSHA256
            case .unnameable(let value): value.sequenceSHA256
            }
        }

        var externalArtifactID: String {
            switch self {
            case .candidate(let value): value.stableClusterID
            case .unnameable(let value): value.fastaRecordID ?? value.stableClusterID
            }
        }

        var hasDeclaredExternalSequenceIdentity: Bool {
            switch self {
            case .candidate:
                return true
            case .unnameable(let value):
                guard let fastaRecordID = value.fastaRecordID,
                      let sequenceSHA256 = value.sequenceSHA256 else {
                    return false
                }
                return !fastaRecordID.isEmpty && !sequenceSHA256.isEmpty
            }
        }

        var selectedEvidence: ONTMHCEvidenceLocator? {
            switch self {
            case .candidate(let value): value.selectedEvidence
            case .unnameable(let value): value.selectedEvidence
            }
        }

        var isCDNAReference: Bool {
            guard case .candidate(let value) = self else { return false }
            return value.closestReferenceClass == .cDNA
        }

        var isCandidate: Bool {
            guard case .candidate = self else { return false }
            return true
        }

        var candidateRecord: ONTMHCCandidateRecord? {
            guard case .candidate(let value) = self else { return nil }
            return value
        }

        var subjectQualifiers: [String: AnnotationQualifier] {
            var values: [String: AnnotationQualifier] = [
                "stable_cluster_id": .init(stableClusterID),
                "support_class": .init(supportClass.rawValue),
                "independent_sample_count": .init(String(independentSampleCount)),
                "occurrence_count": .init(String(occurrenceCount)),
                "total_cluster_reads": .init(String(totalClusterReads)),
                "supporting_sample_ids": .init(supportingSampleIDs.sorted()),
            ]
            if let sequenceSHA256 {
                values["sequence_sha256"] = .init(sequenceSHA256)
            }
            switch self {
            case .candidate(let value):
                values["provisional_name"] = .init(value.provisionalName)
                values["classification"] = .init(value.classification.rawValue)
            case .unnameable(let value):
                values["unnameable_reason"] = .init(value.reason.rawValue)
            }
            return values
        }
    }

    struct Input: Sendable {
        let subject: Subject
        let sequence: String
        let selectedAlignmentIsReverse: Bool?
        let closestReference: ONTMHCReferenceVisualizationRecord?
        let analysisName: String
        let projectBundleName: String?
        let minimumIntronGapBases: Int
    }

    enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidInput(stableClusterID: String, detail: String)
        case invalidCIGAR(stableClusterID: String, cigar: String)
        case alignmentOutOfBounds(stableClusterID: String)

        var errorDescription: String? {
            switch self {
            case .invalidInput(let id, let detail):
                "Invalid candidate GenBank input '\(id)': \(detail)."
            case .invalidCIGAR(let id, let cigar):
                "Invalid reciprocal CIGAR '\(cigar)' for candidate GenBank record '\(id)'."
            case .alignmentOutOfBounds(let id):
                "Reciprocal alignment exceeds the candidate or reference sequence for '\(id)'."
            }
        }
    }

    func build(from input: Input) throws -> FullLengthONTMHCCandidateCanonicalization {
        try makeCanonicalization(input)
    }

    func records(from inputs: [Input]) throws -> [GenBankRecord] {
        try inputs.sorted { $0.subject.stableClusterID < $1.subject.stableClusterID }
            .compactMap { input in
                let result = try build(from: input)
                guard result.externalSequence != nil else { return nil }
                return result.record
            }
    }
}

private extension FullLengthONTMHCCandidateGenBankArtifactBuilder {
    struct Insertion {
        let referenceBoundary: Int
        let orientedQueryRange: Range<Int>
    }

    struct Projection {
        let referenceToOrientedQuery: [Int: Int]
        let insertions: [Insertion]
        let changes: FullLengthONTMHCCandidateChangeProjection
        let leadingTerminalRescuedBases: Int
        let trailingTerminalRescuedBases: Int
        let terminalRescuedSubstitutions: Int
        let queryLength: Int
        let isReverse: Bool
        let minimumIntronGapBases: Int
        let excludeLongInsertionsAsIntronFills: Bool

        func intervals(for feature: ONTMHCReferenceVisualizationFeature) -> [AnnotationInterval] {
            var positions = Set<Int>()
            for referencePosition in feature.start..<feature.end {
                guard let oriented = referenceToOrientedQuery[referencePosition] else { continue }
                positions.insert(candidatePosition(oriented))
            }
            for insertion in insertions where insertion.referenceBoundary > feature.start
                && insertion.referenceBoundary < feature.end
                && (!excludeLongInsertionsAsIntronFills
                    || insertion.orientedQueryRange.count < minimumIntronGapBases) {
                for oriented in insertion.orientedQueryRange {
                    positions.insert(candidatePosition(oriented))
                }
            }
            return mergedIntervals(positions.sorted())
        }

        func maps(referencePosition: Int) -> Bool {
            referenceToOrientedQuery[referencePosition] != nil
        }

        func assessesEveryReferenceBase(of feature: ONTMHCReferenceVisualizationFeature) -> Bool {
            (feature.start..<feature.end).allSatisfy {
                changes.assessedReferencePositions.contains($0)
            }
        }

        func coversBoundaries(of feature: ONTMHCReferenceVisualizationFeature) -> Bool {
            feature.start < feature.end
                && maps(referencePosition: feature.start)
                && maps(referencePosition: feature.end - 1)
        }

        func longInsertionCount(inside feature: ONTMHCReferenceVisualizationFeature) -> Int {
            insertions.filter {
                $0.referenceBoundary > feature.start
                    && $0.referenceBoundary < feature.end
                    && $0.orientedQueryRange.count >= minimumIntronGapBases
            }.count
        }

        private func candidatePosition(_ oriented: Int) -> Int {
            isReverse ? queryLength - oriented - 1 : oriented
        }

        private func mergedIntervals(_ positions: [Int]) -> [AnnotationInterval] {
            guard let first = positions.first else { return [] }
            var result: [AnnotationInterval] = []
            var start = first
            var previous = first
            for position in positions.dropFirst() {
                if position != previous + 1 {
                    result.append(.init(start: start, end: previous + 1))
                    start = position
                }
                previous = position
            }
            result.append(.init(start: start, end: previous + 1))
            return result
        }
    }

    func makeCanonicalization(_ input: Input) throws -> FullLengthONTMHCCandidateCanonicalization {
        let stableID = input.subject.stableClusterID
        let externalArtifactID = input.subject.externalArtifactID
        let sequence = input.sequence.uppercased()
        guard !stableID.isEmpty, !sequence.isEmpty, input.minimumIntronGapBases > 0 else {
            throw Error.invalidInput(stableClusterID: stableID, detail: "identity, sequence, and intron threshold must be nonempty and positive")
        }

        var annotations = [SequenceAnnotation(
            type: .source,
            name: input.subject.displayName,
            start: 0,
            end: sequence.count,
            strand: .forward,
            qualifiers: input.subject.subjectQualifiers
        )]
        var comments = baseComments(input)
        var translationStatus = FullLengthONTMHCTranslationStatus.incompleteUnresolved
        var liftedCDSTrimRange: Range<Int>?
        var substitutionCount = 0
        var comparableBases = 0
        var identity = 0.0
        var shorterCoverage = 0.0

        if let evidence = input.subject.selectedEvidence,
           let isReverse = input.selectedAlignmentIsReverse,
           let reference = input.closestReference {
            guard evidence.referenceName == reference.rawReferenceID else {
                throw Error.invalidInput(stableClusterID: stableID, detail: "selected reference does not match the visualization record")
            }
            let terminalCDSIntervals = terminalCDSIntervals(reference.features)
            let projection = try makeProjection(
                stableID: stableID,
                cigar: evidence.cigar,
                referenceStart: evidence.referenceStart,
                candidateSequence: sequence,
                referenceSequence: reference.sequence,
                isReverse: isReverse,
                minimumIntronGapBases: input.minimumIntronGapBases,
                terminalCDSIntervals: terminalCDSIntervals,
                excludeLongInsertionsAsIntronFills: !input.subject.isCandidate
                    || input.subject.isCDNAReference
            )
            let canonicalReferenceRange = terminalCDSIntervals.map {
                $0.leading.lowerBound..<$0.trailing.upperBound
            }
            substitutionCount = projection.changes.events.reduce(into: 0) { count, event in
                guard case let .substitution(referencePosition, _, _, _) = event else {
                    return
                }
                if canonicalReferenceRange?.contains(referencePosition) ?? true {
                    count += 1
                }
            }
            comparableBases = projection.referenceToOrientedQuery.keys.reduce(into: 0) {
                count, referencePosition in
                if canonicalReferenceRange?.contains(referencePosition) ?? true {
                    count += 1
                }
            }
            identity = comparableBases > 0
                ? Double(comparableBases - substitutionCount) / Double(comparableBases)
                : 0
            if projection.leadingTerminalRescuedBases > 0
                || projection.trailingTerminalRescuedBases > 0 {
                comments.append(
                    "Lungfish terminal local-clipping rescue: leading reference bases="
                        + String(projection.leadingTerminalRescuedBases)
                        + "; trailing reference bases="
                        + String(projection.trailingTerminalRescuedBases)
                        + "; rescued substitutions="
                        + String(projection.terminalRescuedSubstitutions)
                        + "; eligibility=single terminal CDS interval, canonical A/C/G/T, missing bases < "
                        + String(input.minimumIntronGapBases)
                        + ", mismatches <= max(1,floor(0.20*missing bases))"
                        + "; rescue mode=substitution-only (no indel inference)"
                        + "; selected POS/CIGAR/NM/AS evidence retained unchanged"
                )
            }
            let lifted = liftFeatures(
                reference.features,
                projection: projection,
                candidateSequence: sequence,
                defaultName: input.subject.displayName,
                retainReferenceIntrons: input.subject.isCandidate,
                requireCompleteCDSAssessment: input.subject.isCandidate,
                requireSupportedTranslationTable: input.subject.isCandidate
            )
            translationStatus = lifted.translationStatus
            annotations.append(contentsOf: lifted.annotations)
            if let cds = lifted.annotations.first(where: { $0.type == .cds }) {
                liftedCDSTrimRange = cds.start..<cds.end
            }
            let canonicalCandidateLength = liftedCDSTrimRange?.count ?? sequence.count
            let canonicalReferenceLength = canonicalReferenceRange?.count
                ?? reference.sequence.count
            let shorterLength = min(canonicalCandidateLength, canonicalReferenceLength)
            shorterCoverage = shorterLength > 0
                ? min(1, Double(comparableBases) / Double(shorterLength))
                : 0
            if input.subject.isCDNAReference,
               let cds = lifted.annotations.first(where: { $0.type == .cds }),
               let sourceCDS = reference.features.first(where: {
                   AnnotationType.from(rawString: $0.type) == .cds
               }),
               projection.assessesEveryReferenceBase(of: sourceCDS),
               projection.longInsertionCount(inside: sourceCDS) == cds.intervals.count - 1,
               cds.intervals.count > 1,
               !lifted.hadSourceExons {
                annotations.append(contentsOf: cds.intervals.enumerated().map { index, interval in
                    SequenceAnnotation(
                        type: .exon,
                        name: "inferred exon \(index + 1)",
                        intervals: [interval],
                        strand: cds.strand,
                        qualifiers: [
                            "number": .init(String(index + 1)),
                            "inference": .init("alignment:reciprocal CIGAR insertion >= \(input.minimumIntronGapBases) bases"),
                        ]
                    )
                })
                annotations.append(contentsOf: zip(cds.intervals, cds.intervals.dropFirst()).enumerated().compactMap {
                    index, pair in
                    let (left, right) = pair
                    guard left.end < right.start else { return nil }
                    return SequenceAnnotation(
                        type: .intron,
                        name: "inferred intron \(index + 1)",
                        intervals: [.init(start: left.end, end: right.start)],
                        strand: cds.strand,
                        qualifiers: [
                            "number": .init(String(index + 1)),
                            "inference": .init("alignment:reciprocal CIGAR insertion >= \(input.minimumIntronGapBases) bases"),
                        ]
                    )
                })
                comments.append("Lungfish inferred exon count: \(cds.intervals.count) (reciprocal-CIGAR; minimum intron insertion \(input.minimumIntronGapBases) bp)")
            }
            if let candidateTranslation = annotations.first(where: { $0.type == .cds })?
                .qualifier("translation") {
                let internalStops = candidateTranslation.filter { $0 == "*" }.count
                let aminoAcidCount = candidateTranslation.filter { $0 != "*" }.count
                let referenceLength = preferredReferenceTranslation(reference)
                    .map { $0.filter { $0 != "*" }.count }
                comments.append(
                    "Lungfish translation comparison: candidate amino acids=\(aminoAcidCount); "
                        + "closest-reference amino acids=\(referenceLength.map(String.init) ?? "unavailable"); "
                        + "internal stops=\(internalStops)"
                )
            }
            let liftedExons = annotations.filter { $0.type == .exon }
                .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
            if !liftedExons.isEmpty {
                let reverse = liftedExons.first?.strand == .reverse
                let terminal = reverse ? liftedExons.first : liftedExons.last
                let terminalBases = terminal?.intervals.reduce(0) { $0 + $1.length } ?? 0
                comments.append(
                    "Lungfish lifted exon structure: exons=\(liftedExons.count); "
                        + "terminal exon bases=\(terminalBases); "
                        + "short eighth exon=\(liftedExons.count == 8 && terminalBases <= 30)"
                )
            }
            comments.append("Lungfish selected reference: \(reference.rawReferenceID) (\(reference.alleleName))")
            comments.append("Lungfish reciprocal alignment: start=\(evidence.referenceStart); cigar=\(evidence.cigar); orientation=\(isReverse ? "reverse" : "forward")")
            if input.subject.isCandidate {
                comments.append(contentsOf: FullLengthONTMHCCandidateConsequenceAnnotator().comments(for: .init(
                    reference: reference,
                    projection: projection.changes.rebasedStoredCoordinates(
                        by: liftedCDSTrimRange?.lowerBound ?? 0,
                        length: liftedCDSTrimRange?.count ?? sequence.count
                    ),
                    isCDNAReference: input.subject.isCDNAReference,
                    minimumIntronGapBases: input.minimumIntronGapBases,
                    candidateTranslation: annotations.first(where: { $0.type == .cds })?.qualifier("translation"),
                    referenceTranslation: preferredReferenceTranslation(reference),
                    translationStatus: translationStatus
                )))
            }
        } else if let evidence = input.subject.selectedEvidence,
                  let isReverse = input.selectedAlignmentIsReverse {
            comments.append("Lungfish selected reference raw ID: \(evidence.referenceName)")
            comments.append("Lungfish reciprocal alignment: start=\(evidence.referenceStart); cigar=\(evidence.cigar); orientation=\(isReverse ? "reverse" : "forward")")
            comments.append("Lungfish annotation unavailable: closest-reference annotations are unavailable")
            if input.subject.isCandidate {
                comments.append(contentsOf: FullLengthONTMHCCandidateConsequenceAnnotator.summaryPrefixes.map {
                    "\($0) unavailable: closest-reference annotations are unavailable"
                })
            }
        } else {
            comments.append("Lungfish annotation unavailable: no selected reciprocal alignment")
            if input.subject.isCandidate {
                comments.append(contentsOf: FullLengthONTMHCCandidateConsequenceAnnotator.summaryPrefixes.map {
                    "\($0) unavailable: no selected reciprocal alignment"
                })
            }
        }

        annotations[0].qualifiers["translation_status"] = .init(translationStatus.rawValue)

        let referenceReadiness: FullLengthONTMHCReferenceReadiness
        if liftedCDSTrimRange == nil {
            referenceReadiness = .unavailable
        } else if translationStatus == .incompleteUnresolved {
            referenceReadiness = .incomplete
        } else {
            referenceReadiness = .referenceReady
        }
        let externalSequence = referenceReadiness == .referenceReady
            && input.subject.hasDeclaredExternalSequenceIdentity
            ? liftedCDSTrimRange.map { substring(sequence, in: $0) }
            : nil

        let outputSequence: String
        let sequenceLabel = input.subject.isCandidate ? "candidate" : "un-nameable"
        if input.subject.isCandidate || externalSequence != nil {
            let trimRange = liftedCDSTrimRange ?? 0..<sequence.count
            outputSequence = substring(sequence, in: trimRange)
            let trimStatus: String
            if liftedCDSTrimRange == nil {
                trimStatus = "unavailable-no-lifted-CDS"
                comments.append(
                    "Lungfish \(sequenceLabel) sequence trim: UTR trimming unavailable; no lifted CDS; "
                        + "original length=" + String(sequence.count)
                        + "; trim start=1; trim end=" + String(sequence.count)
                        + "; retained length=" + String(outputSequence.count)
                )
                comments.append("Lungfish reference readiness: not reference-ready; CDS/UTR boundaries could not be resolved")
            } else if translationStatus == .incompleteUnresolved {
                trimStatus = "trimmed-to-partial-lifted-CDS"
                comments.append(
                    "Lungfish \(sequenceLabel) sequence trim: partial lifted CDS; original length="
                        + String(sequence.count) + "; trim start=" + String(trimRange.lowerBound + 1)
                        + "; trim end=" + String(trimRange.upperBound)
                        + "; retained length=" + String(outputSequence.count)
                )
                comments.append("Lungfish reference readiness: not reference-ready; partial or unresolved lifted CDS")
            } else {
                trimStatus = "trimmed-to-outer-lifted-CDS"
                comments.append(
                    "Lungfish \(sequenceLabel) sequence trim: outer lifted CDS span; original length="
                        + String(sequence.count) + "; trim start=" + String(trimRange.lowerBound + 1)
                        + "; trim end=" + String(trimRange.upperBound)
                        + "; retained length=" + String(outputSequence.count)
                )
                comments.append("Lungfish reference readiness: reference-ready; complete lifted CDS boundaries resolved")
            }
            let outputSHA256 = sha256Hex(outputSequence)
            annotations[0].qualifiers["original_sequence_length"] = .init(String(sequence.count))
            annotations[0].qualifiers["trim_start"] = .init(String(trimRange.lowerBound + 1))
            annotations[0].qualifiers["trim_end"] = .init(String(trimRange.upperBound))
            annotations[0].qualifiers["genbank_sequence_sha256"] = .init(outputSHA256)
            annotations[0].qualifiers["trim_status"] = .init(trimStatus)
            annotations[0].qualifiers["reference_readiness_status"] = .init(referenceReadiness.rawValue)
            comments.append("Lungfish GenBank sequence SHA-256: " + outputSHA256)
            annotations = cropAndRebase(annotations, to: trimRange)
        } else {
            outputSequence = sequence
            let outputSHA256 = sha256Hex(outputSequence)
            annotations[0].qualifiers["original_sequence_length"] = .init(String(sequence.count))
            if let trimRange = liftedCDSTrimRange {
                annotations[0].qualifiers["trim_start"] = .init(String(trimRange.lowerBound + 1))
                annotations[0].qualifiers["trim_end"] = .init(String(trimRange.upperBound))
                if referenceReadiness == .referenceReady {
                    annotations[0].qualifiers["trim_status"] = .init("not-exported-missing-external-identity")
                    comments.append(
                        "Lungfish \(sequenceLabel) sequence export: omitted because paired external FASTA "
                            + "identity and checksum are unavailable; complete lifted CDS boundaries retained "
                            + "for diagnostics"
                    )
                    comments.append(
                        "Lungfish reference readiness: reference-ready; complete lifted CDS boundaries resolved; "
                            + "external publication identity unavailable"
                    )
                } else {
                    annotations[0].qualifiers["trim_status"] = .init("not-exported-partial-lifted-CDS")
                    comments.append(
                        "Lungfish \(sequenceLabel) sequence trim: partial lifted CDS boundaries retained for diagnostics; "
                            + "external sequence omitted"
                    )
                }
            } else {
                annotations[0].qualifiers["trim_status"] = .init("unavailable-no-lifted-CDS")
            }
            annotations[0].qualifiers["genbank_sequence_sha256"] = .init(outputSHA256)
            annotations[0].qualifiers["reference_readiness_status"] = .init(referenceReadiness.rawValue)
            comments.append("Lungfish GenBank sequence SHA-256: " + outputSHA256)
        }

        let recordFields = copiedRecordFields(input.closestReference)
            + comments.enumerated().map { GenBankRecordField(key: "COMMENT", value: $0.element, ordinal: recordFieldsBaseCount(input.closestReference) + $0.offset) }
        let record = GenBankRecord(
            sequence: try Sequence(name: externalArtifactID, description: input.subject.definition, alphabet: .dna, bases: outputSequence),
            annotations: annotations.sorted(by: annotationLessThan),
            locus: LocusInfo(name: externalArtifactID, length: outputSequence.count, moleculeType: .dna, topology: .linear),
            definition: input.subject.definition,
            accession: externalArtifactID,
            recordFields: recordFields
        )
        return FullLengthONTMHCCandidateCanonicalization(
            record: record,
            rawSequence: sequence,
            externalSequence: externalSequence,
            trimRange: liftedCDSTrimRange,
            translationStatus: translationStatus,
            referenceReadiness: referenceReadiness,
            substitutionCount: substitutionCount,
            comparableBases: comparableBases,
            identity: identity,
            shorterCoverage: shorterCoverage
        )
    }

    func cropAndRebase(
        _ annotations: [SequenceAnnotation],
        to trimRange: Range<Int>
    ) -> [SequenceAnnotation] {
        annotations.compactMap { annotation in
            var rebased = annotation
            if annotation.type == .source {
                rebased.intervals = [.init(start: 0, end: trimRange.count)]
                return rebased
            }
            let intervals = annotation.intervals.compactMap { interval -> AnnotationInterval? in
                let start = max(interval.start, trimRange.lowerBound)
                let end = min(interval.end, trimRange.upperBound)
                guard start < end else { return nil }
                return .init(start: start - trimRange.lowerBound, end: end - trimRange.lowerBound)
            }
            guard !intervals.isEmpty else { return nil }
            rebased.intervals = intervals
            return rebased
        }
    }

    func substring(_ sequence: String, in range: Range<Int>) -> String {
        let lower = sequence.index(sequence.startIndex, offsetBy: range.lowerBound)
        let upper = sequence.index(sequence.startIndex, offsetBy: range.upperBound)
        return String(sequence[lower..<upper])
    }

    func sha256Hex(_ sequence: String) -> String {
        SHA256.hash(data: Data(sequence.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func baseComments(_ input: Input) -> [String] {
        var values = [
            "Lungfish analysis: \(input.analysisName)",
            "Lungfish stable cluster ID: \(input.subject.stableClusterID)",
            "Lungfish support: \(input.subject.supportClass.rawValue); independent samples=\(input.subject.independentSampleCount); occurrences=\(input.subject.occurrenceCount); reads=\(input.subject.totalClusterReads)",
            "Lungfish supporting samples: \(input.subject.supportingSampleIDs.sorted().joined(separator: ", "))",
        ]
        if let sequenceSHA256 = input.subject.sequenceSHA256 {
            values.insert("Lungfish sequence SHA-256: \(sequenceSHA256)", at: 2)
        }
        if let project = input.projectBundleName, !project.isEmpty {
            values.insert("Lungfish project: \(project)", at: 1)
        }
        if let candidate = input.subject.candidateRecord, !candidate.extensionOf.isEmpty {
            values.append("Lungfish extension of: \(candidate.extensionOf.joined(separator: ", "))")
            let closestLabel = candidate.closestReferenceClass == .genomicDNA
                ? "selected genomic closest reference"
                : "selected cDNA closest reference"
            values.append("Lungfish \(closestLabel): \(candidate.closestReferenceName) [\(candidate.selectedEvidence.referenceName)]")
            for interpretation in candidate.extensionInterpretations {
                values.append(
                    "Lungfish cDNA interpretation: allele=\(interpretation.alleleName); raw_id=\(interpretation.rawReferenceID); locus=\(interpretation.locus); cdna_coverage=\(interpretation.cDNAReferenceCoverage); cluster_coverage=\(interpretation.clusterCoverage); leading_flank=\(interpretation.leadingClusterFlankBases); trailing_flank=\(interpretation.trailingClusterFlankBases); largest_cluster_structure=\(interpretation.largestClusterStructuralSegmentBases); largest_cdna_deficit=\(interpretation.largestCDNADeficitSegmentBases); snps=\(interpretation.snpSubstitutions); ordinary_indels=\(interpretation.ordinaryIndelBases); strand=\(interpretation.isReverse ? "reverse" : "forward"); score=\(interpretation.alignmentScore); identity=\(interpretation.identity)"
                )
            }
            if candidate.provisionalNamingAmbiguous {
                values.append("Lungfish provisional naming ambiguity: multiple compatible cDNA allele names; genomic closest reference supplied the provisional base name")
            }
        }
        return values
    }

    func copiedRecordFields(_ reference: ONTMHCReferenceVisualizationRecord?) -> [GenBankRecordField] {
        guard let reference else { return [] }
        let keys = ["SOURCE", "ORGANISM", "TAXONOMY"]
        var result: [GenBankRecordField] = []
        for key in keys {
            for value in reference.recordFields[key] ?? [] {
                result.append(.init(key: key, value: value, ordinal: result.count))
            }
        }
        return result
    }

    func recordFieldsBaseCount(_ reference: ONTMHCReferenceVisualizationRecord?) -> Int {
        copiedRecordFields(reference).count
    }

    func makeProjection(
        stableID: String,
        cigar: String,
        referenceStart: Int,
        candidateSequence: String,
        referenceSequence: String,
        isReverse: Bool,
        minimumIntronGapBases: Int,
        terminalCDSIntervals: (leading: Range<Int>, trailing: Range<Int>)?,
        excludeLongInsertionsAsIntronFills: Bool
    ) throws -> Projection {
        guard referenceStart > 0 else { throw Error.alignmentOutOfBounds(stableClusterID: stableID) }
        let orientedCandidate = isReverse
            ? TranslationEngine.reverseComplement(candidateSequence.uppercased())
            : candidateSequence.uppercased()
        let queryBases = Array(orientedCandidate)
        let referenceBases = Array(referenceSequence.uppercased())
        let queryLength = queryBases.count
        let referenceLength = referenceBases.count
        var referenceCursor = referenceStart - 1
        let initialReferenceCursor = referenceCursor
        var queryCursor = 0
        var digits = ""
        var mapping: [Int: Int] = [:]
        var insertions: [Insertion] = []
        var events: [FullLengthONTMHCCandidateChangeProjection.Event] = []
        var assessedReferencePositions = Set<Int>()
        struct ParsedOperation {
            let length: Int
            let operation: Character
            let queryStart: Int
            let referenceStart: Int
        }
        var operations: [ParsedOperation] = []
        for character in cigar {
            if character.isNumber {
                digits.append(character)
                continue
            }
            guard let length = Int(digits), length > 0 else {
                throw Error.invalidCIGAR(stableClusterID: stableID, cigar: cigar)
            }
            digits = ""
            operations.append(.init(
                length: length,
                operation: character,
                queryStart: queryCursor,
                referenceStart: referenceCursor
            ))
            switch character {
            case "M", "=", "X":
                guard queryCursor + length <= queryLength, referenceCursor + length <= referenceLength else {
                    throw Error.alignmentOutOfBounds(stableClusterID: stableID)
                }
                for offset in 0..<length {
                    let referencePosition = referenceCursor + offset
                    let queryPosition = queryCursor + offset
                    mapping[referencePosition] = queryPosition
                    assessedReferencePositions.insert(referencePosition)
                    if referenceBases[referencePosition] != queryBases[queryPosition] {
                        events.append(.substitution(
                            referencePosition: referencePosition,
                            orientedQueryPosition: queryPosition,
                            referenceBase: referenceBases[referencePosition],
                            alternateBase: queryBases[queryPosition]
                        ))
                    }
                }
                referenceCursor += length
                queryCursor += length
            case "I":
                guard queryCursor + length <= queryLength else {
                    throw Error.alignmentOutOfBounds(stableClusterID: stableID)
                }
                let queryRange = queryCursor..<(queryCursor + length)
                insertions.append(.init(referenceBoundary: referenceCursor, orientedQueryRange: queryRange))
                events.append(.insertion(
                    referenceBoundary: referenceCursor,
                    orientedQueryRange: queryRange,
                    bases: String(queryBases[queryRange])
                ))
                queryCursor += length
            case "D":
                guard referenceCursor + length <= referenceLength else {
                    throw Error.alignmentOutOfBounds(stableClusterID: stableID)
                }
                let range = referenceCursor..<(referenceCursor + length)
                assessedReferencePositions.formUnion(range)
                events.append(.deletion(
                    referenceRange: range,
                    orientedQueryBoundary: queryCursor,
                    bases: String(referenceBases[range])
                ))
                referenceCursor += length
            case "N":
                guard referenceCursor + length <= referenceLength else {
                    throw Error.alignmentOutOfBounds(stableClusterID: stableID)
                }
                events.append(.skipped(referenceRange: referenceCursor..<(referenceCursor + length)))
                referenceCursor += length
            case "S":
                queryCursor += length
            case "H":
                if mapping.isEmpty {
                    queryCursor += length
                }
            default:
                throw Error.invalidCIGAR(stableClusterID: stableID, cigar: cigar)
            }
            guard queryCursor <= queryLength, referenceCursor <= referenceLength else {
                throw Error.alignmentOutOfBounds(stableClusterID: stableID)
            }
        }
        guard digits.isEmpty, !mapping.isEmpty else {
            throw Error.invalidCIGAR(stableClusterID: stableID, cigar: cigar)
        }
        var leadingTerminalRescuedBases = 0
        var trailingTerminalRescuedBases = 0
        var terminalRescuedSubstitutions = 0
        let alignedOperations: Set<Character> = ["M", "=", "X"]
        let canonicalBases: Set<Character> = ["A", "C", "G", "T"]
        func eligibleMismatchCount(
            referenceRange: Range<Int>,
            queryRange: Range<Int>
        ) -> Int? {
            guard referenceRange.count == queryRange.count,
                  referenceRange.count > 0,
                  referenceRange.count < minimumIntronGapBases,
                  referenceRange.lowerBound >= 0,
                  referenceRange.upperBound <= referenceBases.count,
                  queryRange.lowerBound >= 0,
                  queryRange.upperBound <= queryBases.count else {
                return nil
            }
            let referenceSlice = referenceBases[referenceRange]
            let querySlice = queryBases[queryRange]
            guard referenceSlice.allSatisfy(canonicalBases.contains),
                  querySlice.allSatisfy(canonicalBases.contains) else {
                return nil
            }
            let mismatches = zip(referenceSlice, querySlice).reduce(into: 0) {
                if $1.0 != $1.1 {
                    $0 += 1
                }
            }
            let allowedMismatches = max(
                1,
                Int(floor(0.20 * Double(referenceRange.count)))
            )
            return mismatches <= allowedMismatches ? mismatches : nil
        }
        if let leadingCDS = terminalCDSIntervals?.leading,
           initialReferenceCursor > leadingCDS.lowerBound,
           initialReferenceCursor <= leadingCDS.upperBound,
           operations.count >= 2,
           let softClip = operations.first,
           softClip.operation == "S",
           alignedOperations.contains(operations[1].operation),
           operations[1].queryStart == softClip.queryStart + softClip.length,
           operations[1].referenceStart == initialReferenceCursor {
            let referenceRange = leadingCDS.lowerBound..<initialReferenceCursor
            let missingLength = referenceRange.count
            let queryStart = softClip.queryStart + softClip.length - missingLength
            let queryRange = queryStart..<(queryStart + missingLength)
            if softClip.length >= missingLength,
               let rescuedMismatches = eligibleMismatchCount(
                   referenceRange: referenceRange,
                   queryRange: queryRange
               ) {
                for offset in 0..<missingLength {
                    let referencePosition = referenceRange.lowerBound + offset
                    let queryPosition = queryStart + offset
                    mapping[referencePosition] = queryPosition
                    assessedReferencePositions.insert(referencePosition)
                    if referenceBases[referencePosition] != queryBases[queryPosition] {
                        events.append(.substitution(
                            referencePosition: referencePosition,
                            orientedQueryPosition: queryPosition,
                            referenceBase: referenceBases[referencePosition],
                            alternateBase: queryBases[queryPosition]
                        ))
                    }
                }
                leadingTerminalRescuedBases = missingLength
                terminalRescuedSubstitutions += rescuedMismatches
            }
        }
        if let trailingCDS = terminalCDSIntervals?.trailing,
           referenceCursor >= trailingCDS.lowerBound,
           referenceCursor < trailingCDS.upperBound,
           operations.count >= 2,
           let softClip = operations.last,
           softClip.operation == "S",
           alignedOperations.contains(operations[operations.count - 2].operation),
           operations[operations.count - 2].queryStart
                + operations[operations.count - 2].length == softClip.queryStart,
           softClip.referenceStart == referenceCursor {
            let referenceRange = referenceCursor..<trailingCDS.upperBound
            let missingLength = referenceRange.count
            let queryRange = softClip.queryStart..<(softClip.queryStart + missingLength)
            if softClip.length >= missingLength,
               let rescuedMismatches = eligibleMismatchCount(
                   referenceRange: referenceRange,
                   queryRange: queryRange
               ) {
                for offset in 0..<missingLength {
                    let referencePosition = referenceCursor + offset
                    let queryPosition = softClip.queryStart + offset
                    mapping[referencePosition] = queryPosition
                    assessedReferencePositions.insert(referencePosition)
                    if referenceBases[referencePosition] != queryBases[queryPosition] {
                        events.append(.substitution(
                            referencePosition: referencePosition,
                            orientedQueryPosition: queryPosition,
                            referenceBase: referenceBases[referencePosition],
                            alternateBase: queryBases[queryPosition]
                        ))
                    }
                }
                trailingTerminalRescuedBases = missingLength
                terminalRescuedSubstitutions += rescuedMismatches
            }
        }
        return Projection(
            referenceToOrientedQuery: mapping,
            insertions: insertions,
            changes: .init(
                events: events,
                assessedReferencePositions: assessedReferencePositions,
                queryLength: queryLength,
                isReverse: isReverse
            ),
            leadingTerminalRescuedBases: leadingTerminalRescuedBases,
            trailingTerminalRescuedBases: trailingTerminalRescuedBases,
            terminalRescuedSubstitutions: terminalRescuedSubstitutions,
            queryLength: queryLength,
            isReverse: isReverse,
            minimumIntronGapBases: minimumIntronGapBases,
            excludeLongInsertionsAsIntronFills: excludeLongInsertionsAsIntronFills
        )
    }

    func terminalCDSIntervals(
        _ features: [ONTMHCReferenceVisualizationFeature]
    ) -> (leading: Range<Int>, trailing: Range<Int>)? {
        let groups = Dictionary(grouping: features.filter {
            AnnotationType.from(rawString: $0.type) == .cds
        }) {
            "\($0.sourceOrdinal)\u{0}\($0.strand)\u{0}\($0.rawGenBankLocation ?? "")"
        }
        guard groups.count == 1,
              let group = groups.values.first else {
            return nil
        }
        let intervals: [Range<Int>] = group.map { feature in
            Range(uncheckedBounds: (lower: feature.start, upper: feature.end))
        }
        let sortedIntervals = intervals.sorted { lhs, rhs in
            if lhs.lowerBound != rhs.lowerBound {
                return lhs.lowerBound < rhs.lowerBound
            }
            return lhs.upperBound < rhs.upperBound
        }
        guard let leading = sortedIntervals.first,
              let trailing = sortedIntervals.last,
              leading.lowerBound < leading.upperBound,
              trailing.lowerBound < trailing.upperBound else {
            return nil
        }
        return (leading, trailing)
    }

    func liftFeatures(
        _ features: [ONTMHCReferenceVisualizationFeature],
        projection: Projection,
        candidateSequence: String,
        defaultName: String,
        retainReferenceIntrons: Bool,
        requireCompleteCDSAssessment: Bool,
        requireSupportedTranslationTable: Bool
    ) -> (
        annotations: [SequenceAnnotation],
        hadSourceExons: Bool,
        translationStatus: FullLengthONTMHCTranslationStatus
    ) {
        var supported: Set<AnnotationType> = [.gene, .mRNA, .transcript, .exon, .cds, .utr5, .utr3]
        if retainReferenceIntrons { supported.insert(.intron) }
        var annotations: [SequenceAnnotation] = []
        var hadSourceExons = false
        var cdsStatuses: [FullLengthONTMHCTranslationStatus] = []
        let featureGroups = Dictionary(grouping: features) {
            "\($0.sourceOrdinal)\u{0}\($0.type)\u{0}\($0.strand)\u{0}\($0.rawGenBankLocation ?? "")"
        }.values.sorted {
            ($0.first?.sourceOrdinal ?? 0) < ($1.first?.sourceOrdinal ?? 0)
        }
        for group in featureGroups {
            guard let feature = group.first else { continue }
            guard let type = AnnotationType.from(rawString: feature.type), supported.contains(type) else { continue }
            guard group.allSatisfy({ AnnotationType.from(rawString: $0.type) == type }) else { continue }
            var intervals = mergedAnnotationIntervals(group.flatMap { projection.intervals(for: $0) })
            guard !intervals.isEmpty else { continue }
            if type == .gene, let first = intervals.first, let last = intervals.last {
                intervals = [.init(start: first.start, end: last.end)]
            }
            if type == .exon { hadSourceExons = true }
            let sourceStrand = Strand(rawValue: feature.strand) ?? .unknown
            let strand = projection.isReverse ? sourceStrand.opposite : sourceStrand
            var qualifiers = safeQualifiers(feature.qualifiers)
            qualifiers["inference"] = .init("alignment:reciprocal minimap2 CIGAR")
            let name = qualifiers["gene"]?.firstValue ?? qualifiers["product"]?.firstValue ?? defaultName
            var annotation = SequenceAnnotation(
                type: type,
                name: name,
                intervals: intervals,
                strand: strand,
                qualifiers: qualifiers
            )
            if type == .cds {
                let sourceStart = group.map(\.start).min() ?? feature.start
                let sourceEnd = group.map(\.end).max() ?? feature.end
                let fivePrimeReferencePosition = sourceStrand == .reverse
                    ? sourceEnd - 1
                    : sourceStart
                let hasSufficientAssessment = group.allSatisfy {
                    requireCompleteCDSAssessment
                        ? projection.assessesEveryReferenceBase(of: $0)
                        : projection.coversBoundaries(of: $0)
                }
                let hasTrustworthyAnnotation = sourceStrand != .unknown
                    && !group.contains(where: {
                        $0.rawGenBankLocation?.contains("<") == true
                            || $0.rawGenBankLocation?.contains(">") == true
                    })
                    && (annotation.qualifier("codon_start").map { $0 == "1" } ?? true)
                let translationTableText = annotation.qualifier("transl_table")
                let hasSupportedTranslationTable = !requireSupportedTranslationTable
                    || translationTableText == nil
                    || translationTableText == "1"
                if projection.maps(referencePosition: fivePrimeReferencePosition),
                   hasSupportedTranslationTable,
                   let translation = translatedCDS(annotation, sequence: candidateSequence) {
                    annotation.qualifiers["translation"] = .init(translation)
                    cdsStatuses.append(
                        translationStatus(
                            annotation: annotation,
                            translation: translation,
                            hasSufficientAssessment: hasSufficientAssessment,
                            hasTrustworthyAnnotation: hasTrustworthyAnnotation
                        )
                    )
                } else {
                    cdsStatuses.append(.incompleteUnresolved)
                    let existingNotes = annotation.qualifiers["note"]?.values ?? []
                    let reason = hasSupportedTranslationTable
                        ? "the 5-prime CDS boundary is not aligned"
                        : "translation table \(translationTableText ?? "unknown") is unsupported"
                    annotation.qualifiers["note"] = .init(
                        existingNotes + ["Candidate translation omitted because \(reason)"]
                    )
                }
            }
            annotations.append(annotation)
        }
        return (
            annotations,
            hadSourceExons,
            cdsStatuses.count == 1 ? cdsStatuses[0] : .incompleteUnresolved
        )
    }

    func translationStatus(
        annotation: SequenceAnnotation,
        translation: String,
        hasSufficientAssessment: Bool,
        hasTrustworthyAnnotation: Bool
    ) -> FullLengthONTMHCTranslationStatus {
        guard hasSufficientAssessment,
              hasTrustworthyAnnotation,
              !translation.uppercased().contains("X") else {
            return .incompleteUnresolved
        }
        let offset = annotation.qualifier("codon_start")
            .flatMap(Int.init)
            .map { max(0, min(2, $0 - 1)) } ?? 0
        let codingBaseCount = max(0, annotation.totalLength - offset)
        guard codingBaseCount > 0 else { return .incompleteUnresolved }
        if codingBaseCount.isMultiple(of: 3), !translation.contains("*") {
            return .fullLength
        }
        return .pseudogene
    }

    func mergedAnnotationIntervals(_ intervals: [AnnotationInterval]) -> [AnnotationInterval] {
        let sorted = intervals.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        guard var current = sorted.first else { return [] }
        var result: [AnnotationInterval] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = AnnotationInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                result.append(current)
                current = interval
            }
        }
        result.append(current)
        return result
    }

    func safeQualifiers(_ source: [String: [String]]) -> [String: AnnotationQualifier] {
        let allowed: Set<String> = ["gene", "product", "note", "codon_start", "transl_table"]
        return source.reduce(into: [:]) { result, item in
            guard allowed.contains(item.key), !item.value.isEmpty else { return }
            result[item.key] = .init(item.value)
        }
    }

    func preferredReferenceTranslation(
        _ reference: ONTMHCReferenceVisualizationRecord
    ) -> String? {
        if let annotated = reference.annotatedTranslation?
            .filter({ !$0.isWhitespace }),
           annotated.count > 1,
           annotated.contains(where: { $0 != "X" && $0 != "x" && $0 != "*" }) {
            return annotated
        }
        let groups = Dictionary(grouping: reference.features.filter {
            AnnotationType.from(rawString: $0.type) == .cds
        }) {
            "\($0.sourceOrdinal)\u{0}\($0.strand)\u{0}\($0.rawGenBankLocation ?? "")"
        }.values.sorted {
            ($0.first?.sourceOrdinal ?? 0) < ($1.first?.sourceOrdinal ?? 0)
        }
        for group in groups {
            guard let feature = group.first else { continue }
            let unsortedIntervals: [AnnotationInterval] = group.map { item in
                AnnotationInterval(start: item.start, end: item.end)
            }
            let intervals = unsortedIntervals.sorted { lhs, rhs in
                lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
            }
            let annotation = SequenceAnnotation(
                type: .cds,
                name: reference.alleleName,
                intervals: intervals,
                strand: Strand(rawValue: feature.strand) ?? .unknown,
                qualifiers: safeQualifiers(feature.qualifiers)
            )
            if let translation = translatedCDS(annotation, sequence: reference.sequence) {
                return translation
            }
        }
        return nil
    }

    func translatedCDS(_ annotation: SequenceAnnotation, sequence: String) -> String? {
        let parts = annotation.intervals.sorted().compactMap { interval -> String? in
            guard interval.start >= 0, interval.end <= sequence.count else { return nil }
            let start = sequence.index(sequence.startIndex, offsetBy: interval.start)
            let end = sequence.index(sequence.startIndex, offsetBy: interval.end)
            return String(sequence[start..<end])
        }
        guard parts.count == annotation.intervals.count else { return nil }
        let coding = annotation.strand == .reverse
            ? TranslationEngine.reverseComplement(parts.joined())
            : parts.joined()
        let offset = annotation.qualifier("codon_start").flatMap(Int.init).map { max(0, min(2, $0 - 1)) } ?? 0
        var protein = TranslationEngine.translate(coding, offset: offset)
        if protein.last == "*" { protein.removeLast() }
        guard !protein.isEmpty else { return nil }
        return protein
    }

    func annotationLessThan(_ lhs: SequenceAnnotation, _ rhs: SequenceAnnotation) -> Bool {
        let order: [AnnotationType: Int] = [.source: 0, .gene: 1, .mRNA: 2, .transcript: 3, .exon: 4, .cds: 5]
        let left = order[lhs.type] ?? 10
        let right = order[rhs.type] ?? 10
        if left != right { return left < right }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.name < rhs.name
    }
}
