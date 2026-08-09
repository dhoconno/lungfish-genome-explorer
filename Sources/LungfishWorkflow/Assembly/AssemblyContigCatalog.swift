// AssemblyContigCatalog.swift - Indexed contig catalog for managed assemblies
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public struct AssemblyContigRecord: Sendable, Equatable {
    public let rank: Int
    public let name: String
    public let header: String
    public let lengthBP: Int64
    public let gcPercent: Double
    public let shareOfAssemblyPercent: Double
    public let previewSequence: String

    public init(
        rank: Int,
        name: String,
        header: String,
        lengthBP: Int64,
        gcPercent: Double,
        shareOfAssemblyPercent: Double,
        previewSequence: String = ""
    ) {
        self.rank = rank
        self.name = name
        self.header = header
        self.lengthBP = lengthBP
        self.gcPercent = gcPercent
        self.shareOfAssemblyPercent = shareOfAssemblyPercent
        self.previewSequence = previewSequence
    }
}

public struct AssemblyContigSelectionSummary: Sendable, Equatable {
    public let selectedContigCount: Int
    public let totalSelectedBP: Int64
    public let longestContigBP: Int64
    public let shortestContigBP: Int64
    public let lengthWeightedGCPercent: Double
}

public struct AssemblyContigCatalog: Sendable {
    private struct ContigMetadata: Sendable {
        let order: Int
        let name: String
        let header: String
        let lengthBP: Int64
        let gcBases: Int64
        let gcPercent: Double
        let shareOfAssemblyPercent: Double
        let previewSequence: String
    }

    private let reader: IndexedFASTAReader
    private let contigsByName: [String: ContigMetadata]
    private let rankedRecords: [AssemblyContigRecord]

    public init(result: AssemblyResult) async throws {
        let indexURL = try Self.ensureFASTAIndexExists(for: result.contigsPath)
        self.reader = try IndexedFASTAReader(url: result.contigsPath, indexURL: indexURL)
        try Self.validateUniqueSequenceNames(reader.sequenceNames)

        let headersByName = try Self.parseHeaders(from: result.contigsPath)
        let fileHandle = try FileHandle(forReadingFrom: result.contigsPath)
        defer { try? fileHandle.close() }

        var contigs: [ContigMetadata] = []
        contigs.reserveCapacity(reader.sequenceNames.count)

        for (order, name) in reader.sequenceNames.enumerated() {
            guard let entry = reader.index.entry(for: name) else {
                throw AssemblyContigCatalogError.contigNotFound(name)
            }
            guard let header = headersByName[name] else {
                throw AssemblyContigCatalogError.contigNotFound(name)
            }
            let lengthBP = Int64(entry.length)
            let gcBases: Int64
            let previewSequence: String
            if lengthBP == 0 {
                gcBases = 0
                previewSequence = ""
            } else {
                // Stream the contig's sequence bytes directly from the FASTA index's known
                // byte range (skipping line-wrap newlines) to count G/C bases, rather than
                // materializing the full contig sequence as a String via
                // IndexedFASTAReader.fetchSequence. Avoids buffering megabase-scale contigs
                // in memory just to compute a summary-catalog GC percentage (R3-R3ML-1).
                gcBases = try Self.gcBaseCount(for: entry, fileHandle: fileHandle)
                previewSequence = try await Self.previewSequence(
                    reader: reader,
                    name: name,
                    entryLength: entry.length
                )
            }
            contigs.append(
                ContigMetadata(
                    order: order,
                    name: name,
                    header: header,
                    lengthBP: lengthBP,
                    gcBases: gcBases,
                    gcPercent: Self.gcPercent(gcBases: gcBases, totalBases: lengthBP),
                    shareOfAssemblyPercent: Self.shareOfAssemblyPercent(
                        lengthBP: lengthBP,
                        totalAssemblyBP: result.statistics.totalLengthBP
                    ),
                    previewSequence: previewSequence
                )
            )
        }

        var contigsByName: [String: ContigMetadata] = [:]
        contigsByName.reserveCapacity(contigs.count)
        for contig in contigs {
            if contigsByName[contig.name] != nil {
                throw AssemblyContigCatalogError.duplicateContigName(contig.name)
            }
            contigsByName[contig.name] = contig
        }
        self.contigsByName = contigsByName
        let ranked = contigs.sorted {
            if $0.lengthBP != $1.lengthBP {
                return $0.lengthBP > $1.lengthBP
            }
            return $0.order < $1.order
        }
        self.rankedRecords = ranked.enumerated().map { index, contig in
            AssemblyContigRecord(
                rank: index + 1,
                name: contig.name,
                header: contig.header,
                lengthBP: contig.lengthBP,
                gcPercent: contig.gcPercent,
                shareOfAssemblyPercent: contig.shareOfAssemblyPercent,
                previewSequence: contig.previewSequence
            )
        }
    }

    private static func ensureFASTAIndexExists(for fastaURL: URL) throws -> URL {
        let indexURL = fastaURL.appendingPathExtension("fai")
        if !FileManager.default.fileExists(atPath: indexURL.path) {
            try FASTAIndexBuilder.buildAndWrite(for: fastaURL, outputURL: indexURL)
        }
        return indexURL
    }

    public func records() async throws -> [AssemblyContigRecord] {
        rankedRecords
    }

    public func sequenceFASTA(for contigName: String, lineWidth: Int = 60) async throws -> String {
        guard let contig = contigsByName[contigName] else {
            throw AssemblyContigCatalogError.contigNotFound(contigName)
        }
        if contig.lengthBP == 0 {
            return Self.formatFASTA(header: contig.header, sequence: "", lineWidth: lineWidth)
        }

        let sequence = try await reader.fetchSequence(name: contig.name)
        return Self.formatFASTA(header: contig.header, sequence: sequence.asString(), lineWidth: lineWidth)
    }

    public func sequenceFASTAs(for contigNames: [String], lineWidth: Int = 60) async throws -> [String] {
        var outputs: [String] = []
        outputs.reserveCapacity(contigNames.count)
        for name in contigNames {
            outputs.append(try await sequenceFASTA(for: name, lineWidth: lineWidth))
        }
        return outputs
    }

    public func selectionSummary(for contigNames: [String]) async throws -> AssemblyContigSelectionSummary {
        guard !contigNames.isEmpty else {
            return AssemblyContigSelectionSummary(
                selectedContigCount: 0,
                totalSelectedBP: 0,
                longestContigBP: 0,
                shortestContigBP: 0,
                lengthWeightedGCPercent: 0
            )
        }

        var totalSelectedBP: Int64 = 0
        var gcBases: Int64 = 0
        var longestContigBP: Int64 = 0
        var shortestContigBP: Int64?

        for name in contigNames {
            guard let contig = contigsByName[name] else {
                throw AssemblyContigCatalogError.contigNotFound(name)
            }

            totalSelectedBP += contig.lengthBP
            gcBases += contig.gcBases
            longestContigBP = max(longestContigBP, contig.lengthBP)
            shortestContigBP = min(shortestContigBP ?? contig.lengthBP, contig.lengthBP)
        }

        let lengthWeightedGCPercent = totalSelectedBP > 0
            ? (Double(gcBases) / Double(totalSelectedBP)) * 100.0
            : 0

        return AssemblyContigSelectionSummary(
            selectedContigCount: contigNames.count,
            totalSelectedBP: totalSelectedBP,
            longestContigBP: longestContigBP,
            shortestContigBP: shortestContigBP ?? 0,
            lengthWeightedGCPercent: lengthWeightedGCPercent
        )
    }

    static func parseHeaders(from fastaURL: URL) throws -> [String: String] {
        let handle = try FileHandle(forReadingFrom: fastaURL)
        defer { try? handle.close() }

        let bufferSize = 256 * 1024
        var bufferedData = Data()
        var headersByName: [String: String] = [:]

        while true {
            guard let chunk = try handle.read(upToCount: bufferSize) else { break }
            if chunk.isEmpty { break }

            bufferedData.append(chunk)
            var lineStartIndex = bufferedData.startIndex

            while let newlineIndex = bufferedData[lineStartIndex...].firstIndex(of: 0x0A) {
                try registerHeaderIfNeeded(
                    from: bufferedData.subdata(in: lineStartIndex..<newlineIndex),
                    headersByName: &headersByName
                )
                lineStartIndex = bufferedData.index(after: newlineIndex)
            }

            if lineStartIndex > bufferedData.startIndex {
                bufferedData.removeSubrange(bufferedData.startIndex..<lineStartIndex)
            }
        }

        if !bufferedData.isEmpty {
            try registerHeaderIfNeeded(from: bufferedData, headersByName: &headersByName)
        }

        return headersByName
    }

    private static func registerHeaderIfNeeded(
        from lineData: Data,
        headersByName: inout [String: String]
    ) throws {
        guard var line = String(data: lineData, encoding: .utf8) else {
            throw AssemblyContigCatalogError.invalidEncoding
        }
        if line.hasSuffix("\r") {
            line.removeLast()
        }

        guard line.hasPrefix(">") else { return }

        let header = String(line.dropFirst())
        let keys = headerLookupKeys(for: header)
        guard let primaryKey = keys.first else {
            throw AssemblyContigCatalogError.invalidHeader(header)
        }

        headersByName[primaryKey] = header
        for aliasKey in keys.dropFirst() where headersByName[aliasKey] == nil {
            headersByName[aliasKey] = header
        }
    }

    private static func headerLookupKeys(for header: String) -> [String] {
        guard let spaceToken = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init),
              !spaceToken.isEmpty else {
            return []
        }

        if let tabToken = spaceToken.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init),
           !tabToken.isEmpty,
           tabToken != spaceToken {
            return [spaceToken, tabToken]
        }

        return [spaceToken]
    }

    private static func validateUniqueSequenceNames(_ names: [String]) throws {
        var seen: Set<String> = []
        seen.reserveCapacity(names.count)

        for name in names {
            if !seen.insert(name).inserted {
                throw AssemblyContigCatalogError.duplicateContigName(name)
            }
        }
    }

    private static func gcPercent(gcBases: Int64, totalBases: Int64) -> Double {
        guard totalBases > 0 else { return 0 }
        return (Double(gcBases) / Double(totalBases)) * 100.0
    }

    /// Counts G/C bases for a single FASTA index entry by seeking directly to its known byte
    /// range and streaming the sequence bytes in bounded chunks, skipping the line-wrap
    /// newline bytes the .fai `lineBases`/`lineWidth` fields describe. Never materializes the
    /// contig's full base sequence as a `String` (see the call site's R3-R3ML-1 note).
    private static func gcBaseCount(for entry: FASTAIndex.Entry, fileHandle: FileHandle) throws -> Int64 {
        guard entry.length > 0, entry.lineBases > 0 else { return 0 }

        // Matches FASTAIndex.byteOffset(for:in:)'s addressing exactly: the byte span from the
        // entry's start offset up to (but not including) one past the last base's byte -- i.e.
        // the same [startOffset, endOffset) range fetch(region:) reads, computed without going
        // through fetch/fetchSequence so no base String is ever materialized here.
        let lastBasePosition = entry.length - 1
        let lastBaseLineNumber = lastBasePosition / entry.lineBases
        let lastBaseLineOffset = lastBasePosition % entry.lineBases
        let totalByteSpan = (lastBaseLineNumber * entry.lineWidth) + lastBaseLineOffset + 1

        try fileHandle.seek(toOffset: UInt64(entry.offset))

        let chunkSize = 256 * 1024
        var remainingBytes = totalByteSpan
        var gcBases: Int64 = 0

        while remainingBytes > 0 {
            let readSize = min(chunkSize, remainingBytes)
            guard let chunk = try fileHandle.read(upToCount: readSize), !chunk.isEmpty else { break }
            remainingBytes -= chunk.count

            for byte in chunk {
                // Newline/CR bytes are line-wrap formatting, not sequence data -- the entry's
                // byte span includes them (lineWidth > lineBases), so skip without counting
                // them toward GC content.
                switch byte {
                case UInt8(ascii: "G"), UInt8(ascii: "g"), UInt8(ascii: "C"), UInt8(ascii: "c"):
                    gcBases += 1
                default:
                    break
                }
            }
        }

        return gcBases
    }

    private static func shareOfAssemblyPercent(lengthBP: Int64, totalAssemblyBP: Int64) -> Double {
        guard totalAssemblyBP > 0 else { return 0 }
        return (Double(lengthBP) / Double(totalAssemblyBP)) * 100.0
    }

    private static func previewSequence(
        reader: IndexedFASTAReader,
        name: String,
        entryLength: Int,
        maxBases: Int = 80
    ) async throws -> String {
        guard entryLength > 0 else { return "" }
        let previewLength = min(entryLength, maxBases)
        let region = GenomicRegion(chromosome: name, start: 0, end: previewLength)
        let prefix = try await reader.fetch(region: region)
        guard entryLength > maxBases else { return prefix }
        return prefix + "…"
    }

    private static func formatFASTA(header: String, sequence: String, lineWidth: Int) -> String {
        var output = ">\(header)\n"
        guard !sequence.isEmpty else { return output }
        guard lineWidth > 0 else {
            output += sequence + "\n"
            return output
        }

        var index = sequence.startIndex
        while index < sequence.endIndex {
            let endIndex = sequence.index(index, offsetBy: lineWidth, limitedBy: sequence.endIndex) ?? sequence.endIndex
            output += String(sequence[index..<endIndex]) + "\n"
            index = endIndex
        }
        return output
    }
}

private enum AssemblyContigCatalogError: Error, LocalizedError {
    case contigNotFound(String)
    case duplicateContigName(String)
    case invalidHeader(String)
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .contigNotFound(let name):
            return "Contig not found: \(name)"
        case .duplicateContigName(let name):
            return "Duplicate contig name in FASTA index: \(name)"
        case .invalidHeader(let header):
            return "Invalid FASTA header: \(header)"
        case .invalidEncoding:
            return "Assembly contig FASTA has invalid encoding (expected UTF-8)"
        }
    }
}
