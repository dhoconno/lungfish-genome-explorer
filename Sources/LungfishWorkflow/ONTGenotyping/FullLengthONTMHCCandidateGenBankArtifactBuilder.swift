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

        var sequenceSHA256: String {
            switch self {
            case .candidate(let value): value.sequenceSHA256
            case .unnameable(let value): value.sequenceSHA256
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

        var subjectQualifiers: [String: AnnotationQualifier] {
            var values: [String: AnnotationQualifier] = [
                "stable_cluster_id": .init(stableClusterID),
                "support_class": .init(supportClass.rawValue),
                "independent_sample_count": .init(String(independentSampleCount)),
                "occurrence_count": .init(String(occurrenceCount)),
                "total_cluster_reads": .init(String(totalClusterReads)),
                "supporting_sample_ids": .init(supportingSampleIDs.sorted()),
                "sequence_sha256": .init(sequenceSHA256),
            ]
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

    func records(from inputs: [Input]) throws -> [GenBankRecord] {
        try inputs.sorted { $0.subject.stableClusterID < $1.subject.stableClusterID }
            .map(makeRecord)
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
        let queryLength: Int
        let isReverse: Bool
        let minimumIntronGapBases: Int

        func intervals(for feature: ONTMHCReferenceVisualizationFeature) -> [AnnotationInterval] {
            var positions = Set<Int>()
            for referencePosition in feature.start..<feature.end {
                guard let oriented = referenceToOrientedQuery[referencePosition] else { continue }
                positions.insert(candidatePosition(oriented))
            }
            for insertion in insertions where insertion.referenceBoundary > feature.start
                && insertion.referenceBoundary < feature.end
                && insertion.orientedQueryRange.count < minimumIntronGapBases {
                for oriented in insertion.orientedQueryRange {
                    positions.insert(candidatePosition(oriented))
                }
            }
            return mergedIntervals(positions.sorted())
        }

        func maps(referencePosition: Int) -> Bool {
            referenceToOrientedQuery[referencePosition] != nil
        }

        func coversEveryReferenceBase(of feature: ONTMHCReferenceVisualizationFeature) -> Bool {
            (feature.start..<feature.end).allSatisfy { referenceToOrientedQuery[$0] != nil }
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

    func makeRecord(_ input: Input) throws -> GenBankRecord {
        let stableID = input.subject.stableClusterID
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

        if let evidence = input.subject.selectedEvidence,
           let isReverse = input.selectedAlignmentIsReverse,
           let reference = input.closestReference {
            guard evidence.referenceName == reference.rawReferenceID else {
                throw Error.invalidInput(stableClusterID: stableID, detail: "selected reference does not match the visualization record")
            }
            let projection = try makeProjection(
                stableID: stableID,
                cigar: evidence.cigar,
                referenceStart: evidence.referenceStart,
                candidateSequence: sequence,
                referenceSequence: reference.sequence,
                isReverse: isReverse,
                minimumIntronGapBases: input.minimumIntronGapBases
            )
            let lifted = liftFeatures(
                reference.features,
                projection: projection,
                candidateSequence: sequence,
                defaultName: input.subject.displayName
            )
            translationStatus = lifted.translationStatus
            annotations.append(contentsOf: lifted.annotations)
            if input.subject.isCDNAReference,
               let cds = lifted.annotations.first(where: { $0.type == .cds }),
               let sourceCDS = reference.features.first(where: {
                   AnnotationType.from(rawString: $0.type) == .cds
               }),
               projection.coversEveryReferenceBase(of: sourceCDS),
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
                    projection: projection.changes,
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

        let recordFields = copiedRecordFields(input.closestReference)
            + comments.enumerated().map { GenBankRecordField(key: "COMMENT", value: $0.element, ordinal: recordFieldsBaseCount(input.closestReference) + $0.offset) }
        return GenBankRecord(
            sequence: try Sequence(name: stableID, description: input.subject.definition, alphabet: .dna, bases: sequence),
            annotations: annotations.sorted(by: annotationLessThan),
            locus: LocusInfo(name: stableID, length: sequence.count, moleculeType: .dna, topology: .linear),
            definition: input.subject.definition,
            accession: stableID,
            recordFields: recordFields
        )
    }

    func baseComments(_ input: Input) -> [String] {
        var values = [
            "Lungfish analysis: \(input.analysisName)",
            "Lungfish stable cluster ID: \(input.subject.stableClusterID)",
            "Lungfish sequence SHA-256: \(input.subject.sequenceSHA256)",
            "Lungfish support: \(input.subject.supportClass.rawValue); independent samples=\(input.subject.independentSampleCount); occurrences=\(input.subject.occurrenceCount); reads=\(input.subject.totalClusterReads)",
            "Lungfish supporting samples: \(input.subject.supportingSampleIDs.sorted().joined(separator: ", "))",
        ]
        if let project = input.projectBundleName, !project.isEmpty {
            values.insert("Lungfish project: \(project)", at: 1)
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
        minimumIntronGapBases: Int
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
        var queryCursor = 0
        var digits = ""
        var mapping: [Int: Int] = [:]
        var insertions: [Insertion] = []
        var events: [FullLengthONTMHCCandidateChangeProjection.Event] = []
        var assessedReferencePositions = Set<Int>()
        for character in cigar {
            if character.isNumber {
                digits.append(character)
                continue
            }
            guard let length = Int(digits), length > 0 else {
                throw Error.invalidCIGAR(stableClusterID: stableID, cigar: cigar)
            }
            digits = ""
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
        return Projection(
            referenceToOrientedQuery: mapping,
            insertions: insertions,
            changes: .init(
                events: events,
                assessedReferencePositions: assessedReferencePositions,
                queryLength: queryLength,
                isReverse: isReverse
            ),
            queryLength: queryLength,
            isReverse: isReverse,
            minimumIntronGapBases: minimumIntronGapBases
        )
    }

    func liftFeatures(
        _ features: [ONTMHCReferenceVisualizationFeature],
        projection: Projection,
        candidateSequence: String,
        defaultName: String
    ) -> (
        annotations: [SequenceAnnotation],
        hadSourceExons: Bool,
        translationStatus: FullLengthONTMHCTranslationStatus
    ) {
        let supported: Set<AnnotationType> = [.gene, .mRNA, .transcript, .exon, .cds, .utr5, .utr3]
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
                let hasBoundaryCoverage = group.allSatisfy {
                    projection.coversBoundaries(of: $0)
                }
                let hasTrustworthyAnnotation = sourceStrand != .unknown
                    && !group.contains(where: {
                        $0.rawGenBankLocation?.contains("<") == true
                            || $0.rawGenBankLocation?.contains(">") == true
                    })
                    && (annotation.qualifier("codon_start").map { $0 == "1" } ?? true)
                if projection.maps(referencePosition: fivePrimeReferencePosition),
                   let translation = translatedCDS(annotation, sequence: candidateSequence) {
                    annotation.qualifiers["translation"] = .init(translation)
                    cdsStatuses.append(
                        translationStatus(
                            annotation: annotation,
                            translation: translation,
                            hasBoundaryCoverage: hasBoundaryCoverage,
                            hasTrustworthyAnnotation: hasTrustworthyAnnotation
                        )
                    )
                } else {
                    cdsStatuses.append(.incompleteUnresolved)
                    let existingNotes = annotation.qualifiers["note"]?.values ?? []
                    annotation.qualifiers["note"] = .init(
                        existingNotes + ["Candidate translation omitted because the 5-prime CDS boundary is not aligned"]
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
        hasBoundaryCoverage: Bool,
        hasTrustworthyAnnotation: Bool
    ) -> FullLengthONTMHCTranslationStatus {
        guard hasBoundaryCoverage,
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
