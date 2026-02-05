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

    /// Entries indexed by sequence name
    private let entriesByName: [String: Entry]

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

        let content = try String(contentsOf: url, encoding: .utf8)
        var entries: [Entry] = []
        var byName: [String: Entry] = [:]

        for (lineNum, line) in content.split(separator: "\n").enumerated() {
            let parts = line.split(separator: "\t")
            guard parts.count >= 5 else {
                throw FASTAError.invalidIndex("Line \(lineNum + 1): expected 5 tab-separated fields")
            }

            guard let length = Int(parts[1]),
                  let offset = Int(parts[2]),
                  let lineBases = Int(parts[3]),
                  let lineWidth = Int(parts[4]) else {
                throw FASTAError.invalidIndex("Line \(lineNum + 1): invalid numeric values")
            }

            let entry = Entry(
                name: String(parts[0]),
                length: length,
                offset: offset,
                lineBases: lineBases,
                lineWidth: lineWidth
            )

            entries.append(entry)
            byName[entry.name] = entry
        }

        self.orderedEntries = entries
        self.entriesByName = byName
    }

    /// Creates an index from a list of entries.
    public init(entries: [Entry]) {
        self.orderedEntries = entries
        self.entriesByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
    }

    /// Returns the entry for a sequence by name.
    public func entry(for name: String) -> Entry? {
        entriesByName[name]
    }

    /// Returns the length of a sequence.
    public func length(of name: String) -> Int? {
        entriesByName[name]?.length
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

        // Remove newlines from the sequence
        let sequence = rawSequence.replacingOccurrences(of: "\n", with: "")
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

        // Remove newlines from the sequence
        let sequence = rawSequence.replacingOccurrences(of: "\n", with: "")
        let clampedLength = min(region.length, sequence.count)

        return String(sequence.prefix(clampedLength))
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

        guard let data = try handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            throw FASTAError.invalidEncoding
        }

        var entries: [FASTAIndex.Entry] = []
        var currentName: String?
        var currentOffset: Int?
        var currentLength = 0
        var currentLineBases: Int?
        var currentLineWidth: Int?
        var bytePosition = 0

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        for (_, line) in lines.enumerated() {
            let lineLength = line.utf8.count
            let lineWithNewline = lineLength + 1  // +1 for newline

            if line.hasPrefix(">") {
                // Save previous entry if exists
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

                // Start new sequence
                let headerLine = String(line.dropFirst())
                currentName = headerLine.split(separator: " ").first.map(String.init)
                currentOffset = nil
                currentLength = 0
                currentLineBases = nil
                currentLineWidth = nil

            } else if currentName != nil && !line.isEmpty {
                // Sequence line
                if currentOffset == nil {
                    currentOffset = bytePosition
                    currentLineBases = lineLength
                    currentLineWidth = lineWithNewline
                }
                currentLength += lineLength
            }

            bytePosition += lineWithNewline
        }

        // Don't forget the last entry
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
}
