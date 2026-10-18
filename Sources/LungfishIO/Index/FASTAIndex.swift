// FASTAIndex.swift - FASTA index (.fai) support
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// A FASTA index (.fai) for random access to sequences.
///
/// The .fai format stores information about each sequence:
/// - NAME: Sequence name
/// - LENGTH: Total bases in sequence
/// - OFFSET: Byte offset of first base in file
/// - LINEBASES: Bases per line
/// - LINEWIDTH: Bytes per line (including newline)
///
/// ## Example
///
/// ```swift
/// let index = try FASTAIndex(url: faiURL)
/// print(index.sequenceNames)  // ["chr1", "chr2", ...]
/// print(index.length(of: "chr1"))  // 248956422
/// ```
public struct FASTAIndex: Sendable {
    /// Index entry for a single sequence
    public struct Entry: Sendable, Codable {
        /// Sequence name
        public let name: String
        /// Total length in bases
        public let length: Int
        /// Byte offset to first base in file
        public let offset: Int
        /// Bases per line (excluding newline)
        public let lineBases: Int
        /// Bytes per line (including newline)
        public let lineWidth: Int

        public init(name: String, length: Int, offset: Int, lineBases: Int, lineWidth: Int) {
            self.name = name
            self.length = length
            self.offset = offset
            self.lineBases = lineBases
            self.lineWidth = lineWidth
        }
    }

    /// Position in `orderedEntries` of each sequence name. A name listed twice maps to its last entry.
    private let positionByName: [String: Int]

    /// Ordered list of entries
    private let orderedEntries: [Entry]

    /// Names of all sequences in order
    public var sequenceNames: [String] {
        orderedEntries.map(\.name)
    }

    /// Number of sequences in the index
    public var count: Int {
        orderedEntries.count
    }

    /// Creates an index by loading from a .fai file.
    ///
    /// - Parameter url: The .fai file URL
    /// - Throws: `FASTAError.indexNotFound` or `FASTAError.invalidIndex`
    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FASTAError.indexNotFound(url)
        }

        // Reading the text as a string keeps the errors of a file that is not UTF-8. The lines are
        // then parsed from its UTF-8 bytes rather than split into grapheme clusters, which for an
        // index of 905,628 sequences took most of the parse.
        var content = try String(contentsOf: url, encoding: .utf8)
        content.makeContiguousUTF8()
        let entries = try content.utf8.withContiguousStorageIfAvailable(Self.parseEntries)
            ?? Array(content.utf8).withUnsafeBufferPointer(Self.parseEntries)

        var positionByName: [String: Int] = [:]
        positionByName.reserveCapacity(entries.count)
        for (position, entry) in entries.enumerated() {
            positionByName[entry.name] = position
        }

        self.orderedEntries = entries
        self.positionByName = positionByName
    }

    /// Creates an index from a list of entries.
    public init(entries: [Entry]) {
        self.orderedEntries = entries
        self.positionByName = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.name, $0) })
    }

    /// Returns the entry for a sequence by name.
    public func entry(for name: String) -> Entry? {
        positionByName[name].map { orderedEntries[$0] }
    }

    /// Returns the length of a sequence.
    public func length(of name: String) -> Int? {
        entry(for: name)?.length
    }

    /// The entries of a `.fai`, parsed from its UTF-8 bytes with the results of splitting its text at
    /// "\n" and each line at "\t". As there, an LF ends a line unless a CR comes right before it,
    /// since CR LF is one grapheme cluster. Empty lines and empty fields are skipped, fields after
    /// the fifth are ignored, and the line numbers in errors count non-empty lines only.
    private static func parseEntries(_ bytes: UnsafeBufferPointer<UInt8>) throws -> [Entry] {
        let lineFeed = UInt8(ascii: "\n")
        let carriageReturn = UInt8(ascii: "\r")
        let tab = UInt8(ascii: "\t")
        var entries: [Entry] = []
        var fields: [Range<Int>] = []
        fields.reserveCapacity(5)
        var lineNumber = 0
        var lineStart = 0

        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != lineFeed || (lineEnd > 0 && bytes[lineEnd - 1] == carriageReturn) {
                lineEnd += 1
            }
            let line = lineStart..<lineEnd
            lineStart = lineEnd + 1
            guard !line.isEmpty else { continue }
            lineNumber += 1

            fields.removeAll(keepingCapacity: true)
            var fieldStart = line.lowerBound
            for index in line.lowerBound...line.upperBound where index == line.upperBound || bytes[index] == tab {
                if index > fieldStart { fields.append(fieldStart..<index) }
                fieldStart = index + 1
                if fields.count == 5 { break }
            }
            guard fields.count == 5 else {
                throw FASTAError.invalidIndex("Line \(lineNumber): expected 5 tab-separated fields")
            }

            guard let length = integer(in: bytes, fields[1]),
                  let offset = integer(in: bytes, fields[2]),
                  let lineBases = integer(in: bytes, fields[3]),
                  let lineWidth = integer(in: bytes, fields[4]) else {
                throw FASTAError.invalidIndex("Line \(lineNumber): invalid numeric values")
            }

            entries.append(Entry(
                name: String(decoding: UnsafeBufferPointer(rebasing: bytes[fields[0]]), as: UTF8.self),
                length: length,
                offset: offset,
                lineBases: lineBases,
                lineWidth: lineWidth
            ))
        }
        return entries
    }

    /// The value `Int(_:)` gives for the field's text: an optional `+` or `-`, then one or more
    /// decimal digits, and nil when anything else appears or the value overflows.
    private static func integer(in bytes: UnsafeBufferPointer<UInt8>, _ field: Range<Int>) -> Int? {
        var index = field.lowerBound
        let isNegative = bytes[index] == UInt8(ascii: "-")
        if isNegative || bytes[index] == UInt8(ascii: "+") {
            index += 1
        }
        guard index < field.upperBound else { return nil }

        var value = 0
        while index < field.upperBound {
            let digit = Int(bytes[index]) - Int(UInt8(ascii: "0"))
            guard (0...9).contains(digit) else { return nil }
            let (shifted, shiftOverflow) = value.multipliedReportingOverflow(by: 10)
            let (next, digitOverflow) = isNegative
                ? shifted.subtractingReportingOverflow(digit)
                : shifted.addingReportingOverflow(digit)
            guard !shiftOverflow, !digitOverflow else { return nil }
            value = next
            index += 1
        }
        return value
    }

    /// Calculates the byte offset for a position within a sequence.
    ///
    /// - Parameters:
    ///   - position: 0-based position in the sequence
    ///   - entry: The index entry for the sequence
    /// - Returns: Byte offset in the file
    public func byteOffset(for position: Int, in entry: Entry) -> Int {
        let lineNumber = position / entry.lineBases
        let lineOffset = position % entry.lineBases
        return entry.offset + (lineNumber * entry.lineWidth) + lineOffset
    }

    /// Writes the index to a .fai file.
    ///
    /// - Parameter url: The output file URL
    public func write(to url: URL) throws {
        var content = ""
        for entry in orderedEntries {
            content += "\(entry.name)\t\(entry.length)\t\(entry.offset)\t\(entry.lineBases)\t\(entry.lineWidth)\n"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - IndexedFASTAReader

/// A FASTA reader with random access via .fai index.
///
/// IndexedFASTAReader allows fetching subsequences without reading the entire file.
/// This is essential for large reference genomes.
///
/// ## Example
///
/// ```swift
/// let reader = try IndexedFASTAReader(url: fastaURL)
/// let region = GenomicRegion(chromosome: "chr1", start: 1000, end: 2000)
/// let sequence = try await reader.fetch(region: region)
/// ```
public final class IndexedFASTAReader: Sendable {
    /// The FASTA file URL
    public let url: URL

    /// The loaded index
    public let index: FASTAIndex

    /// Creates an indexed FASTA reader.
    ///
    /// Looks for index at `<fastaPath>.fai`.
    ///
    /// - Parameter url: The FASTA file URL
    /// - Throws: `FASTAError.indexNotFound` if the .fai file doesn't exist
    public init(url: URL) throws {
        self.url = url
        let indexURL = url.appendingPathExtension("fai")
        self.index = try FASTAIndex(url: indexURL)
    }

    /// Creates an indexed FASTA reader with explicit index URL.
    ///
    /// - Parameters:
    ///   - url: The FASTA file URL
    ///   - indexURL: The .fai index file URL
    public init(url: URL, indexURL: URL) throws {
        self.url = url
        self.index = try FASTAIndex(url: indexURL)
    }

    /// Fetches a subsequence from the FASTA file.
    ///
    /// - Parameter region: The genomic region to fetch
    /// - Returns: The subsequence as a string
    /// - Throws: `FASTAError.regionOutOfBounds` if region exceeds sequence length
    public func fetch(region: GenomicRegion) async throws -> String {
        guard let entry = index.entry(for: region.chromosome) else {
            throw FASTAError.invalidIndex("Sequence '\(region.chromosome)' not found in index")
        }

        guard region.start >= 0 && region.end <= entry.length else {
            throw FASTAError.regionOutOfBounds(region, sequenceLength: entry.length)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // Calculate byte positions
        let startOffset = index.byteOffset(for: region.start, in: entry)
        let endOffset = index.byteOffset(for: region.end - 1, in: entry) + 1

        // Seek to start position
        try handle.seek(toOffset: UInt64(startOffset))

        // Read the required bytes
        let data = handle.readData(ofLength: endOffset - startOffset + entry.lineWidth)
        guard let rawSequence = String(data: data, encoding: .utf8) else {
            throw FASTAError.invalidEncoding
        }

        let sequence = Self.sequenceText(fromIndexedWindow: rawSequence)
        let clampedLength = min(region.length, sequence.count)

        return String(sequence.prefix(clampedLength))
    }

    /// Fetches a full sequence by name.
    ///
    /// - Parameter name: The sequence name
    /// - Returns: The full sequence
    public func fetchSequence(name: String) async throws -> Sequence {
        guard let entry = index.entry(for: name) else {
            throw FASTAError.invalidIndex("Sequence '\(name)' not found in index")
        }

        let region = GenomicRegion(chromosome: name, start: 0, end: entry.length)
        let bases = try await fetch(region: region)

        return try Sequence(
            name: name,
            alphabet: .dna,  // Assume DNA for reference sequences
            bases: bases
        )
    }

    /// Returns available sequence names.
    public var sequenceNames: [String] {
        index.sequenceNames
    }

    /// Fetches a subsequence from the FASTA file synchronously.
    ///
    /// This is useful when Swift Tasks are not executing properly in certain contexts.
    ///
    /// - Parameter region: The genomic region to fetch
    /// - Returns: The subsequence as a string
    /// - Throws: `FASTAError.regionOutOfBounds` if region exceeds sequence length
    public func fetchSync(region: GenomicRegion) throws -> String {
        guard let entry = index.entry(for: region.chromosome) else {
            throw FASTAError.invalidIndex("Sequence '\(region.chromosome)' not found in index")
        }

        guard region.start >= 0 && region.end <= entry.length else {
            throw FASTAError.regionOutOfBounds(region, sequenceLength: entry.length)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // Calculate byte positions
        let startOffset = index.byteOffset(for: region.start, in: entry)
        let endOffset = index.byteOffset(for: region.end - 1, in: entry) + 1

        // Seek to start position
        try handle.seek(toOffset: UInt64(startOffset))

        // Read the required bytes
        let data = handle.readData(ofLength: endOffset - startOffset + entry.lineWidth)
        guard let rawSequence = String(data: data, encoding: .utf8) else {
            throw FASTAError.invalidEncoding
        }

        let sequence = Self.sequenceText(fromIndexedWindow: rawSequence)
        let clampedLength = min(region.length, sequence.count)

        return String(sequence.prefix(clampedLength))
    }

    /// Strips FASTA line-wrapping newlines (LF and CR) from a raw indexed
    /// window of file bytes, leaving only sequence characters.
    ///
    /// Both LF and CR must be stripped, not just LF: a CRLF-terminated FASTA
    /// (common from Windows-edited references) otherwise leaves a stray `\r`
    /// in the sequence, shifting every base after it. Shared with
    /// ``BgzipIndexedFASTAReader``, which reads the same on-disk byte layout
    /// for bgzip-compressed FASTA.
    static func sequenceText(fromIndexedWindow rawSequence: String) -> String {
        String(String.UnicodeScalarView(rawSequence.unicodeScalars.filter { $0.value != 10 && $0.value != 13 }))
    }
}

// MARK: - FASTAIndexBuilder

/// Builds a FASTA index (.fai) from a FASTA file.
public struct FASTAIndexBuilder {
    /// Builds an index for a FASTA file.
    ///
    /// - Parameter url: The FASTA file URL
    /// - Returns: The generated index
    public static func build(for url: URL) throws -> FASTAIndex {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var entries: [FASTAIndex.Entry] = []
        var currentName: String?
        var currentOffset: Int?
        var currentLength = 0
        var currentLineBases: Int?
        var currentLineWidth: Int?
        var bytePosition = 0

        func appendCurrentEntry() {
            if let name = currentName,
               let offset = currentOffset,
               let lineBases = currentLineBases,
               let lineWidth = currentLineWidth {
                entries.append(FASTAIndex.Entry(
                    name: name,
                    length: currentLength,
                    offset: offset,
                    lineBases: lineBases,
                    lineWidth: lineWidth
                ))
            }
        }

        func processLine(_ rawLine: [UInt8], startOffset: Int, newlineWidth: Int) throws {
            var line = rawLine
            if line.last == 13 {
                line.removeLast()
            }

            guard !line.isEmpty else { return }

            if line.first == 62 { // ">"
                appendCurrentEntry()
                let headerBytes = line.dropFirst()
                guard let headerLine = String(bytes: headerBytes, encoding: .utf8) else {
                    throw FASTAError.invalidEncoding
                }
                currentName = parseIndexHeaderName(headerLine)
                currentOffset = nil
                currentLength = 0
                currentLineBases = nil
                currentLineWidth = nil
                return
            }

            guard currentName != nil else { return }

            if currentOffset == nil {
                currentOffset = startOffset
                currentLineBases = line.count
                currentLineWidth = line.count + newlineWidth
            }
            currentLength += line.count
        }

        let chunkSize = 64 * 1024
        var lineBuffer: [UInt8] = []
        lineBuffer.reserveCapacity(1024)
        var lineStartOffset = 0

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                break
            }

            for byte in chunk {
                bytePosition += 1
                if byte == 10 {
                    let newlineWidth = lineBuffer.last == 13 ? 2 : 1
                    try processLine(lineBuffer, startOffset: lineStartOffset, newlineWidth: newlineWidth)
                    lineBuffer.removeAll(keepingCapacity: true)
                    lineStartOffset = bytePosition
                } else {
                    lineBuffer.append(byte)
                }
            }
        }

        if !lineBuffer.isEmpty {
            try processLine(lineBuffer, startOffset: lineStartOffset, newlineWidth: 0)
        }

        appendCurrentEntry()

        return FASTAIndex(entries: entries)
    }

    /// Builds and writes an index for a FASTA file.
    ///
    /// - Parameters:
    ///   - url: The FASTA file URL
    ///   - outputURL: The output .fai URL (defaults to `<fastaPath>.fai`)
    public static func buildAndWrite(for url: URL, outputURL: URL? = nil) throws {
        let index = try build(for: url)
        let output = outputURL ?? url.appendingPathExtension("fai")
        try index.write(to: output)
    }

    private static func parseIndexHeaderName(_ header: String) -> String? {
        let trimmedHeader = header.trimmingCharacters(in: .whitespaces)
        guard !trimmedHeader.isEmpty else { return nil }
        guard let separator = trimmedHeader.firstIndex(where: isHeaderWhitespace) else {
            return trimmedHeader
        }
        return String(trimmedHeader[..<separator])
    }

    private static func isHeaderWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }
}
