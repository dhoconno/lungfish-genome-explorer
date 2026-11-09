import Foundation
import CryptoKit
import LungfishIO

public struct TwelveSReferenceRecord: Equatable, Sendable {
    public let targetID: String
    public let displayName: String
    public let sequence: String
    public let metadata: [String: String]
    public let sourceHeader: String
    public let alternateMatches: [TwelveSAlternateMatch]

    public init(
        targetID: String,
        displayName: String,
        sequence: String,
        metadata: [String: String] = [:],
        sourceHeader: String? = nil,
        alternateMatches: [TwelveSAlternateMatch] = []
    ) {
        self.targetID = targetID
        self.displayName = displayName
        self.sequence = sequence.uppercased()
        self.metadata = metadata
        self.sourceHeader = sourceHeader ?? displayName
        self.alternateMatches = alternateMatches
    }

    public var target: TwelveSAmpliconTarget {
        TwelveSAmpliconTarget(
            targetID: targetID,
            displayName: displayName,
            scientificName: Self.nonEmpty(metadata["scientific_name"]) ?? Self.scientificName(from: displayName),
            commonName: Self.nonEmpty(metadata["common_name"]) ?? Self.commonName(from: displayName),
            taxid: metadata["taxid"],
            taxonGroup: metadata["taxon_group"],
            taxonomy: metadata["taxonomy"],
            nameSource: metadata["name_source"],
            locus: metadata["locus"],
            length: Int(metadata["len"] ?? metadata["length"] ?? ""),
            sourceHeader: sourceHeader,
            metadata: metadata,
            alternateMatches: alternateMatches
        )
    }

    /// A copy of this record carrying `entry`'s taxonomy.
    ///
    /// A sequence match copies every non-empty table column and the table's
    /// alternate matches. A name match copies only the species-level fields
    /// (names, taxid, group, taxonomy, name source), since the rest of the
    /// row (length, hash, alternates) describes a different sequence.
    func enriched(with entry: TwelveSReferenceMetadataEntry, matchedBySequence: Bool) -> TwelveSReferenceRecord {
        var metadata = self.metadata
        if matchedBySequence {
            for (key, value) in entry.metadata where !value.isEmpty {
                metadata[key] = value
            }
        } else {
            if let scientificName = entry.scientificName { metadata["scientific_name"] = scientificName }
            if let commonName = entry.commonName, Self.nonEmpty(metadata["common_name"]) == nil {
                metadata["common_name"] = commonName
            }
        }
        if let taxid = entry.taxid { metadata["taxid"] = taxid }
        if let taxonGroup = entry.taxonGroup { metadata["taxon_group"] = taxonGroup }
        if let taxonomy = entry.taxonomy { metadata["taxonomy"] = taxonomy }
        if let nameSource = entry.nameSource { metadata["name_source"] = nameSource }
        return TwelveSReferenceRecord(
            targetID: targetID,
            displayName: displayName,
            sequence: sequence,
            metadata: metadata,
            sourceHeader: sourceHeader,
            alternateMatches: matchedBySequence && !entry.alternateMatches.isEmpty
                ? entry.alternateMatches
                : alternateMatches
        )
    }

    static func scientificName(from displayName: String) -> String? {
        guard let open = displayName.firstIndex(of: "("),
              let close = displayName.lastIndex(of: ")"),
              open < close else {
            return nil
        }
        let innerStart = displayName.index(after: open)
        let text = displayName[innerStart..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func commonName(from displayName: String) -> String? {
        let prefix: Substring
        if let open = displayName.firstIndex(of: "(") {
            prefix = displayName[..<open]
        } else {
            prefix = Substring(displayName)
        }
        let text = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public struct TwelveSReferenceIndex: Equatable, Sendable {
    public let records: [TwelveSReferenceRecord]

    public init(records: [TwelveSReferenceRecord]) {
        self.records = records
    }

    public static func load(from url: URL, metadataURL: URL? = nil) throws -> TwelveSReferenceIndex {
        let content: String
        if url.pathExtension.lowercased() == "gz" {
            content = try GzipInputStream(url: url).readAllSync()
        } else {
            content = try String(contentsOf: url, encoding: .utf8)
        }
        let index = try parse(content)
        guard let metadataURL else { return index }
        return try index.enriched(with: TwelveSReferenceMetadataIndex.load(from: metadataURL))
    }

    /// Fills taxid, taxon group, taxonomy, and name source from the metadata
    /// table.
    ///
    /// A record is matched by sequence SHA-256 first: that is how a
    /// `.lungfish12sref` bundle pairs its FASTA with its table, and it also
    /// carries the table's alternate matches, which describe that exact
    /// amplicon. When the sequence is unknown to the table (a loose FASTA
    /// whose amplicons were trimmed or deduplicated differently) but the
    /// header carries the scientific name, the taxonomy fields come from the
    /// table's row for that species instead. Alternates stay the record's
    /// own in that case, because the table's alternates belong to a
    /// different sequence.
    public func enriched(with metadataIndex: TwelveSReferenceMetadataIndex) -> TwelveSReferenceIndex {
        TwelveSReferenceIndex(records: records.map { record in
            if let sequenceSHA = record.metadata["sequence_sha256"],
               let metadataEntry = metadataIndex.entry(sequenceSHA256: sequenceSHA) {
                return record.enriched(with: metadataEntry, matchedBySequence: true)
            }
            if let scientificName = record.target.scientificName,
               let metadataEntry = metadataIndex.entry(scientificName: scientificName) {
                return record.enriched(with: metadataEntry, matchedBySequence: false)
            }
            return record
        })
    }

    public static func parse(_ content: String) throws -> TwelveSReferenceIndex {
        var records: [TwelveSReferenceRecord] = []
        var currentHeader: String?
        var currentSequence = ""

        func flush() {
            guard let header = currentHeader else { return }
            let parsed = parseHeader(header)
            var metadata = parsed.metadata
            let sequenceSHA256 = sha256Hex(for: currentSequence)
            metadata["sequence_sha256"] = sequenceSHA256
            records.append(
                TwelveSReferenceRecord(
                    targetID: "\(parsed.displayName)|seq_sha256=\(sequenceSHA256.prefix(16))",
                    displayName: parsed.displayName,
                    sequence: currentSequence,
                    metadata: metadata,
                    sourceHeader: header,
                    alternateMatches: alternateMatches(fromAlsoMatches: metadata["also_matches"])
                )
            )
        }

        for rawLine in content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix(">") {
                flush()
                currentHeader = String(line.dropFirst())
                currentSequence = ""
            } else {
                currentSequence += line
            }
        }
        flush()
        return TwelveSReferenceIndex(records: records)
    }

    /// Alternate species that share the exact amplicon, read from the
    /// `also_matches=` header field a deduplicated reference FASTA carries
    /// (`Common name (Scientific name)` labels, comma separated). A
    /// `.lungfish12sref` bundle's metadata TSV supplies taxonomy-enriched
    /// alternates; a loose FASTA has only the header, so its alternates carry
    /// the parsed names and the shared-amplicon reason.
    static func alternateMatches(fromAlsoMatches raw: String?) -> [TwelveSAlternateMatch] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        var seen = Set<String>()
        return raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { label in
                TwelveSAlternateMatch(
                    displayName: label,
                    scientificName: TwelveSReferenceRecord.scientificName(from: label),
                    commonName: TwelveSReferenceRecord.commonName(from: label),
                    reason: "shared_exact_amplicon"
                )
            }
    }

    private static func parseHeader(_ header: String) -> (displayName: String, metadata: [String: String]) {
        let fields = header.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let displayName = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? header
        var metadata: [String: String] = [:]
        for field in fields.dropFirst() {
            let pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            metadata[String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)] =
                String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (displayName: displayName, metadata: metadata)
    }

    private static func sha256Hex(for sequence: String) -> String {
        SHA256.hash(data: Data(sequence.uppercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
