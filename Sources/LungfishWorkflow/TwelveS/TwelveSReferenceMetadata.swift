import Foundation
import CryptoKit
import LungfishIO

public struct TwelveSReferenceMetadataBuildConfiguration: Equatable, Sendable {
    public let deduplicatedFASTA: URL
    public let midoriMetadataTSV: URL
    public let outputURL: URL
    public let forceOverwrite: Bool
    public let argv: [String]

    public init(
        deduplicatedFASTA: URL,
        midoriMetadataTSV: URL,
        outputURL: URL,
        forceOverwrite: Bool = false,
        argv: [String] = []
    ) {
        self.deduplicatedFASTA = deduplicatedFASTA.standardizedFileURL
        self.midoriMetadataTSV = midoriMetadataTSV.standardizedFileURL
        self.outputURL = outputURL.standardizedFileURL
        self.forceOverwrite = forceOverwrite
        self.argv = argv
    }
}

public struct TwelveSReferenceMetadataBuildResult: Equatable, Sendable {
    public let metadataURL: URL
    public let provenanceURL: URL
}

public struct TwelveSReferenceMetadataEntry: Equatable, Sendable {
    public let targetID: String
    public let sequenceSHA256: String
    public let displayName: String
    public let scientificName: String?
    public let commonName: String?
    public let taxid: String?
    public let taxonGroup: String?
    public let taxonomy: String?
    public let nameSource: String?
    public let metadata: [String: String]
    public let alternateMatches: [TwelveSAlternateMatch]
}

public struct TwelveSReferenceMetadataIndex: Equatable, Sendable {
    public let entries: [TwelveSReferenceMetadataEntry]
    private let entriesBySequenceSHA256: [String: TwelveSReferenceMetadataEntry]

    public init(entries: [TwelveSReferenceMetadataEntry]) {
        self.entries = entries
        var indexed: [String: TwelveSReferenceMetadataEntry] = [:]
        for entry in entries where indexed[entry.sequenceSHA256] == nil {
            indexed[entry.sequenceSHA256] = entry
        }
        self.entriesBySequenceSHA256 = indexed
    }

    public func entry(sequenceSHA256: String) -> TwelveSReferenceMetadataEntry? {
        entriesBySequenceSHA256[sequenceSHA256]
    }

    public static func load(from url: URL) throws -> TwelveSReferenceMetadataIndex {
        let rows = try TSVTable.load(from: url).rows
        let decoder = JSONDecoder()
        let entries = try rows.map { row in
            let alternateMatches: [TwelveSAlternateMatch]
            if let json = nonEmpty(row["alternate_matches_json"]),
               let data = json.data(using: .utf8) {
                alternateMatches = try decoder.decode([TwelveSAlternateMatch].self, from: data)
            } else {
                alternateMatches = []
            }
            return TwelveSReferenceMetadataEntry(
                targetID: try required(row["target_id"], column: "target_id", file: url.lastPathComponent),
                sequenceSHA256: try required(row["sequence_sha256"], column: "sequence_sha256", file: url.lastPathComponent),
                displayName: nonEmpty(row["display_name"]) ?? "",
                scientificName: nonEmpty(row["scientific_name"]),
                commonName: nonEmpty(row["common_name"]),
                taxid: nonEmpty(row["taxid"]),
                taxonGroup: nonEmpty(row["taxon_group"]),
                taxonomy: nonEmpty(row["taxonomy"]),
                nameSource: nonEmpty(row["name_source"]),
                metadata: row.filter { !$0.value.isEmpty },
                alternateMatches: alternateMatches
            )
        }
        return TwelveSReferenceMetadataIndex(entries: entries)
    }
}

public enum TwelveSReferenceMetadataBuildError: Error, LocalizedError, Equatable {
    case missingInput(String)
    case outputExists(String)
    case missingColumn(String)

    public var errorDescription: String? {
        switch self {
        case .missingInput(let path):
            return "12S reference metadata input does not exist: \(path)"
        case .outputExists(let path):
            return "12S reference metadata output already exists: \(path)"
        case .missingColumn(let column):
            return "12S MIDORI metadata table is missing required column '\(column)'"
        }
    }
}

public struct TwelveSReferenceMetadataBuilder: Sendable {
    public init() {}

    public func build(
        _ config: TwelveSReferenceMetadataBuildConfiguration
    ) async throws -> TwelveSReferenceMetadataBuildResult {
        let startedAt = Date()
        try validate(config)
        try FileManager.default.createDirectory(
            at: config.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let references = try TwelveSReferenceIndex.load(from: config.deduplicatedFASTA).records
        let midoriIndex = try MIDORIMetadataIndex.load(from: config.midoriMetadataTSV)
        let entries = references.map { reference in
            makeEntry(reference: reference, midoriIndex: midoriIndex)
        }
        do {
            try write(entries, to: config.outputURL)
            let provenanceURL = try writeProvenance(config: config, startedAt: startedAt, completedAt: Date())
            return TwelveSReferenceMetadataBuildResult(
                metadataURL: config.outputURL.standardizedFileURL,
                provenanceURL: provenanceURL.standardizedFileURL
            )
        } catch {
            try? FileManager.default.removeItem(at: config.outputURL)
            try? FileManager.default.removeItem(
                at: config.outputURL.appendingPathExtension("lungfish-provenance.json")
            )
            throw error
        }
    }

    private func validate(_ config: TwelveSReferenceMetadataBuildConfiguration) throws {
        let fm = FileManager.default
        for input in [config.deduplicatedFASTA, config.midoriMetadataTSV] where !fm.fileExists(atPath: input.path) {
            throw TwelveSReferenceMetadataBuildError.missingInput(input.path)
        }
        if fm.fileExists(atPath: config.outputURL.path) {
            if config.forceOverwrite {
                try fm.removeItem(at: config.outputURL)
            } else {
                throw TwelveSReferenceMetadataBuildError.outputExists(config.outputURL.path)
            }
        }
    }

    private func makeEntry(
        reference: TwelveSReferenceRecord,
        midoriIndex: MIDORIMetadataIndex
    ) -> TwelveSReferenceMetadataEntry {
        let parsedPrimary = Self.parseSpeciesLabel(reference.displayName)
        let primaryMetadata = midoriIndex.bestMatch(
            scientificName: parsedPrimary.scientificName,
            commonName: parsedPrimary.commonName,
            displayName: reference.displayName
        )
        let alternateMatches = Self.alternateLabels(from: reference).map { label in
            let parsed = Self.parseSpeciesLabel(label)
            let metadata = midoriIndex.bestMatch(
                scientificName: parsed.scientificName,
                commonName: parsed.commonName,
                displayName: label
            )
            return TwelveSAlternateMatch(
                displayName: label,
                scientificName: metadata?.latinName ?? parsed.scientificName,
                commonName: metadata?.commonName ?? parsed.commonName,
                taxid: metadata?.taxid,
                taxonGroup: metadata?.group,
                taxonomy: metadata?.taxonomy,
                nameSource: metadata?.nameSource,
                reason: "shared_exact_amplicon"
            )
        }

        var metadata = reference.metadata
        metadata["taxid"] = primaryMetadata?.taxid
        metadata["taxon_group"] = primaryMetadata?.group
        metadata["taxonomy"] = primaryMetadata?.taxonomy
        metadata["name_source"] = primaryMetadata?.nameSource

        return TwelveSReferenceMetadataEntry(
            targetID: reference.targetID,
            sequenceSHA256: reference.metadata["sequence_sha256"] ?? Self.sha256Hex(for: reference.sequence),
            displayName: reference.displayName,
            scientificName: primaryMetadata?.latinName ?? parsedPrimary.scientificName,
            commonName: primaryMetadata?.commonName ?? parsedPrimary.commonName,
            taxid: primaryMetadata?.taxid,
            taxonGroup: primaryMetadata?.group,
            taxonomy: primaryMetadata?.taxonomy,
            nameSource: primaryMetadata?.nameSource,
            metadata: metadata,
            alternateMatches: alternateMatches
        )
    }

    private func write(_ entries: [TwelveSReferenceMetadataEntry], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines = [
            [
                "target_id", "sequence_sha256", "display_name", "scientific_name", "common_name",
                "taxid", "taxon_group", "taxonomy", "name_source", "locus", "length",
                "n_refs", "n_species", "n_primer_pairs", "primer_pairs", "alternate_matches_json",
            ].joined(separator: "\t")
        ]
        for entry in entries {
            let alternateJSON = String(
                data: try encoder.encode(entry.alternateMatches),
                encoding: .utf8
            ) ?? "[]"
            lines.append([
                entry.targetID,
                entry.sequenceSHA256,
                entry.displayName,
                entry.scientificName ?? "",
                entry.commonName ?? "",
                entry.taxid ?? "",
                entry.taxonGroup ?? "",
                entry.taxonomy ?? "",
                entry.nameSource ?? "",
                entry.metadata["locus"] ?? "",
                entry.metadata["len"] ?? entry.metadata["length"] ?? "",
                entry.metadata["n_refs"] ?? "",
                entry.metadata["n_species"] ?? "",
                entry.metadata["n_primer_pairs"] ?? "",
                entry.metadata["primer_pairs"] ?? "",
                alternateJSON,
            ].map(Self.tsvEscape).joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeProvenance(
        config: TwelveSReferenceMetadataBuildConfiguration,
        startedAt: Date,
        completedAt: Date
    ) throws -> URL {
        let argv = config.argv.isEmpty
            ? Self.replayArgv(for: config)
            : config.argv
        let envelope = try ProvenanceRunBuilder(
            workflowName: "lungfish fastq 12s-reference-metadata",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish-cli",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .reproducibleCommand(Self.commandLine(from: argv))
        .options(
            explicit: [
                "deduplicatedFASTA": .file(config.deduplicatedFASTA),
                "midoriMetadataTSV": .file(config.midoriMetadataTSV),
                "output": .file(config.outputURL),
                "forceOverwrite": .boolean(config.forceOverwrite),
            ],
            defaults: [
                "forceOverwrite": .boolean(false),
            ],
            resolved: [
                "forceOverwrite": .boolean(config.forceOverwrite),
            ]
        )
        .input(config.deduplicatedFASTA, format: .fasta, role: .reference)
        .input(config.midoriMetadataTSV, format: .text, role: .reference)
        .output(config.outputURL, format: .text, role: .output)
        .runtime(ProvenanceRuntimeIdentity(user: WorkflowRun.currentUser))
        .complete(exitStatus: 0, startedAt: startedAt, endedAt: completedAt)
        let sidecarURL = config.outputURL.appendingPathExtension("lungfish-provenance.json")
        return try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: sidecarURL)
    }

    private static func alternateLabels(from reference: TwelveSReferenceRecord) -> [String] {
        guard let raw = nonEmpty(reference.metadata["also_matches"]) else { return [] }
        return raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parseSpeciesLabel(_ label: String) -> (commonName: String?, scientificName: String?) {
        guard let open = label.firstIndex(of: "("),
              let close = label.lastIndex(of: ")"),
              open < close else {
            let trimmed = nonEmpty(label)
            return (nil, trimmed)
        }
        let common = nonEmpty(String(label[..<open]))
        let start = label.index(after: open)
        let scientific = nonEmpty(String(label[start..<close]))
        return (common, scientific)
    }

    private static func sha256Hex(for sequence: String) -> String {
        SHA256.hash(data: Data(sequence.uppercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func tsvEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func commandLine(from argv: [String]) -> String {
        argv.map(twelveSMetadataShellEscape).joined(separator: " ")
    }

    private static func replayArgv(for config: TwelveSReferenceMetadataBuildConfiguration) -> [String] {
        var argv = [
            "lungfish-cli", "fastq", "12s-reference-metadata",
            "--dedup-fasta", config.deduplicatedFASTA.path,
            "--midori-metadata", config.midoriMetadataTSV.path,
            "--output", config.outputURL.path,
        ]
        if config.forceOverwrite {
            argv.append("--force")
        }
        return argv
    }
}

private struct MIDORIMetadata: Equatable {
    let seqID: String
    let commonName: String?
    let latinName: String?
    let group: String?
    let taxid: String?
    let nameSource: String?
    let taxonomy: String?
}

private struct MIDORIMetadataIndex {
    let byLatinName: [String: [MIDORIMetadata]]
    let byCommonName: [String: [MIDORIMetadata]]

    static func load(from url: URL) throws -> MIDORIMetadataIndex {
        let table = try TSVTable.load(from: url)
        for requiredColumn in ["seq_id", "common_name", "latin_name", "group", "taxid", "name_source", "taxonomy"] {
            guard table.headers.contains(requiredColumn) else {
                throw TwelveSReferenceMetadataBuildError.missingColumn(requiredColumn)
            }
        }
        let rows = table.rows.map {
            MIDORIMetadata(
                seqID: $0["seq_id"] ?? "",
                commonName: nonEmpty($0["common_name"]),
                latinName: nonEmpty($0["latin_name"]),
                group: nonEmpty($0["group"]),
                taxid: nonEmpty($0["taxid"]),
                nameSource: nonEmpty($0["name_source"]),
                taxonomy: nonEmpty($0["taxonomy"])
            )
        }
        return MIDORIMetadataIndex(
            byLatinName: Dictionary(grouping: rows, by: { normalizedKey($0.latinName) }),
            byCommonName: Dictionary(grouping: rows, by: { normalizedKey($0.commonName) })
        )
    }

    func bestMatch(scientificName: String?, commonName: String?, displayName: String) -> MIDORIMetadata? {
        let candidates = byLatinName[normalizedKey(scientificName)]
            ?? byCommonName[normalizedKey(commonName)]
            ?? byLatinName[normalizedKey(displayName)]
            ?? byCommonName[normalizedKey(displayName)]
            ?? []
        return candidates.sorted { lhs, rhs in
            let lhsPriority = nameSourcePriority(lhs.nameSource)
            let rhsPriority = nameSourcePriority(rhs.nameSource)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return (lhs.latinName ?? lhs.seqID).localizedStandardCompare(rhs.latinName ?? rhs.seqID) == .orderedAscending
        }.first
    }
}

private struct TSVTable {
    let headers: [String]
    let rows: [[String: String]]

    static func load(from url: URL) throws -> TSVTable {
        let content = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let headerLine = lines.first else {
            return TSVTable(headers: [], rows: [])
        }
        let headers = splitTSVLine(headerLine).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let rows = lines.dropFirst().map { line in
            let fields = splitTSVLine(line)
            var row: [String: String] = [:]
            for index in headers.indices where !headers[index].isEmpty {
                row[headers[index]] = index < fields.count ? fields[index] : ""
            }
            return row
        }
        return TSVTable(headers: headers, rows: rows)
    }

    private static func splitTSVLine(_ line: String) -> [String] {
        line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }
}

private func required(_ value: String?, column: String, file: String) throws -> String {
    guard let value = nonEmpty(value) else {
        throw TwelveSAmpliconResultBundleError.missingColumn(file: file, column: column)
    }
    return value
}

private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func normalizedKey(_ value: String?) -> String {
    nonEmpty(value)?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ?? ""
}

private func nameSourcePriority(_ value: String?) -> Int {
    switch value {
    case "ncbi_genbank": return 0
    case "ncbi_common": return 1
    case "fishbase": return 2
    case "latin": return 3
    default: return 4
    }
}

private func twelveSMetadataShellEscape(_ value: String) -> String {
    guard !value.isEmpty else { return "''" }
    if value.range(of: #"[^A-Za-z0-9_./:=@+-]"#, options: .regularExpression) == nil {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
