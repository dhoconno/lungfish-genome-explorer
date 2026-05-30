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

    private static func scientificName(from displayName: String) -> String? {
        guard let open = displayName.firstIndex(of: "("),
              let close = displayName.lastIndex(of: ")"),
              open < close else {
            return nil
        }
        let innerStart = displayName.index(after: open)
        let text = displayName[innerStart..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func commonName(from displayName: String) -> String? {
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

    public func enriched(with metadataIndex: TwelveSReferenceMetadataIndex) -> TwelveSReferenceIndex {
        TwelveSReferenceIndex(records: records.map { record in
            guard let sequenceSHA = record.metadata["sequence_sha256"],
                  let metadataEntry = metadataIndex.entry(sequenceSHA256: sequenceSHA) else {
                return record
            }
            var metadata = record.metadata
            for (key, value) in metadataEntry.metadata where !value.isEmpty {
                metadata[key] = value
            }
            if let taxid = metadataEntry.taxid { metadata["taxid"] = taxid }
            if let taxonGroup = metadataEntry.taxonGroup { metadata["taxon_group"] = taxonGroup }
            if let taxonomy = metadataEntry.taxonomy { metadata["taxonomy"] = taxonomy }
            if let nameSource = metadataEntry.nameSource { metadata["name_source"] = nameSource }
            return TwelveSReferenceRecord(
                targetID: record.targetID,
                displayName: record.displayName,
                sequence: record.sequence,
                metadata: metadata,
                sourceHeader: record.sourceHeader,
                alternateMatches: metadataEntry.alternateMatches
            )
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
                    sourceHeader: header
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
