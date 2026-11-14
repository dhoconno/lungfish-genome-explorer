// SalmonQuantFolderReader.swift - salmon's quant folders read as given (Phase 5.1 lane RS-BULK-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A salmon folder holds `quant.sf`, `cmd_info.json`, `lib_format_counts.json` and `aux_info/meta_info.json`. The reader
// takes each transcript's count from NumReads as salmon printed it, sums genes only through the transcript-to-gene table
// the person passes, and reads salmon's own quality numbers. It changes no byte: the one writer keeps each file it read,
// and nf-core/rnaseq's `quant.genes.sf`, under `source/<sample>/` (`docs/formats/rnaseq-bundle.md`, The tool's own
// files). RS-QUANT reuses it for the folders LGE's own salmon run writes.

import Foundation
import LungfishIO

/// One salmon folder as salmon wrote it.
public struct SalmonQuantFolder: Sendable, Equatable {
    public struct Transcript: Sendable, Equatable {
        public var id: String
        public var numReads: Double
    }

    /// salmon's own numbers. A nil field is one the files do not state.
    public struct Quality: Sendable, Equatable {
        public var salmonVersion: String?
        public var numProcessed: Int?
        public var numMapped: Int?
        public var percentMapped: Double?
        /// `library_types` of `meta_info.json`, joined with commas, such as `IU`.
        public var libraryType: String?
        /// `expected_format` of `lib_format_counts.json`.
        public var expectedFormat: String?
        public var compatibleFragmentRatio: Double?
        public var strandMappingBias: Double?
        /// `libType` as the run asked for it in `cmd_info.json`, such as `A`.
        public var libTypeOption: String?
        public var seqBiasCorrect: Bool?
        public var gcBiasCorrect: Bool?
        public var posBiasCorrect: Bool?
        /// Every `index_*hash*` key of `meta_info.json` with its value as given.
        public var indexHashes: [String: String] = [:]
    }

    /// The sample id, the folder's name unless a sample sheet labels it.
    public var sample: String
    public var url: URL
    public var transcripts: [Transcript]
    public var quality: Quality
    /// The files kept under `source/<sample>/`, as paths under the folder.
    public var keptFiles: [String]
}

/// A transcript-to-gene table with `transcript_id` and `gene_id` columns, as `tx2gene.py` writes it.
public struct SalmonTx2Gene: Sendable, Equatable {
    public private(set) var geneByTranscript: [String: String]
    private var geneByUnversioned: [String: String]

    public init(geneByTranscript: [String: String]) {
        self.geneByTranscript = geneByTranscript
        var unversioned: [String: String] = [:]
        for (transcript, gene) in geneByTranscript { unversioned[Self.unversioned(transcript)] = gene }
        geneByUnversioned = unversioned
    }

    /// The gene of `transcript`, matched as given and then without a trailing `.<version>` on either side.
    public func gene(for transcript: String) -> String? {
        geneByTranscript[transcript] ?? geneByUnversioned[Self.unversioned(transcript)]
    }

    static func unversioned(_ id: String) -> String {
        guard let dot = id.lastIndex(of: "."), dot != id.startIndex else { return id }
        let version = id[id.index(after: dot)...]
        return !version.isEmpty && version.allSatisfy(\.isASCII) && version.allSatisfy(\.isNumber) ? String(id[..<dot]) : id
    }

    public static func read(_ url: URL) throws -> SalmonTx2Gene {
        let name = url.lastPathComponent
        let rows = try SalmonQuantFolderReader.tsvRows(Data(contentsOf: url), path: name)
        guard let header = rows.first, let transcriptColumn = header.firstIndex(of: "transcript_id"),
              let geneColumn = header.firstIndex(of: "gene_id") else {
            throw RNASeqImportError.invalidFile(path: name, reason: "its first line names no transcript_id and gene_id columns")
        }
        var map: [String: String] = [:]
        for (index, row) in rows.dropFirst().enumerated() {
            guard max(transcriptColumn, geneColumn) < row.count, !row[transcriptColumn].isEmpty, !row[geneColumn].isEmpty else {
                throw RNASeqImportError.invalidFile(path: name, reason: "line \(index + 2) names no transcript and gene")
            }
            let transcript = row[transcriptColumn], gene = row[geneColumn]
            if let earlier = map.updateValue(gene, forKey: transcript), earlier != gene {
                throw RNASeqImportError.invalidFile(path: name, reason: "the transcript \(transcript) maps to \(earlier) and to \(gene)")
            }
        }
        return SalmonTx2Gene(geneByTranscript: map)
    }
}

// MARK: - reader

public enum SalmonQuantFolderReader {
    public static let tool = "salmon"
    /// The files the reader reads, as paths under a salmon folder.
    public static let readFiles = ["quant.sf", "cmd_info.json", "lib_format_counts.json", "aux_info/meta_info.json"]
    /// nf-core/rnaseq's gene table beside `quant.sf`, kept as given when present and never read.
    public static let keptIfPresent = ["quant.genes.sf"]

    private struct MetaInfo: Decodable {
        var salmonVersion: String?
        var numProcessed: Int?
        var numMapped: Int?
        var percentMapped: Double?
        var libraryTypes: [String]?
        var seqBiasCorrect: Bool?
        var gcBiasCorrect: Bool?
        var posBiasCorrect: Bool?
    }

    private struct LibFormatCounts: Decodable {
        var expectedFormat: String?
        var compatibleFragmentRatio: Double?
        var strandMappingBias: Double?
    }

    private struct CommandInfo: Decodable {
        var libType: String?
    }

    /// The `index_*hash*` strings of `meta_info.json`, read by their own keys.
    private struct IndexHashes: Decodable {
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        var values: [String: String] = [:]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            for key in container.allKeys where key.stringValue.hasPrefix("index_") && key.stringValue.contains("hash") {
                if let value = try? container.decode(String.self, forKey: key) { values[key.stringValue] = value }
            }
        }
    }

    /// Reads `folder`. The sample id is the folder's name.
    public static func read(folder: URL) throws -> SalmonQuantFolder {
        let name = folder.lastPathComponent
        let fileManager = FileManager.default
        for file in readFiles where !fileManager.fileExists(atPath: folder.appendingPathComponent(file).path) {
            throw RNASeqImportError.missingFile(folder: name, file: file)
        }
        let transcripts = try quant(folder.appendingPathComponent("quant.sf"), path: "\(name)/quant.sf")
        let meta: MetaInfo = try decode(folder, "aux_info/meta_info.json", snakeCase: true)
        let hashes: IndexHashes = try decode(folder, "aux_info/meta_info.json", snakeCase: false)
        let format: LibFormatCounts = try decode(folder, "lib_format_counts.json", snakeCase: true)
        let command: CommandInfo = try decode(folder, "cmd_info.json", snakeCase: false)
        var quality = SalmonQuantFolder.Quality()
        quality.salmonVersion = meta.salmonVersion
        quality.numProcessed = meta.numProcessed
        quality.numMapped = meta.numMapped
        quality.percentMapped = meta.percentMapped
        quality.libraryType = meta.libraryTypes.map { $0.joined(separator: ",") }
        quality.expectedFormat = format.expectedFormat
        quality.compatibleFragmentRatio = format.compatibleFragmentRatio
        quality.strandMappingBias = format.strandMappingBias
        quality.libTypeOption = command.libType
        quality.seqBiasCorrect = meta.seqBiasCorrect
        quality.gcBiasCorrect = meta.gcBiasCorrect
        quality.posBiasCorrect = meta.posBiasCorrect
        quality.indexHashes = hashes.values
        let kept = readFiles + keptIfPresent.filter { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }
        return SalmonQuantFolder(sample: name, url: folder, transcripts: transcripts, quality: quality, keptFiles: kept)
    }

    private static func decode<T: Decodable>(_ folder: URL, _ file: String, snakeCase: Bool) throws -> T {
        let path = "\(folder.lastPathComponent)/\(file)"
        let decoder = JSONDecoder()
        if snakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        do {
            return try decoder.decode(T.self, from: Data(contentsOf: folder.appendingPathComponent(file)))
        } catch {
            throw RNASeqImportError.invalidFile(path: path, reason: "it is not the JSON salmon writes (\(error.localizedDescription))")
        }
    }

    /// Tab-separated rows of `data`, a line break of `\n` or `\r\n`, empty lines left out.
    static func tsvRows(_ data: Data, path: String) throws -> [[String]] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RNASeqImportError.invalidFile(path: path, reason: "it is not UTF-8 text")
        }
        return text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    /// NumReads by transcript in file order. A cancel is checked every 4,096 rows.
    static func quant(_ url: URL, path: String) throws -> [SalmonQuantFolder.Transcript] {
        let data = try Data(contentsOf: url)
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).makeIterator()
        func cells(_ line: Data) -> [String] {
            let trimmed = line.last == UInt8(ascii: "\r") ? line.dropLast() : line
            return trimmed.split(separator: UInt8(ascii: "\t"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        }
        guard let first = lines.next(), case let header = cells(first),
              let nameColumn = header.firstIndex(of: "Name"), let readsColumn = header.firstIndex(of: "NumReads") else {
            throw RNASeqImportError.invalidFile(path: path, reason: "its first line names no Name and NumReads columns")
        }
        var transcripts: [SalmonQuantFolder.Transcript] = []
        var lineNumber = 1
        while let line = lines.next() {
            lineNumber += 1
            if lineNumber % 4_096 == 0 { try Task.checkCancellation() }
            let row = cells(line)
            guard row.count == header.count, let reads = Double(row[readsColumn]), reads.isFinite else {
                throw RNASeqImportError.invalidFile(path: path, reason: "line \(lineNumber) holds no NumReads count")
            }
            transcripts.append(.init(id: row[nameColumn], numReads: reads))
        }
        return transcripts
    }

    /// Transcripts by samples, NumReads as given. Every folder must list the same transcripts in the same order.
    public static func transcriptCounts(_ folders: [SalmonQuantFolder]) throws -> RNASeqCountTable {
        var seen = Set<String>()
        if let repeated = folders.first(where: { !seen.insert($0.sample).inserted }) {
            throw RNASeqImportError.duplicateSample(repeated.sample)
        }
        guard let first = folders.first else { return RNASeqCountTable(sampleIDs: [], rows: []) }
        for other in folders.dropFirst() {
            try Task.checkCancellation()
            guard other.transcripts.elementsEqual(first.transcripts, by: { $0.id == $1.id }) else {
                throw RNASeqImportError.transcriptSetsDiffer(first: first.sample, other: other.sample)
            }
        }
        var rows: [RNASeqCountTable.Row] = []
        rows.reserveCapacity(first.transcripts.count)
        for index in first.transcripts.indices {
            if index % 4_096 == 0 { try Task.checkCancellation() }
            rows.append(.init(id: first.transcripts[index].id, counts: folders.map { $0.transcripts[index].numReads }))
        }
        return RNASeqCountTable(sampleIDs: folders.map(\.sample), rows: rows)
    }

    /// Genes by samples, each the sum of its transcripts' NumReads in file order. A transcript with no gene is refused.
    public static func geneCounts(_ folders: [SalmonQuantFolder], tx2gene: SalmonTx2Gene) throws -> RNASeqCountTable {
        let transcripts = try transcriptCounts(folders)
        var order: [String] = []
        var sums: [String: [Double]] = [:]
        var missing: [String] = []
        for row in transcripts.rows {
            guard let gene = tx2gene.gene(for: row.id) else {
                missing.append(row.id)
                continue
            }
            if let sum = sums[gene] {
                sums[gene] = zip(sum, row.counts).map { $0 + $1 }
            } else {
                order.append(gene)
                sums[gene] = row.counts
            }
        }
        guard missing.isEmpty else {
            throw RNASeqImportError.transcriptsWithoutGene(count: missing.count, examples: Array(missing.prefix(3)))
        }
        return RNASeqCountTable(sampleIDs: transcripts.sampleIDs, rows: order.map { .init(id: $0, counts: sums[$0] ?? []) })
    }

    // MARK: - quality

    /// The quality columns, in the order of `quality/samples.quality.tsv`.
    public static let qualityColumns = [
        "salmon_version", "num_processed", "num_mapped", "percent_mapped", "library_type", "expected_format",
        "compatible_fragment_ratio", "strand_mapping_bias", "lib_type_option", "seq_bias_correct", "gc_bias_correct",
        "pos_bias_correct", "index_seq_hash", "index_name_hash", "index_seq_hash512", "index_name_hash512",
        "index_decoy_seq_hash", "index_decoy_name_hash",
    ]

    /// The quality numbers of `quality` by column, nil where the files state none.
    static func qualityValues(_ quality: SalmonQuantFolder.Quality) -> [String: ParameterValue?] {
        var values: [String: ParameterValue?] = [
            "salmon_version": quality.salmonVersion.map(ParameterValue.string),
            "num_processed": quality.numProcessed.map(ParameterValue.integer),
            "num_mapped": quality.numMapped.map(ParameterValue.integer),
            "percent_mapped": quality.percentMapped.map(ParameterValue.number),
            "library_type": quality.libraryType.map(ParameterValue.string),
            "expected_format": quality.expectedFormat.map(ParameterValue.string),
            "compatible_fragment_ratio": quality.compatibleFragmentRatio.map(ParameterValue.number),
            "strand_mapping_bias": quality.strandMappingBias.map(ParameterValue.number),
            "lib_type_option": quality.libTypeOption.map(ParameterValue.string),
            "seq_bias_correct": quality.seqBiasCorrect.map(ParameterValue.boolean),
            "gc_bias_correct": quality.gcBiasCorrect.map(ParameterValue.boolean),
            "pos_bias_correct": quality.posBiasCorrect.map(ParameterValue.boolean),
        ]
        for column in qualityColumns where column.hasPrefix("index_") {
            values[column] = quality.indexHashes[column].map(ParameterValue.string)
        }
        return values
    }

    /// `quality/samples.quality.tsv`: one row a sample, an empty cell where the files state nothing.
    public static func qualityTSV(_ folders: [SalmonQuantFolder]) -> Data {
        var lines = [(["sample_id"] + qualityColumns).joined(separator: "\t")]
        for folder in folders {
            let values = qualityValues(folder.quality)
            let cells = qualityColumns.map { column -> String in
                switch values[column] ?? nil {
                case .string(let text)?: return text
                case .integer(let number)?: return String(number)
                case .number(let number)?: return "\(number)"
                case .boolean(let flag)?: return flag ? "true" : "false"
                default: return ""
                }
            }
            lines.append(([folder.sample] + cells).joined(separator: "\t"))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// The quality numbers for the record, by sample, with Not recorded where the files state none.
    public static func qualityRecord(_ folders: [SalmonQuantFolder]) -> ParameterValue {
        var samples: [String: ParameterValue] = [:]
        for folder in folders {
            let values = qualityValues(folder.quality)
            var row: [String: ParameterValue] = [:]
            for column in qualityColumns { row[column] = (values[column] ?? nil) ?? .string(RNASeqImportFacts.notRecorded) }
            samples[folder.sample] = .dictionary(row)
        }
        return .dictionary(samples)
    }

    /// The files to keep, each under its sample's folder as salmon wrote it.
    public static func sourceFiles(_ folders: [SalmonQuantFolder]) -> [RNASeqResultWriter.SourceFile] {
        folders.flatMap { folder in
            folder.keptFiles.map {
                RNASeqResultWriter.SourceFile(url: folder.url.appendingPathComponent($0), relativePath: $0, sample: folder.sample, tool: tool)
            }
        }
    }

    /// The one route of `folders`. Folders of two salmon versions or two indexes are refused, since their counts
    /// would join two routes in one table (`docs/formats/rnaseq-bundle.md`, One table, one route).
    public static func route(_ folders: [SalmonQuantFolder], tx2geneName: String?) throws -> RNASeqResultManifest.Route {
        func one(_ label: String, _ value: (SalmonQuantFolder.Quality) -> String?) throws -> String {
            let values = Set(folders.map { value($0.quality) ?? RNASeqImportFacts.notRecorded })
            guard values.count <= 1 else { throw RNASeqImportError.routesDiffer(label) }
            return values.first ?? RNASeqImportFacts.notRecorded
        }
        let version = try one("salmon version") { $0.salmonVersion }
        var settings = [
            "indexSeqHash": try one("index (index_seq_hash)") { $0.indexHashes["index_seq_hash"] },
            "libraryType": try one("library type") { $0.libraryType },
            "seqBiasCorrect": try one("sequence bias correction") { $0.seqBiasCorrect.map { "\($0)" } },
            "gcBiasCorrect": try one("GC bias correction") { $0.gcBiasCorrect.map { "\($0)" } },
            "posBiasCorrect": try one("position bias correction") { $0.posBiasCorrect.map { "\($0)" } },
            "counts": "NumReads",
        ]
        if let tx2geneName { settings["geneSums"] = "NumReads summed by gene through \(tx2geneName)" }
        return .init(id: "imported-salmon", tool: tool, toolVersion: version, settings: settings)
    }
}
