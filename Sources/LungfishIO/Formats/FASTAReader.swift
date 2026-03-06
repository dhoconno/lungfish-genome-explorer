// FASTAReader.swift - FASTA file parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// A parser for FASTA format sequence files.
///
/// FASTAReader provides both streaming and indexed access to FASTA files.
/// For large files, use ``IndexedFASTAReader`` which requires an accompanying
/// .fai index file for random access.
///
/// ## File Format
///
/// FASTA files contain one or more sequences, each starting with a header line
/// beginning with `>`:
///
/// ```
/// >sequence_name optional description
/// ATCGATCGATCGATCG
/// ATCGATCGATCGATCG
/// >another_sequence
/// MKTAYIAKQRQISFVK
/// ```
///
/// ## Example
///
/// ```swift
/// let reader = try FASTAReader(url: fastaURL)
///
/// // Stream sequences
/// for try await sequence in reader.sequences() {
///     print("\(sequence.name): \(sequence.length) bp")
/// }
///
/// // Or read all at once
/// let allSequences = try await reader.readAll()
/// ```
public final class FASTAReader: Sendable {
    /// The file URL being read
    public let url: URL

    /// Whether the file is gzip compressed
    public let isCompressed: Bool

    /// Supported file extensions
    public static let supportedExtensions: Set<String> = [
        "fa", "fasta", "fna", "faa", "ffn", "frn",
        "fa.gz", "fasta.gz", "fna.gz", "faa.gz"
    ]

    /// Creates a FASTA reader for the specified file.
    ///
    /// - Parameter url: The file URL to read
    /// - Throws: `FASTAError.fileNotFound` if the file doesn't exist
    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FASTAError.fileNotFound(url)
        }
        self.url = url
        self.isCompressed = url.pathExtension == "gz"
    }

    /// Reads all sequences from the file.
    ///
    /// - Parameter alphabet: The expected alphabet (auto-detected if nil)
    /// - Returns: Array of sequences
    /// - Throws: `FASTAError` if parsing fails
    public func readAll(alphabet: SequenceAlphabet? = nil) async throws -> [Sequence] {
        // Directly parse the file - caller is responsible for running off main actor
        var sequences: [Sequence] = []
        try await parseFile(alphabet: alphabet) { sequence in
            sequences.append(sequence)
        }
        return sequences
    }

    /// Returns an async sequence of FASTA sequences.
    ///
    /// This is memory-efficient for large files as it yields sequences
    /// one at a time.
    ///
    /// - Parameter alphabet: The expected alphabet (auto-detected if nil)
    /// - Returns: An async stream of sequences
    public func sequences(alphabet: SequenceAlphabet? = nil) -> AsyncThrowingStream<Sequence, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.parseFile(alphabet: alphabet) { sequence in
                        continuation.yield(sequence)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Reads only the sequence headers (names and descriptions).
    ///
    /// This is much faster than reading full sequences as it skips sequence data.
    ///
    /// - Returns: Array of (name, description) tuples
    public func readHeaders() async throws -> [(name: String, description: String?)] {
        var headers: [(String, String?)] = []

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let data = try handle.readToEnd() else {
            return headers
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw FASTAError.invalidEncoding
        }

        // Normalize CR-LF to LF, then split on LF to handle both Unix and Windows line endings
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(">") {
                let headerLine = String(line.dropFirst())
                let (name, desc) = parseHeader(headerLine)
                headers.append((name, desc))
            }
        }

        return headers
    }

    // MARK: - Private Implementation

    private func parseFile(
        alphabet: SequenceAlphabet?,
        onSequence: @escaping (Sequence) -> Void
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let data = try handle.readToEnd() else {
            return
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw FASTAError.invalidEncoding
        }

        var currentName: String?
        var currentDescription: String?
        var currentBases = ""
        var lineNumber = 0

        // Normalize CR-LF to LF, then split on LF to handle both Unix and Windows line endings
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.isEmpty {
                continue
            }

            if trimmedLine.hasPrefix(">") {
                // Save previous sequence if exists
                if let name = currentName, !currentBases.isEmpty {
                    let seq = try createSequence(
                        name: name,
                        description: currentDescription,
                        bases: currentBases,
                        alphabet: alphabet,
                        lineNumber: lineNumber
                    )
                    onSequence(seq)
                }

                // Parse new header
                let headerLine = String(trimmedLine.dropFirst())
                (currentName, currentDescription) = parseHeader(headerLine)
                currentBases = ""

            } else if currentName != nil {
                // Accumulate sequence data
                currentBases += trimmedLine
            } else {
                throw FASTAError.sequenceBeforeHeader(line: lineNumber)
            }
        }

        // Don't forget the last sequence
        if let name = currentName, !currentBases.isEmpty {
            let seq = try createSequence(
                name: name,
                description: currentDescription,
                bases: currentBases,
                alphabet: alphabet,
                lineNumber: lineNumber
            )
            onSequence(seq)
        }
    }

    private func parseHeader(_ header: String) -> (name: String, description: String?) {
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let name = String(parts.first ?? "")
        let description = parts.count > 1 ? String(parts[1]) : nil
        return (name, description)
    }

    private func createSequence(
        name: String,
        description: String?,
        bases: String,
        alphabet: SequenceAlphabet?,
        lineNumber: Int
    ) throws -> Sequence {
        let detectedAlphabet = alphabet ?? detectAlphabet(bases)

        do {
            return try Sequence(
                name: name,
                description: description,
                alphabet: detectedAlphabet,
                bases: bases
            )
        } catch let error as SequenceError {
            throw FASTAError.invalidSequence(name: name, underlying: error)
        }
    }

    private func detectAlphabet(_ bases: String) -> SequenceAlphabet {
        let upper = bases.uppercased()

        // Check for protein-specific amino acids
        let proteinOnly = Set("EFILPQZ")
        for char in upper {
            if proteinOnly.contains(char) {
                return .protein
            }
        }

        // Check for U (RNA) vs T (DNA)
        let hasU = upper.contains("U")
        let hasT = upper.contains("T")

        if hasU && !hasT {
            return .rna
        }

        // Default to DNA
        return .dna
    }
}

// MARK: - FASTAError

/// Errors that can occur during FASTA parsing.
public enum FASTAError: Error, LocalizedError {
    case fileNotFound(URL)
    case invalidEncoding
    case sequenceBeforeHeader(line: Int)
    case invalidSequence(name: String, underlying: SequenceError)
    case indexNotFound(URL)
    case invalidIndex(String)
    case regionOutOfBounds(GenomicRegion, sequenceLength: Int)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "FASTA file not found: \(url.path)"
        case .invalidEncoding:
            return "FASTA file has invalid encoding (expected UTF-8)"
        case .sequenceBeforeHeader(let line):
            return "Sequence data found before header at line \(line)"
        case .invalidSequence(let name, let underlying):
            return "Invalid sequence '\(name)': \(underlying.localizedDescription)"
        case .indexNotFound(let url):
            return "FASTA index not found: \(url.path)"
        case .invalidIndex(let message):
            return "Invalid FASTA index: \(message)"
        case .regionOutOfBounds(let region, let length):
            return "Region \(region) exceeds sequence length \(length)"
        }
    }
}

// MARK: - FASTAWriter

/// A writer for FASTA format sequence files.
public final class FASTAWriter: Sendable {
    /// The file URL to write to
    public let url: URL

    /// Line width for sequence data (default: 60)
    public let lineWidth: Int

    /// Creates a FASTA writer for the specified file.
    ///
    /// - Parameters:
    ///   - url: The file URL to write
    ///   - lineWidth: Characters per line for sequence data
    public init(url: URL, lineWidth: Int = 60) {
        self.url = url
        self.lineWidth = lineWidth
    }

    /// Writes sequences to the file.
    ///
    /// - Parameter sequences: The sequences to write
    /// - Throws: If writing fails
    public func write(_ sequences: [Sequence]) throws {
        var content = ""

        for sequence in sequences {
            // Header line
            content += ">\(sequence.name)"
            if let desc = sequence.description {
                content += " \(desc)"
            }
            content += "\n"

            // Sequence data
            let bases = sequence.asString()
            for i in stride(from: 0, to: bases.count, by: lineWidth) {
                let start = bases.index(bases.startIndex, offsetBy: i)
                let end = bases.index(start, offsetBy: min(lineWidth, bases.count - i))
                content += String(bases[start..<end]) + "\n"
            }
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes a single sequence to the file (appending if it exists).
    ///
    /// - Parameter sequence: The sequence to write
    /// - Throws: If writing fails
    public func append(_ sequence: Sequence) throws {
        var content = ""

        // Header line
        content += ">\(sequence.name)"
        if let desc = sequence.description {
            content += " \(desc)"
        }
        content += "\n"

        // Sequence data
        let bases = sequence.asString()
        for i in stride(from: 0, to: bases.count, by: lineWidth) {
            let start = bases.index(bases.startIndex, offsetBy: i)
            let end = bases.index(start, offsetBy: min(lineWidth, bases.count - i))
            content += String(bases[start..<end]) + "\n"
        }

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(content.data(using: .utf8)!)
        } else {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
