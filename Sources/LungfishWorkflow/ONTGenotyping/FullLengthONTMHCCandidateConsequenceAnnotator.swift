import Foundation
import LungfishCore
import LungfishIO

struct FullLengthONTMHCCandidateChangeProjection: Sendable {
    enum Event: Sendable {
        case substitution(referencePosition: Int, orientedQueryPosition: Int, referenceBase: Character, alternateBase: Character)
        case insertion(referenceBoundary: Int, orientedQueryRange: Range<Int>, bases: String)
        case deletion(referenceRange: Range<Int>, orientedQueryBoundary: Int, bases: String)
        case skipped(referenceRange: Range<Int>)
    }

    let events: [Event]
    let assessedReferencePositions: Set<Int>
    let queryLength: Int
    let isReverse: Bool
    let storedCoordinateOffset: Int
    let storedCoordinateLength: Int?

    init(
        events: [Event],
        assessedReferencePositions: Set<Int>,
        queryLength: Int,
        isReverse: Bool,
        storedCoordinateOffset: Int = 0,
        storedCoordinateLength: Int? = nil
    ) {
        self.events = events
        self.assessedReferencePositions = assessedReferencePositions
        self.queryLength = queryLength
        self.isReverse = isReverse
        self.storedCoordinateOffset = storedCoordinateOffset
        self.storedCoordinateLength = storedCoordinateLength
    }

    func rebasedStoredCoordinates(by offset: Int, length: Int) -> Self {
        .init(
            events: events,
            assessedReferencePositions: assessedReferencePositions,
            queryLength: queryLength,
            isReverse: isReverse,
            storedCoordinateOffset: offset,
            storedCoordinateLength: length
        )
    }

    func storedCandidatePosition(orientedPosition: Int) -> Int {
        (isReverse ? queryLength - orientedPosition - 1 : orientedPosition) - storedCoordinateOffset
    }

    func storedCandidateRange(orientedRange: Range<Int>) -> Range<Int> {
        let range = isReverse
            ? (queryLength - orientedRange.upperBound)..<(queryLength - orientedRange.lowerBound)
            : orientedRange
        return (range.lowerBound - storedCoordinateOffset)..<(range.upperBound - storedCoordinateOffset)
    }

    func storedCandidateBoundary(orientedBoundary: Int) -> Int {
        (isReverse ? queryLength - orientedBoundary : orientedBoundary) - storedCoordinateOffset
    }

    func storedCandidatePositionInOrigin(orientedPosition: Int) -> Int? {
        let position = storedCandidatePosition(orientedPosition: orientedPosition)
        guard position >= 0,
              storedCoordinateLength.map({ position < $0 }) ?? true else { return nil }
        return position
    }

    func storedCandidateRangeInOrigin(orientedRange: Range<Int>) -> Range<Int>? {
        let range = storedCandidateRange(orientedRange: orientedRange)
        guard range.lowerBound >= 0,
              storedCoordinateLength.map({ range.upperBound <= $0 }) ?? true else { return nil }
        return range
    }
}

struct FullLengthONTMHCCandidateConsequenceAnnotator {
    static let summaryPrefixes = [
        "Lungfish exon 2/3 nonsynonymous changes:",
        "Lungfish CDS nonsynonymous changes:",
        "Lungfish CDS synonymous changes:",
        "Lungfish intronic changes:",
    ]

    struct Input: Sendable {
        let reference: ONTMHCReferenceVisualizationRecord
        let projection: FullLengthONTMHCCandidateChangeProjection
        let isCDNAReference: Bool
        let minimumIntronGapBases: Int
        let candidateTranslation: String?
        let referenceTranslation: String?
        let translationStatus: FullLengthONTMHCTranslationStatus
    }

    func comments(for input: Input) -> [String] {
        let coordinateComment = "Lungfish consequence coordinate convention: reference, stored candidate ORIGIN, CDS nucleotide, codon, exon, intron, and amino-acid coordinates are 1-based; insertion/deletion boundaries are reported between flanking coordinates; terminal changes outside cropped ORIGIN are reference-only"
        guard let cds = primaryCDS(input.reference) else {
            return unavailable(reason: "no annotated CDS") + [coordinateComment]
        }
        guard cds.strand != .unknown else {
            return unavailable(reason: "annotated CDS strand is unknown") + [coordinateComment]
        }
        if let issue = cds.semanticIssue {
            return unavailable(reason: issue) + [coordinateComment]
        }
        guard cds.translationTable == 1 else {
            return unavailable(reason: "translation table \(cds.translationTable) is unsupported") + [coordinateComment]
        }

        let cdsMap = makeCDSMap(cds, sequence: input.reference.sequence)
        guard !cdsMap.transcriptBases.isEmpty else {
            return unavailable(reason: "annotated CDS could not be resolved") + [coordinateComment]
        }
        let exonRegions = exons(input.reference, strand: cds.strand)
        let intronRegions = introns(input.reference, exons: exonRegions, strand: cds.strand)
        let nonCDSExonicPositions = Set(input.reference.features.filter {
            let type = AnnotationType.from(rawString: $0.type)
            return type == .exon || type == .utr5 || type == .utr3
        }.flatMap { feature in
            feature.interval.filter { cdsMap.indexByReferencePosition[$0] == nil }
        })
        let annotationIsPartial = cds.isPartial
        let ambiguousReferencePositions = zip(cdsMap.referencePositions, cdsMap.transcriptBases)
            .compactMap { position, base in isCanonicalDNA(base) ? nil : position }
            .sorted()
        let translationIsResolved = input.translationStatus != .incompleteUnresolved
        let cdsComplete = !annotationIsPartial
            && translationIsResolved
            && ambiguousReferencePositions.isEmpty
            && Set(cdsMap.referencePositions).isSubset(of: input.projection.assessedReferencePositions)
        let exon23Positions = Set(exonRegions.filter { $0.number == 2 || $0.number == 3 }.flatMap { $0.range })
        let exon23Complete = !exon23Positions.isEmpty
            && !annotationIsPartial
            && exon23Positions.isDisjoint(with: ambiguousReferencePositions)
            && exon23Positions.isSubset(of: input.projection.assessedReferencePositions)
        let intronPositions = Set(intronRegions.flatMap { $0.range })
        let intronsComplete = !intronPositions.isEmpty
            && intronPositions.isSubset(of: input.projection.assessedReferencePositions)

        var substitutionGroups: [Int: [Substitution]] = [:]
        var unresolvedCoding: [UnresolvedCoding] = []
        var codingIndels: [CodingIndel] = []
        var intronicDetails: [RawDetail] = []
        var intronFills: [RawDetail] = []
        var unclassifiedDetails: [RawDetail] = []

        if !ambiguousReferencePositions.isEmpty {
            unresolvedCoding.append(unresolvedDetail(
                "ambiguous reference/candidate CDS bases at ref "
                    + ambiguousReferencePositions.map { String($0 + 1) }.joined(separator: ",")
                    + "; "
                    + (input.candidateTranslation?.uppercased().contains("X") == true
                        ? "candidate translation contains X"
                        : "candidate translation status is \(input.translationStatus.rawValue)")
                    + "; protein effect unresolved",
                referencePositions: ambiguousReferencePositions,
                exonRegions: exonRegions
            ))
        }

        for event in input.projection.events {
            switch event {
            case .substitution(let refPosition, let queryPosition, let refBase, let altBase):
                if let cdsIndex = cdsMap.indexByReferencePosition[refPosition] {
                    if cds.isPartial {
                        let storedCandidatePosition = input.projection.storedCandidatePosition(
                            orientedPosition: queryPosition
                        )
                        let exonNumber = regionNumber(at: refPosition, in: exonRegions)
                        unresolvedCoding.append(unresolvedDetail(
                            "ref \(refPosition + 1) \(refBase)>\(altBase); candidate \(storedCandidatePosition + 1)"
                                + (exonNumber.map { "; exon \($0)" } ?? "")
                                + "; partial CDS annotation; protein effect unresolved",
                            referencePositions: [refPosition],
                            exonNumbers: exonNumber.map { [$0] } ?? [],
                            exonRegions: exonRegions
                        ))
                        continue
                    }
                    guard cdsIndex >= cds.codonOffset else {
                        unresolvedCoding.append(unresolvedDetail(
                            "ref \(refPosition + 1) \(refBase)>\(altBase); before first complete annotated codon",
                            referencePositions: [refPosition],
                            exonRegions: exonRegions
                        ))
                        continue
                    }
                    let codingIndex = cdsIndex - cds.codonOffset
                    substitutionGroups[codingIndex / 3, default: []].append(.init(
                        referencePosition: refPosition,
                        storedCandidatePosition: input.projection.storedCandidatePosition(orientedPosition: queryPosition),
                        referenceBase: refBase,
                        alternateBase: altBase,
                        cdsIndex: cdsIndex,
                        exonNumber: regionNumber(at: refPosition, in: exonRegions)
                    ))
                } else if let intronNumber = regionNumber(at: refPosition, in: intronRegions) {
                    intronicDetails.append(.init(
                        sortPosition: refPosition,
                        text: "ref \(refPosition + 1) \(refBase)>\(altBase); candidate \(input.projection.storedCandidatePosition(orientedPosition: queryPosition) + 1); intron \(intronNumber); direct CDS translation effect none; splice/regulatory impact not assessed"
                    ))
                } else {
                    let candidate = input.projection.storedCandidatePositionInOrigin(
                        orientedPosition: queryPosition
                    ).map { "candidate \($0 + 1)" } ?? "outside cropped candidate ORIGIN"
                    unclassifiedDetails.append(.init(
                        sortPosition: refPosition,
                        text: "ref \(refPosition + 1) \(refBase)>\(altBase); \(candidate); \(nonCDSExonicPositions.contains(refPosition) ? "non-CDS exonic/UTR" : "outside classified CDS/intron features"); protein effect not applicable"
                    ))
                }
            case .insertion(let boundary, let queryRange, let bases):
                if input.isCDNAReference,
                   bases.count >= input.minimumIntronGapBases,
                   isInternal(boundary: boundary, in: cds.intervals),
                   hasAssessedFlanks(boundary: boundary, positions: input.projection.assessedReferencePositions) {
                    let stored = input.projection.storedCandidateRange(orientedRange: queryRange)
                    intronFills.append(.init(
                        sortPosition: boundary,
                        text: "ref boundary \(boundary)/\(boundary + 1); candidate \(stored.lowerBound + 1)-\(stored.upperBound); \(bases.count) bp insertion; closest cDNA contains no homologous intron sequence; splice impact not assessed"
                    ))
                } else if isInternal(boundary: boundary, in: cds.intervals) {
                    let stored = input.projection.storedCandidateRange(orientedRange: queryRange)
                    if cds.isPartial {
                        let exonNumber = regionNumber(atBoundary: boundary, in: exonRegions)
                        unresolvedCoding.append(unresolvedDetail(
                            "\(bases.count) bp insertion at ref boundary \(boundary)/\(boundary + 1); candidate \(stored.lowerBound + 1)-\(stored.upperBound); partial CDS annotation; protein effect unresolved",
                            exonNumbers: exonNumber.map { [$0] } ?? [],
                            exonRegions: exonRegions
                        ))
                    } else {
                        codingIndels.append(.init(
                            sortPosition: boundary,
                            referenceBounds: boundary...boundary,
                            exonNumber: regionNumber(atBoundary: boundary, in: exonRegions),
                            lengthDelta: bases.count,
                            text: "\(bases.count) bp insertion at ref boundary \(boundary)/\(boundary + 1); candidate \(stored.lowerBound + 1)-\(stored.upperBound); inserted \(bases)"
                        ))
                    }
                } else if let intronNumber = regionNumber(atBoundary: boundary, in: intronRegions) {
                    let stored = input.projection.storedCandidateRange(orientedRange: queryRange)
                    intronicDetails.append(.init(
                        sortPosition: boundary,
                        text: "\(bases.count) bp insertion at ref boundary \(boundary)/\(boundary + 1); candidate \(stored.lowerBound + 1)-\(stored.upperBound); inserted \(bases); intron \(intronNumber); direct CDS translation effect none; splice/regulatory impact not assessed"
                    ))
                } else {
                    let candidate = input.projection.storedCandidateRangeInOrigin(
                        orientedRange: queryRange
                    ).map { "candidate \($0.lowerBound + 1)-\($0.upperBound)" }
                        ?? "outside cropped candidate ORIGIN"
                    unclassifiedDetails.append(.init(
                        sortPosition: boundary,
                        text: "\(bases.count) bp insertion at ref boundary \(boundary)/\(boundary + 1); \(candidate); outside classified CDS/intron features; protein effect unresolved"
                    ))
                }
            case .deletion(let range, let queryBoundary, let bases):
                let codingPositions = range.filter { cdsMap.indexByReferencePosition[$0] != nil }
                if !codingPositions.isEmpty {
                    let boundary = input.projection.storedCandidateBoundary(orientedBoundary: queryBoundary)
                    if cds.isPartial {
                        unresolvedCoding.append(unresolvedDetail(
                            "\(codingPositions.count) bp deletion at ref \(range.lowerBound + 1)-\(range.upperBound) (\(bases)); candidate boundary \(boundary)/\(boundary + 1); partial CDS annotation; protein effect unresolved",
                            referencePositions: codingPositions,
                            exonRegions: exonRegions
                        ))
                    } else {
                        codingIndels.append(.init(
                            sortPosition: range.lowerBound,
                            referenceBounds: range.lowerBound...range.upperBound,
                            exonNumber: regionNumber(at: codingPositions[0], in: exonRegions),
                            lengthDelta: -codingPositions.count,
                            text: "\(codingPositions.count) bp deletion at ref \(range.lowerBound + 1)-\(range.upperBound) (\(bases)); candidate boundary \(boundary)/\(boundary + 1)"
                        ))
                    }
                }
                for region in intronRegions {
                    let overlap = max(range.lowerBound, region.range.lowerBound)..<min(range.upperBound, region.range.upperBound)
                    guard !overlap.isEmpty else { continue }
                    intronicDetails.append(.init(
                        sortPosition: overlap.lowerBound,
                        text: "\(overlap.count) bp deletion at ref \(overlap.lowerBound + 1)-\(overlap.upperBound); intron \(region.number); direct CDS translation effect none; splice/regulatory impact not assessed"
                    ))
                }
                let classified = Set(codingPositions).union(intronRegions.flatMap { region in
                    range.filter { region.range.contains($0) }
                })
                let other = range.filter { !classified.contains($0) }
                if let first = other.first {
                    unclassifiedDetails.append(.init(
                        sortPosition: first,
                        text: "\(other.count) bp deletion including ref \(first + 1); \(other.allSatisfy { nonCDSExonicPositions.contains($0) } ? "non-CDS exonic/UTR" : "outside classified CDS/intron features"); protein effect not applicable or unresolved"
                    ))
                }
            case .skipped(let range):
                let skippedCodingPositions = range.filter { cdsMap.indexByReferencePosition[$0] != nil }
                if !skippedCodingPositions.isEmpty {
                    unresolvedCoding.append(unresolvedDetail(
                        "ref \(range.lowerBound + 1)-\(range.upperBound) skipped by CIGAR N; protein effect unresolved",
                        referencePositions: skippedCodingPositions,
                        exonRegions: exonRegions
                    ))
                } else {
                    unclassifiedDetails.append(.init(
                        sortPosition: range.lowerBound,
                        text: "ref \(range.lowerBound + 1)-\(range.upperBound) skipped by CIGAR N; region unassessed"
                    ))
                }
            }
        }

        var nonsynonymous: [Detail] = []
        var synonymous: [Detail] = []
        for codonIndex in substitutionGroups.keys.sorted() {
            guard let changes = substitutionGroups[codonIndex]?.sorted(by: { $0.referencePosition < $1.referencePosition }) else { continue }
            let codonStart = cds.codonOffset + codonIndex * 3
            guard codonStart + 3 <= cdsMap.transcriptBases.count else {
                unresolvedCoding.append(unresolvedDetail(
                    changes.map(changeDescription).joined(separator: ", ") + "; incomplete codon",
                    referencePositions: changes.map(\.referencePosition),
                    exonNumbers: changes.compactMap(\.exonNumber),
                    exonRegions: exonRegions
                ))
                continue
            }
            let referenceCodon = String(cdsMap.transcriptBases[codonStart..<(codonStart + 3)])
            var alternate = Array(referenceCodon)
            for change in changes {
                let withinCodon = change.cdsIndex - codonStart
                alternate[withinCodon] = cds.strand == .reverse
                    ? complemented(change.alternateBase)
                    : change.alternateBase
            }
            let alternateCodon = String(alternate)
            guard referenceCodon.allSatisfy(isCanonicalDNA),
                  alternateCodon.allSatisfy(isCanonicalDNA) else {
                if referenceCodon.allSatisfy(isCanonicalDNA) {
                    unresolvedCoding.append(unresolvedDetail(
                        changes.map(changeDescription).joined(separator: ", ")
                            + "; ref codon \(referenceCodon)>\(alternateCodon); ambiguous candidate codon; protein effect unresolved",
                        referencePositions: changes.map(\.referencePosition),
                        exonNumbers: changes.compactMap(\.exonNumber),
                        exonRegions: exonRegions
                    ))
                }
                continue
            }
            let referenceAA = TranslationEngine.translate(referenceCodon)
            let alternateAA = TranslationEngine.translate(alternateCodon)
            guard referenceAA.count == 1, alternateAA.count == 1,
                  !referenceAA.contains("X"), !alternateAA.contains("X") else {
                unresolvedCoding.append(unresolvedDetail(
                    changes.map(changeDescription).joined(separator: ", ")
                        + "; ref codon \(referenceCodon)>\(alternateCodon); ambiguous translation",
                    referencePositions: changes.map(\.referencePosition),
                    exonNumbers: changes.compactMap(\.exonNumber),
                    exonRegions: exonRegions
                ))
                continue
            }
            let aaPosition = codonIndex + 1
            let effect: String
            if referenceAA == alternateAA { effect = "synonymous" }
            else if alternateAA == "*" { effect = "stop-gained" }
            else if referenceAA == "*" { effect = "stop-lost" }
            else { effect = "missense" }
            let exonNumbers = Array(Set(changes.compactMap(\.exonNumber))).sorted()
            let detail = Detail(
                sortPosition: changes.map(\.referencePosition).min() ?? 0,
                exonNumbers: exonNumbers,
                text: changes.map(changeDescription).joined(separator: ", ")
                    + "; CDS nt \(changes.map { $0.cdsIndex + 1 }.sorted().map(String.init).joined(separator: ","))"
                    + "; codon \(aaPosition); amino acid \(aaPosition)"
                    + (exonNumbers.isEmpty ? "" : "; exon \(exonNumbers.map(String.init).joined(separator: ","))")
                    + "; ref codon \(referenceCodon)>\(alternateCodon); p.\(referenceAA)\(aaPosition)\(referenceAA == alternateAA ? "=" : alternateAA); \(effect)"
            )
            if referenceAA == alternateAA { synonymous.append(detail) }
            else { nonsynonymous.append(detail) }
        }

        for group in adjacentIndelGroups(codingIndels) {
            let netDelta = group.reduce(0) { $0 + $1.lengthDelta }
            let frameEffect = abs(netDelta).isMultiple(of: 3) ? "frame-preserving" : "frame-disrupting"
            let product = productSummary(input)
            let exonNumbers = Array(Set(group.compactMap(\.exonNumber))).sorted()
            nonsynonymous.append(.init(
                sortPosition: group.map(\.sortPosition).min() ?? 0,
                exonNumbers: exonNumbers,
                text: group.map(\.text).joined(separator: "; combined with ")
                    + (exonNumbers.isEmpty ? "" : "; exon \(exonNumbers.map(String.init).joined(separator: ","))")
                    + "; net \(netDelta) bp; \(frameEffect); predicted product \(product)"
            ))
        }
        if input.translationStatus == .incompleteUnresolved && unresolvedCoding.isEmpty {
            unresolvedCoding.append(unresolvedDetail(
                "candidate translation status is incomplete/unresolved; definitive coding consequence classification unavailable",
                exonRegions: exonRegions
            ))
        }
        nonsynonymous.sort { $0.sortPosition < $1.sortPosition }
        synonymous.sort { $0.sortPosition < $1.sortPosition }

        var details: [String] = []
        let nsIDs = nonsynonymous.indices.map { "CDS-NS-\($0 + 1)" }
        let synIDs = synonymous.indices.map { "CDS-SYN-\($0 + 1)" }
        let exon23IDs = nonsynonymous.indices.compactMap { index in
            nonsynonymous[index].exonNumbers.contains(where: { $0 == 2 || $0 == 3 }) ? nsIDs[index] : nil
        }
        details += zip(nsIDs, nonsynonymous).map { "\($0): \($1.text)" }
        details += zip(synIDs, synonymous).map { "\($0): \($1.text)" }
        let unresolvedIDs = unresolvedCoding.indices.map { "CDS-UNRESOLVED-\($0 + 1)" }
        let exon23UnresolvedIDs = unresolvedCoding.indices.compactMap { index in
            unresolvedCoding[index].affects(
                referencePositions: exon23Positions,
                exonNumbers: [2, 3]
            ) ? unresolvedIDs[index] : nil
        }
        details += zip(unresolvedIDs, unresolvedCoding).map { "\($0): \($1.text)" }

        let ordinaryIntrons = intronicDetails.sorted { $0.sortPosition < $1.sortPosition }
        let intronIDs = ordinaryIntrons.indices.map { "INTRON-\($0 + 1)" }
        let fillIDs = intronFills.indices.map { "INTRON-FILL-\($0 + 1)" }
        details += zip(intronIDs, ordinaryIntrons).map { "\($0): \($1.text)" }
        details += zip(fillIDs, intronFills).map { "\($0): \($1.text)" }
        let unclassified = unclassifiedDetails.sorted { $0.sortPosition < $1.sortPosition }
        details += unclassified.enumerated().map { "UNCLASSIFIED-\($0.offset + 1): \($0.element.text)" }

        let exon23Summary = summary(
            prefix: Self.summaryPrefixes[0], identifiers: exon23IDs,
            unresolved: exon23UnresolvedIDs,
            complete: exon23Complete,
            unavailableReason: exon23Positions.isEmpty ? "exon 2/3 annotations are unavailable" : nil
        )
        let nonsynSummary = summary(prefix: Self.summaryPrefixes[1], identifiers: nsIDs, unresolved: unresolvedIDs, complete: cdsComplete)
        let synSummary = summary(prefix: Self.summaryPrefixes[2], identifiers: synIDs, unresolved: unresolvedIDs, complete: cdsComplete)
        let allIntronIDs = intronIDs + fillIDs
        let intronSummary = summary(
            prefix: Self.summaryPrefixes[3], identifiers: allIntronIDs, unresolved: [],
            complete: intronsComplete || (!fillIDs.isEmpty && input.isCDNAReference),
            unavailableReason: intronRegions.isEmpty && fillIDs.isEmpty ? "no annotated or inferable introns" : nil
        )
        return [exon23Summary, nonsynSummary, synSummary, intronSummary] + details + [coordinateComment]
    }
}

private extension FullLengthONTMHCCandidateConsequenceAnnotator {
    struct CDS {
        let intervals: [Range<Int>]
        let strand: Strand
        let codonOffset: Int
        let translationTable: Int
        let isPartial: Bool
        let semanticIssue: String?
    }
    struct CDSMap {
        let referencePositions: [Int]
        let transcriptBases: [Character]
        let indexByReferencePosition: [Int: Int]
    }
    struct Region { let range: Range<Int>; let number: Int }
    struct Substitution {
        let referencePosition: Int
        let storedCandidatePosition: Int
        let referenceBase: Character
        let alternateBase: Character
        let cdsIndex: Int
        let exonNumber: Int?
    }
    struct Detail { let sortPosition: Int; let exonNumbers: [Int]; let text: String }
    struct RawDetail { let sortPosition: Int; let text: String }
    struct UnresolvedCoding {
        let referencePositions: Set<Int>?
        let exonNumbers: Set<Int>
        let text: String

        func affects(referencePositions targetPositions: Set<Int>, exonNumbers targetExons: Set<Int>) -> Bool {
            if let referencePositions, !referencePositions.isDisjoint(with: targetPositions) { return true }
            if !exonNumbers.isDisjoint(with: targetExons) { return true }
            return referencePositions == nil && exonNumbers.isEmpty
        }
    }
    struct CodingIndel {
        let sortPosition: Int
        let referenceBounds: ClosedRange<Int>
        let exonNumber: Int?
        let lengthDelta: Int
        let text: String
    }

    func unavailable(reason: String) -> [String] {
        Self.summaryPrefixes.map { "\($0) unavailable: \(reason)" }
    }

    func unresolvedDetail(
        _ text: String,
        referencePositions: [Int]? = nil,
        exonNumbers: [Int] = [],
        exonRegions: [Region]
    ) -> UnresolvedCoding {
        let derivedExons = (referencePositions ?? []).compactMap {
            regionNumber(at: $0, in: exonRegions)
        }
        return .init(
            referencePositions: referencePositions.map(Set.init),
            exonNumbers: Set(exonNumbers + derivedExons),
            text: text
        )
    }

    func primaryCDS(_ reference: ONTMHCReferenceVisualizationRecord) -> CDS? {
        let features = reference.features.filter { AnnotationType.from(rawString: $0.type) == .cds }
        guard !features.isEmpty else { return nil }
        let groups = Dictionary(grouping: features) {
            "\($0.sourceOrdinal)\u{0}\($0.strand)\u{0}\($0.rawGenBankLocation ?? "")"
        }.values.sorted { ($0.first?.sourceOrdinal ?? 0) < ($1.first?.sourceOrdinal ?? 0) }
        guard let group = groups.first, let first = group.first else { return nil }
        let strand = Strand(rawValue: first.strand) ?? .unknown
        let codonStartText = first.qualifiers["codon_start"]?.first
        let tableText = first.qualifiers["transl_table"]?.first
        let codonStart = codonStartText.flatMap(Int.init) ?? 1
        let table = tableText.flatMap(Int.init) ?? 1
        let semanticIssue: String?
        if codonStartText != nil && (!(1...3).contains(codonStart) || Int(codonStartText!) == nil) {
            semanticIssue = "codon_start \(codonStartText!) is invalid"
        } else if tableText != nil && Int(tableText!) == nil {
            semanticIssue = "translation table \(tableText!) is invalid"
        } else {
            semanticIssue = nil
        }
        return CDS(
            intervals: group.map { $0.start..<$0.end }.sorted { $0.lowerBound < $1.lowerBound },
            strand: strand,
            codonOffset: max(0, min(2, codonStart - 1)),
            translationTable: table,
            isPartial: group.contains { $0.rawGenBankLocation?.contains("<") == true || $0.rawGenBankLocation?.contains(">") == true },
            semanticIssue: semanticIssue
        )
    }

    func makeCDSMap(_ cds: CDS, sequence: String) -> CDSMap {
        let chars = Array(sequence.uppercased())
        let positions: [Int] = cds.strand == .reverse
            ? cds.intervals.reversed().flatMap { Array($0.reversed()) }
            : cds.intervals.flatMap { Array($0) }
        let bases = positions.map { position in
            cds.strand == .reverse ? complemented(chars[position]) : chars[position]
        }
        return CDSMap(
            referencePositions: positions,
            transcriptBases: bases,
            indexByReferencePosition: Dictionary(uniqueKeysWithValues: positions.enumerated().map { ($0.element, $0.offset) })
        )
    }

    func exons(_ reference: ONTMHCReferenceVisualizationRecord, strand: Strand) -> [Region] {
        let features = reference.features.filter { AnnotationType.from(rawString: $0.type) == .exon }
        let sorted = features.sorted {
            strand == .reverse ? $0.start > $1.start : $0.start < $1.start
        }
        return sorted.enumerated().map { index, feature in
            Region(range: feature.start..<feature.end, number: feature.qualifiers["number"]?.first.flatMap(Int.init) ?? index + 1)
        }
    }

    func introns(_ reference: ONTMHCReferenceVisualizationRecord, exons: [Region], strand: Strand) -> [Region] {
        let explicit = reference.features.filter { AnnotationType.from(rawString: $0.type) == .intron }
        if !explicit.isEmpty {
            return explicit.sorted { strand == .reverse ? $0.start > $1.start : $0.start < $1.start }
                .enumerated().map { index, feature in
                    Region(range: feature.start..<feature.end, number: feature.qualifiers["number"]?.first.flatMap(Int.init) ?? index + 1)
                }
        }
        let genomicExons = exons.sorted { $0.range.lowerBound < $1.range.lowerBound }
        let geneRanges = reference.features.filter {
            AnnotationType.from(rawString: $0.type) == .gene
        }.map(\.interval)
        guard geneRanges.contains(where: { gene in
            genomicExons.allSatisfy {
                gene.lowerBound <= $0.range.lowerBound && gene.upperBound >= $0.range.upperBound
            }
        }) else { return [] }
        return zip(genomicExons, genomicExons.dropFirst()).enumerated().compactMap { index, pair in
            guard pair.0.range.upperBound < pair.1.range.lowerBound else { return nil }
            let inferredNumber = strand == .reverse ? genomicExons.count - index - 1 : index + 1
            return Region(range: pair.0.range.upperBound..<pair.1.range.lowerBound, number: inferredNumber)
        }.sorted { strand == .reverse ? $0.range.lowerBound > $1.range.lowerBound : $0.range.lowerBound < $1.range.lowerBound }
    }

    func regionNumber(at position: Int, in regions: [Region]) -> Int? {
        regions.first { $0.range.contains(position) }?.number
    }

    func regionNumber(atBoundary boundary: Int, in regions: [Region]) -> Int? {
        regions.first { boundary > $0.range.lowerBound && boundary < $0.range.upperBound }?.number
    }

    func isInternal(boundary: Int, in intervals: [Range<Int>]) -> Bool {
        intervals.contains { boundary > $0.lowerBound && boundary < $0.upperBound }
    }

    func hasAssessedFlanks(boundary: Int, positions: Set<Int>) -> Bool {
        positions.contains(where: { $0 < boundary }) && positions.contains(where: { $0 >= boundary })
    }

    func complemented(_ base: Character) -> Character {
        Character(TranslationEngine.reverseComplement(String(base)).uppercased())
    }

    func isCanonicalDNA(_ base: Character) -> Bool {
        base == "A" || base == "C" || base == "G" || base == "T"
    }

    func changeDescription(_ change: Substitution) -> String {
        "ref \(change.referencePosition + 1) \(change.referenceBase)>\(change.alternateBase); candidate \(change.storedCandidatePosition + 1)"
    }

    func productSummary(_ input: Input) -> String {
        let candidateLength = input.candidateTranslation?.filter { $0 != "*" }.count
        let referenceLength = input.referenceTranslation?.filter { $0 != "*" }.count
        let stops = input.candidateTranslation?.filter { $0 == "*" }.count
        return "status=\(input.translationStatus.rawValue), candidate amino acids=\(candidateLength.map(String.init) ?? "unavailable"), closest-reference amino acids=\(referenceLength.map(String.init) ?? "unavailable"), internal stops=\(stops.map(String.init) ?? "unavailable")"
    }

    func adjacentIndelGroups(_ indels: [CodingIndel]) -> [[CodingIndel]] {
        var groups: [[CodingIndel]] = []
        let sorted = indels.sorted {
            $0.referenceBounds.lowerBound == $1.referenceBounds.lowerBound
                ? $0.referenceBounds.upperBound < $1.referenceBounds.upperBound
                : $0.referenceBounds.lowerBound < $1.referenceBounds.lowerBound
        }
        for indel in sorted {
            let groupUpperBound = groups.last?.map(\.referenceBounds.upperBound).max()
            if let groupUpperBound,
               indel.referenceBounds.lowerBound <= groupUpperBound {
                groups[groups.count - 1].append(indel)
            } else {
                groups.append([indel])
            }
        }
        return groups
    }

    func summary(
        prefix: String,
        identifiers: [String],
        unresolved: [String],
        complete: Bool,
        unavailableReason: String? = nil
    ) -> String {
        if !identifiers.isEmpty { return "\(prefix) \(identifiers.joined(separator: ", "))" }
        if let unavailableReason { return "\(prefix) unavailable: \(unavailableReason)" }
        if !unresolved.isEmpty { return "\(prefix) unresolved: \(unresolved.joined(separator: ", "))" }
        return "\(prefix) none detected in \(complete ? "complete annotated region" : "aligned portion (partial coverage)")"
    }
}
