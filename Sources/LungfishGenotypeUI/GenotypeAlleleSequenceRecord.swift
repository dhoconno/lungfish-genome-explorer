import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

struct GenotypeAlleleSequenceRecord: Equatable {
    let identity: String
    let displayName: String
    let genBankText: String
    let fastaText: String
    let emblText: String

    enum CatalogError: Error, Equatable {
        case missingCandidateGenBankArtifact
        case duplicateCandidateAccession(String)
        case duplicateStableClusterID(String)
        case missingCandidateAccession(String)
        case candidateAccessionNotFound(String)
        case candidateSequenceChecksumMismatch(
            accession: String,
            expected: String,
            actual: String
        )
    }

    static func known(_ source: ONTMHCReferenceVisualizationRecord) -> Self {
        Self(
            identity: source.rawReferenceID,
            displayName: source.alleleName,
            genBankText: normalizedTrailingNewline(source.genBankText),
            fastaText: normalizedTrailingNewline(source.fastaText),
            emblText: EMBLFormatter.format(
                identity: source.rawReferenceID,
                definition: firstRecordValue("DEFINITION", in: source.recordFields),
                moleculeType: firstRecordValue("LOCUS.MOLECULE_TYPE", in: source.recordFields),
                source: firstRecordValue("SOURCE", in: source.recordFields),
                organism: firstRecordValue("ORGANISM", in: source.recordFields),
                taxonomy: firstRecordValue("TAXONOMY", in: source.recordFields),
                comments: recordValues("COMMENT", in: source.recordFields),
                features: source.features
                    .sorted { $0.sourceOrdinal < $1.sourceOrdinal }
                    .map(EMBLFeature.init),
                sequence: source.sequence
            )
        )
    }

    static func candidateCatalog(
        candidates: [ONTMHCCandidateRecord],
        genBankURL: URL?
    ) throws -> [String: Self] {
        guard !candidates.isEmpty else { return [:] }
        guard let genBankURL else {
            throw CatalogError.missingCandidateGenBankArtifact
        }

        var stableClusterIDs: Set<String> = []
        var candidateAccessions: Set<String> = []
        for candidate in candidates {
            guard stableClusterIDs.insert(candidate.stableClusterID).inserted else {
                throw CatalogError.duplicateStableClusterID(candidate.stableClusterID)
            }
            guard candidateAccessions.insert(candidate.fastaRecordID).inserted else {
                throw CatalogError.duplicateCandidateAccession(candidate.fastaRecordID)
            }
        }

        // The complete validated artifact is parsed in one pass and indexed in memory.
        let records = try GenBankReader(url: genBankURL).readAllSync()
        var recordsByAccession: [String: GenBankRecord] = [:]
        for record in records {
            guard let accession = record.accession, !accession.isEmpty else {
                throw CatalogError.missingCandidateAccession(record.locus.name)
            }
            guard recordsByAccession[accession] == nil else {
                throw CatalogError.duplicateCandidateAccession(accession)
            }
            recordsByAccession[accession] = record
        }

        var result: [String: Self] = [:]
        for candidate in candidates {
            guard let record = recordsByAccession[candidate.fastaRecordID] else {
                throw CatalogError.candidateAccessionNotFound(candidate.fastaRecordID)
            }
            result[candidate.stableClusterID] = try candidateRecord(
                candidate: candidate,
                record: record
            )
        }
        return result
    }

    static func candidateCatalogRetainingValidRecords(
        candidates: [ONTMHCCandidateRecord],
        genBankURL: URL?
    ) -> [String: Self] {
        guard !candidates.isEmpty, let genBankURL,
              let records = try? GenBankReader(url: genBankURL).readAllSync() else {
            return [:]
        }
        let stableIDCounts = Dictionary(grouping: candidates, by: \.stableClusterID)
            .mapValues(\.count)
        let candidateAccessionCounts = Dictionary(grouping: candidates, by: \.fastaRecordID)
            .mapValues(\.count)
        let recordsByAccession = Dictionary(grouping: records.compactMap { record in
            record.accession.map { ($0, record) }
        }, by: \.0)

        var result: [String: Self] = [:]
        for candidate in candidates
        where stableIDCounts[candidate.stableClusterID] == 1
            && candidateAccessionCounts[candidate.fastaRecordID] == 1 {
            guard let indexedRecords = recordsByAccession[candidate.fastaRecordID],
                  indexedRecords.count == 1,
                  let record = indexedRecords.first?.1,
                  let value = try? candidateRecord(candidate: candidate, record: record) else {
                continue
            }
            result[candidate.stableClusterID] = value
        }
        return result
    }

    private static func candidateRecord(
        candidate: ONTMHCCandidateRecord,
        record: GenBankRecord
    ) throws -> Self {
        guard let accession = record.accession else {
            throw CatalogError.missingCandidateAccession(record.locus.name)
        }
        let sequence = record.sequence.asString().uppercased()
        let actualChecksum = SHA256.hash(data: Data(sequence.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let expectedChecksum = candidate.sequenceSHA256.lowercased()
        guard actualChecksum == expectedChecksum else {
            throw CatalogError.candidateSequenceChecksumMismatch(
                accession: accession,
                expected: expectedChecksum,
                actual: actualChecksum
            )
        }
        return Self(
            identity: candidate.stableClusterID,
            displayName: candidate.provisionalName,
            genBankText: cleanGenBankText(record),
            fastaText: fasta(
                accession: accession,
                displayName: candidate.provisionalName,
                sequence: sequence
            ),
            emblText: EMBLFormatter.format(record: record, sequence: sequence)
        )
    }

    static func unavailable(identity: String, displayName: String) -> Self {
        let definition = "Validated allele record unavailable."
        return Self(
            identity: identity,
            displayName: displayName,
            genBankText: [
                "LOCUS       \(identity) 0 bp DNA linear",
                "DEFINITION  \(definition)",
                "ACCESSION   \(identity)",
                "COMMENT     validated allele record unavailable",
                "ORIGIN      ",
                "//",
                "",
            ].joined(separator: "\n"),
            fastaText: ">\(identity) \(displayName) validated allele record unavailable\n",
            emblText: [
                "ID   \(identity); linear; DNA; 0 BP.",
                "AC   \(identity);",
                "DE   \(definition)",
                "CC   Validated allele record unavailable.",
                "SQ   Sequence 0 BP;",
                "//",
                "",
            ].joined(separator: "\n")
        )
    }
}

private extension GenotypeAlleleSequenceRecord {
    static func normalizedTrailingNewline(_ text: String) -> String {
        var normalized = text
        while normalized.last == "\n" || normalized.last == "\r" {
            normalized.removeLast()
        }
        return normalized + "\n"
    }

    static func firstRecordValue(
        _ key: String,
        in fields: [String: [String]]
    ) -> String? {
        fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value.first
    }

    static func recordValues(
        _ key: String,
        in fields: [String: [String]]
    ) -> [String] {
        fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value ?? []
    }

    static func cleanGenBankText(_ record: GenBankRecord) -> String {
        let formatted = GenBankWriter(url: URL(fileURLWithPath: "/dev/null")).format(record)
        var annotationIndex = 0
        var inFeatures = false
        var lines: [String] = []
        for line in formatted.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("FEATURES") {
                inFeatures = true
                lines.append(line)
                continue
            }
            if line.hasPrefix("ORIGIN") {
                inFeatures = false
                lines.append(line)
                continue
            }
            guard inFeatures else {
                lines.append(line)
                continue
            }
            if line.hasPrefix("                     /\(GenBankReader.rawFeatureTypeQualifierKey)")
                || line.hasPrefix("                     /\(GenBankReader.rawLocationQualifierKey)") {
                continue
            }
            if line.hasPrefix("     "), !line.hasPrefix("                     /"),
               annotationIndex < record.annotations.count {
                let annotation = record.annotations[annotationIndex]
                annotationIndex += 1
                let featureType = annotation.qualifier(GenBankReader.rawFeatureTypeQualifierKey)
                    ?? annotation.type.rawValue
                let location = annotation.qualifier(GenBankReader.rawLocationQualifierKey)
                    ?? EMBLFeature.location(annotation)
                let paddedType = featureType.count < 15
                    ? featureType + String(repeating: " ", count: 15 - featureType.count)
                    : featureType
                lines.append("     \(paddedType) \(location)")
            } else {
                lines.append(line)
            }
        }
        return normalizedTrailingNewline(lines.joined(separator: "\n"))
    }

    static func fasta(accession: String, displayName: String, sequence: String) -> String {
        let bases = Array(sequence.uppercased())
        var lines = [">\(accession) \(displayName)"]
        lines.reserveCapacity(1 + ((bases.count + 59) / 60))
        for offset in stride(from: 0, to: bases.count, by: 60) {
            lines.append(String(bases[offset..<min(offset + 60, bases.count)]))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private struct EMBLFeature {
    let type: String
    let location: String
    let qualifiers: [(key: String, values: [String])]

    init(_ source: ONTMHCReferenceVisualizationFeature) {
        type = source.type
        location = source.rawGenBankLocation
            ?? Self.location(start: source.start, end: source.end, strand: source.strand)
        qualifiers = source.qualifiers
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, values: $0.value) }
    }

    init(_ annotation: SequenceAnnotation) {
        type = annotation.qualifier(GenBankReader.rawFeatureTypeQualifierKey)
            ?? annotation.type.rawValue
        location = annotation.qualifier(GenBankReader.rawLocationQualifierKey)
            ?? Self.location(annotation)
        qualifiers = annotation.qualifiers
            .filter {
                $0.key != GenBankReader.rawFeatureTypeQualifierKey
                    && $0.key != GenBankReader.rawLocationQualifierKey
            }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, values: $0.value.values) }
    }

    private static func location(start: Int, end: Int, strand: String) -> String {
        let interval = start + 1 == end ? "\(end)" : "\(start + 1)..\(end)"
        return strand == "-" ? "complement(\(interval))" : interval
    }

    static func location(_ annotation: SequenceAnnotation) -> String {
        let intervals = annotation.intervals.map { interval in
            interval.start + 1 == interval.end
                ? "\(interval.end)"
                : "\(interval.start + 1)..\(interval.end)"
        }
        var location = intervals.count == 1
            ? intervals[0]
            : "join(\(intervals.joined(separator: ",")))"
        if annotation.strand == .reverse {
            location = "complement(\(location))"
        }
        return location
    }
}

private enum EMBLFormatter {
    static func format(record: GenBankRecord, sequence: String) -> String {
        format(
            identity: record.accession ?? record.locus.name,
            definition: record.definition,
            moleculeType: record.locus.moleculeType.rawValue,
            source: record.values(forRecordField: "SOURCE").first,
            organism: record.values(forRecordField: "ORGANISM").first,
            taxonomy: record.values(forRecordField: "TAXONOMY").first,
            comments: record.values(forRecordField: "COMMENT"),
            features: record.annotations.map(EMBLFeature.init),
            sequence: sequence
        )
    }

    static func format(
        identity: String,
        definition: String?,
        moleculeType: String?,
        source: String?,
        organism: String?,
        taxonomy: String?,
        comments: [String],
        features: [EMBLFeature],
        sequence: String
    ) -> String {
        let bases = sequence.uppercased()
        let moleculeComponent = nonempty(moleculeType).map { "; \($0)" } ?? ""
        var lines = [
            "ID   \(identity); linear\(moleculeComponent); \(bases.count) BP.",
            "AC   \(identity);",
        ]
        if let definition, !definition.isEmpty {
            lines.append("DE   \(definition)")
        }
        if let organism = nonempty(organism) ?? nonempty(source) {
            lines.append("OS   \(organism)")
        }
        if let taxonomy = nonempty(taxonomy) {
            lines.append("OC   \(taxonomy)")
        }
        for comment in comments {
            lines.append(contentsOf: wrappedLines(
                prefix: "CC   ",
                content: flattened(comment)
            ))
        }
        if !features.isEmpty {
            lines.append("FH   Key             Location/Qualifiers")
            lines.append("FH")
            for feature in features {
                let featureKey = feature.type.count < 16
                    ? feature.type + String(repeating: " ", count: 16 - feature.type.count)
                    : feature.type + " "
                lines.append("FT   \(featureKey)\(feature.location)")
                for qualifier in feature.qualifiers {
                    for value in qualifier.values {
                        let content = value.isEmpty
                            ? "/\(qualifier.key)"
                            : "/\(qualifier.key)=\"\(escapedQualifier(value))\""
                        lines.append(contentsOf: wrappedLines(
                            prefix: "FT                   ",
                            content: content
                        ))
                    }
                }
            }
        }

        let counts = nucleotideCounts(bases)
        lines.append(
            "SQ   Sequence \(bases.count) BP; \(counts.a) A; \(counts.c) C; "
                + "\(counts.g) G; \(counts.t) T; \(counts.other) other;"
        )
        lines.append(contentsOf: sequenceLines(bases))
        lines.append("//")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func flattened(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func escapedQualifier(_ value: String) -> String {
        flattened(value).replacingOccurrences(of: "\"", with: "\"\"")
    }

    private static func wrappedLines(prefix: String, content: String) -> [String] {
        let width = max(1, 80 - prefix.count)
        let characters = Array(content)
        guard !characters.isEmpty else { return [prefix] }
        return stride(from: 0, to: characters.count, by: width).map { offset in
            prefix + String(characters[offset..<min(offset + width, characters.count)])
        }
    }

    private static func nucleotideCounts(
        _ sequence: String
    ) -> (a: Int, c: Int, g: Int, t: Int, other: Int) {
        var counts = (a: 0, c: 0, g: 0, t: 0, other: 0)
        for base in sequence {
            switch base {
            case "A": counts.a += 1
            case "C": counts.c += 1
            case "G": counts.g += 1
            case "T": counts.t += 1
            default: counts.other += 1
            }
        }
        return counts
    }

    private static func sequenceLines(_ sequence: String) -> [String] {
        let bases = Array(sequence.lowercased())
        var lines: [String] = []
        for offset in stride(from: 0, to: bases.count, by: 60) {
            let end = min(offset + 60, bases.count)
            let lineBases = Array(bases[offset..<end])
            let groups = stride(from: 0, to: lineBases.count, by: 10).map {
                String(lineBases[$0..<min($0 + 10, lineBases.count)])
            }
            let grouped = groups.joined(separator: " ")
                .padding(toLength: 65, withPad: " ", startingAt: 0)
            lines.append("     \(grouped)\(String(format: "%10d", end))")
        }
        return lines
    }
}
