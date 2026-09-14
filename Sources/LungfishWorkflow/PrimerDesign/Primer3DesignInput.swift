import Foundation
import CryptoKit
import LungfishIO

public struct Primer3DesignInputSummary: Sendable {
    public let url: URL
    public let isAlignment: Bool
    public let recordTitles: [String]
    public let checksumSHA256: String
}

enum Primer3PreparedSourceKind: String, Codable, Sendable { case fasta, msa }

struct Primer3PreparedTemplate: Sendable {
    let inputID: UUID
    let resultID: UUID
    let title: String
    let sequence: String
    let sourceURL: URL
    let sourceIndex: Int
    let sourceRecordID: String
    let sourceKind: Primer3PreparedSourceKind
    let bindingSitePolicy: Primer3BindingSitePolicy
    let alignmentToTemplate: [Int?]?
    let excludedRegions: [Range<Int>]
}

struct Primer3AlignmentProjection: Sendable {
    let alignmentToTemplate: [Int?]
    let excludedRegions: [Range<Int>]
}

struct Primer3AlignedRow: Sendable {
    let title: String
    let sequence: String
}

struct Primer3AlignedNormalization: Sendable {
    let rows: [Primer3AlignedRow]
    let uracilCount: Int
    let unknownBaseCount: Int
}

enum Primer3InputLoader {
    static func isAlignmentBundle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == MultipleSequenceAlignmentBundle.directoryExtension
            || (FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
                && FileManager.default.fileExists(atPath: url.appendingPathComponent("metadata/rows.json").path)
                && FileManager.default.fileExists(atPath: url.appendingPathComponent("alignment/primary.aligned.fasta").path))
    }

    static func isReferenceBundle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "lungfishref"
            && SequenceInputResolver.inputSequenceFormat(for: url) == .fasta
    }

    static func fastaURL(for url: URL) -> URL? {
        isReferenceBundle(url) ? SequenceInputResolver.resolvePrimarySequenceURL(for: url) : url
    }

    static func inspect(_ url: URL) throws -> Primer3DesignInputSummary {
        if isAlignmentBundle(url) {
            let bundle = try MultipleSequenceAlignmentBundle.load(from: url)
            return Primer3DesignInputSummary(url: url, isAlignment: true, recordTitles: bundle.rows.map(\.displayName), checksumSHA256: try fingerprint(url))
        }
        guard let fastaURL = fastaURL(for: url) else {
            throw Primer3DesignError.invalidRequest("reference bundle has no readable primary FASTA")
        }
        let records = try FASTAReader(url: fastaURL).readHeadersSync()
        return Primer3DesignInputSummary(
            url: url,
            isAlignment: false,
            recordTitles: records.map { header in
                header.description.map { "\(header.name) \($0)" } ?? header.name
            }, checksumSHA256: try fingerprint(url))
    }

    static func fingerprint(_ url: URL) throws -> String {
        var hasher = SHA256()
        let urls: [URL]
        if isAlignmentBundle(url) {
            urls = ["manifest.json", "metadata/rows.json", "alignment/primary.aligned.fasta"].map { url.appendingPathComponent($0) }
        } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            var files = try regularFiles(in: url)
            if isReferenceBundle(url), let fastaURL = fastaURL(for: url), !isContained(fastaURL, in: url) {
                files.append(fastaURL)
            }
            urls = files
        } else { urls = [url] }
        for file in urls {
            let data = try Data(contentsOf: file)
            if urls.count > 1 {
                var length = UInt64(data.count).bigEndian
                withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func regularFiles(in root: URL) throws -> [URL] {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw Primer3DesignError.invalidRequest("sequence input contains a symbolic link")
        }
        if values.isRegularFile == true { return [root] }
        guard values.isDirectory == true else {
            throw Primer3DesignError.invalidRequest("sequence input contains an unsupported file type")
        }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { try regularFiles(in: $0) }
    }

    static func isContained(_ candidate: URL, in directory: URL) -> Bool {
        candidate.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    static func prepare(_ selection: Primer3TemplateSelection) throws -> Primer3PreparedTemplate {
        switch selection {
        case .fastaRecord(let url, let index):
            guard let fastaURL = fastaURL(for: url) else {
                throw Primer3DesignError.invalidRequest("reference bundle has no readable primary FASTA")
            }
            let records = try FASTAReader(url: fastaURL).readAllSync(alphabet: .dna)
            guard records.indices.contains(index) else { throw Primer3DesignError.invalidRequest("FASTA record index \(index) is out of bounds for \(url.path)") }
            let record = records[index]
            return Primer3PreparedTemplate(inputID: UUID(), resultID: UUID(), title: record.name, sequence: record.asString().uppercased(), sourceURL: url, sourceIndex: index, sourceRecordID: record.name, sourceKind: .fasta, bindingSitePolicy: .templateOnly, alignmentToTemplate: nil, excludedRegions: [])
        case .msaTemplate(let url, let index, let policy):
            let bundle = try MultipleSequenceAlignmentBundle.load(from: url)
            guard bundle.rows.indices.contains(index) else { throw Primer3DesignError.invalidRequest("MSA row index \(index) is out of bounds for \(url.path)") }
            let alignedURL = url.appendingPathComponent("alignment/primary.aligned.fasta")
            let sequences = try readAlignedRows(at: alignedURL)
            try validateAlignedRows(sequences, bundle: bundle)
            guard sequences.indices.contains(index) else { throw Primer3DesignError.invalidRequest("MSA row metadata and aligned FASTA differ") }
            let aligned = sequences.map { $0.sequence.uppercased() }
            guard Set(aligned.map(\.count)).count == 1 else { throw Primer3DesignError.invalidRequest("MSA rows have unequal aligned lengths") }
            let projection = try prepareAlignedRows(aligned, selectedRow: index)
            return Primer3PreparedTemplate(inputID: UUID(), resultID: UUID(), title: bundle.rows[index].displayName, sequence: aligned[index].filter { $0 != "-" && $0 != "." }, sourceURL: url, sourceIndex: index, sourceRecordID: bundle.rows[index].id, sourceKind: .msa, bindingSitePolicy: policy, alignmentToTemplate: projection.alignmentToTemplate, excludedRegions: policy == .excludeVariableAndGappedColumns ? projection.excludedRegions : [])
        }
    }

    static func readAlignedRows(at url: URL, allowingRNAU: Bool = false) throws -> [Primer3AlignedRow] {
        let text: String
        if url.pathExtension.lowercased() == "gz" {
            text = try GzipInputStream(url: url).readAllSync()
        } else {
            guard let decoded = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                throw Primer3DesignError.invalidRequest("aligned FASTA is not UTF-8")
            }
            text = decoded
        }
        var rows: [Primer3AlignedRow] = [], title: String?, chunks: [String] = []
        let allowedSymbols = allowingRNAU ? "ACGTRYSWKMBDHVNU-." : "ACGTRYSWKMBDHVN-."
        func finish() throws {
            guard let currentTitle = title else { return }
            let sequence = chunks.joined()
            guard !sequence.isEmpty, sequence.uppercased().allSatisfy({ allowedSymbols.contains($0) }) else { throw Primer3DesignError.invalidRequest("aligned FASTA row \(currentTitle) is empty or contains unsupported symbols") }
            rows.append(.init(title: currentTitle, sequence: sequence))
        }
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix(">") {
                try finish()
                let header = line.dropFirst().trimmingCharacters(in: .whitespaces)
                guard !header.isEmpty else { throw Primer3DesignError.invalidRequest("aligned FASTA has an empty header") }
                title = header; chunks = []
            } else {
                guard title != nil else { throw Primer3DesignError.invalidRequest("aligned FASTA sequence appears before its header") }
                chunks.append(line.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: ""))
            }
        }
        try finish()
        guard !rows.isEmpty, Set(rows.map { $0.sequence.count }).count == 1 else { throw Primer3DesignError.invalidRequest("aligned FASTA rows must be nonempty and equal width") }
        return rows
    }

    /// Normalizes symbols that the PrimalScheme runtime cannot safely digest.
    ///
    /// `N` is an unknown/missing base in an alignment, so it is represented as
    /// an alignment gap for the runtime. This prevents the native k-mer
    /// digester from treating an unknown symbol as a concrete base while still
    /// preserving the column as missing coverage. RNA uracils are converted to
    /// DNA thymidines at the same execution boundary.
    static func normalizeForPrimalScheme(_ rows: [Primer3AlignedRow]) -> Primer3AlignedNormalization {
        var uracilCount = 0
        var unknownBaseCount = 0
        let normalized = rows.map { row in
            let sequence = String(row.sequence.map { character in
                switch character {
                case "U", "u":
                    uracilCount += 1
                    return "T"
                case "N", "n":
                    unknownBaseCount += 1
                    return "-"
                default:
                    return character
                }
            })
            return Primer3AlignedRow(title: row.title, sequence: sequence)
        }
        return Primer3AlignedNormalization(rows: normalized, uracilCount: uracilCount, unknownBaseCount: unknownBaseCount)
    }

    static func validateAlignedRows(_ alignedRows: [Primer3AlignedRow], bundle: MultipleSequenceAlignmentBundle) throws {
        guard bundle.manifest.rowCount == alignedRows.count, bundle.rows.count == alignedRows.count,
              alignedRows.allSatisfy({ $0.sequence.count == bundle.manifest.alignedLength }) else {
            throw Primer3DesignError.invalidRequest("MSA manifest dimensions disagree with primary aligned FASTA")
        }
        let coordinateMaps = try bundle.loadCoordinateMaps()
        guard coordinateMaps.count == alignedRows.count else { throw Primer3DesignError.invalidRequest("MSA coordinate-map count disagrees with primary aligned FASTA") }
        for (index, aligned) in alignedRows.enumerated() {
            let metadata = bundle.rows[index]
            let ungappedLength = aligned.sequence.filter { $0 != "-" && $0 != "." }.count
            var expectedAlignmentMap: [Int?] = [], expectedUngappedMap: [Int] = [], next = 0
            for (column, base) in aligned.sequence.enumerated() {
                if base == "-" || base == "." { expectedAlignmentMap.append(nil) }
                else { expectedAlignmentMap.append(next); expectedUngappedMap.append(column); next += 1 }
            }
            guard metadata.order == index, metadata.sourceName == aligned.title,
                  metadata.alignedLength == aligned.sequence.count, metadata.ungappedLength == ungappedLength,
                  metadata.checksumSHA256.caseInsensitiveCompare(MultipleSequenceAlignmentBundle.sha256Hex(for: Data(aligned.sequence.utf8))) == .orderedSame,
                  coordinateMaps[index].rowID == metadata.id, coordinateMaps[index].rowName == aligned.title,
                  coordinateMaps[index].alignedLength == aligned.sequence.count,
                  coordinateMaps[index].ungappedLength == ungappedLength,
                  coordinateMaps[index].alignmentToUngapped == expectedAlignmentMap,
                  coordinateMaps[index].ungappedToAlignment == expectedUngappedMap else {
                throw Primer3DesignError.invalidRequest("MSA row \(index) identity or coordinate metadata disagrees with primary aligned FASTA")
            }
        }
    }

    static func prepareAlignedRows(_ rows: [String], selectedRow: Int) throws -> Primer3AlignmentProjection {
        guard !rows.isEmpty, rows.indices.contains(selectedRow), Set(rows.map(\.count)).count == 1 else { throw Primer3DesignError.invalidRequest("aligned rows and selected row are invalid") }
        let matrix = rows.map(Array.init)
        var map: [Int?] = []
        var next = 0
        for base in matrix[selectedRow] {
            if base == "-" || base == "." { map.append(nil) } else { map.append(next); next += 1 }
        }
        var excluded = Set<Int>()
        for column in matrix[0].indices {
            let symbols = matrix.map { Character(String($0[column]).uppercased()) }
            let canonical = symbols.filter { "ACGT".contains($0) }
            let requiresExclusion = canonical.count != symbols.count || Set(canonical).count != 1
            guard requiresExclusion else { continue }
            if let coordinate = map[column] { excluded.insert(coordinate) }
            else {
                if let left = map[..<column].compactMap({ $0 }).last { excluded.insert(left) }
                if let right = map[(column + 1)...].compactMap({ $0 }).first { excluded.insert(right) }
            }
        }
        let sorted = excluded.sorted()
        var ranges: [Range<Int>] = []
        for value in sorted {
            if let last = ranges.last, last.upperBound == value { ranges[ranges.count - 1] = last.lowerBound..<(value + 1) }
            else { ranges.append(value..<(value + 1)) }
        }
        return Primer3AlignmentProjection(alignmentToTemplate: map, excludedRegions: ranges)
    }
}
