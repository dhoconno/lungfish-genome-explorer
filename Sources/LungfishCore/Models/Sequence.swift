// Sequence.swift - Core sequence representation with 2-bit encoding
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A biological sequence with memory-efficient storage.
///
/// For DNA sequences, uses 2-bit encoding where each base requires only 2 bits:
/// - A = 00
/// - C = 01
/// - G = 10
/// - T = 11
///
/// This reduces memory usage by 4x compared to storing characters directly.
/// Ambiguous bases (N, R, Y, etc.) are stored in a separate sparse structure.
///
/// ## Example
/// ```swift
/// let seq = try Sequence(name: "my_dna", alphabet: .dna, bases: "ATCGATCG")
/// print(seq.length)  // 8
/// print(seq[0..<4])  // "ATCG"
/// ```
public struct Sequence: Identifiable, Hashable, Sendable {
    /// Unique identifier for this sequence
    public let id: UUID

    /// Name of the sequence (e.g., chromosome name, accession)
    public var name: String

    /// Description or definition line
    public var description: String?

    /// The sequence alphabet (DNA, RNA, or protein)
    public let alphabet: SequenceAlphabet

    /// Internal storage for the sequence data
    private let storage: SequenceStorage

    /// Length of the sequence in bases/residues
    public var length: Int {
        storage.length
    }

    /// Whether the sequence is circular
    public var isCircular: Bool = false

    /// Quality scores for each base (optional, typically from FASTQ files).
    ///
    /// Each value represents a Phred quality score (0-93), where:
    /// - Q10: 10% error rate (1 in 10 wrong)
    /// - Q20: 1% error rate (1 in 100 wrong)
    /// - Q30: 0.1% error rate (1 in 1000 wrong)
    /// - Q40: 0.01% error rate (1 in 10000 wrong)
    ///
    /// This property is `nil` for sequences loaded from formats that don't
    /// include quality information (e.g., FASTA, GenBank).
    public var qualityScores: [UInt8]?

    /// Creates a new sequence from a string of bases.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (auto-generated if not provided)
    ///   - name: Sequence name
    ///   - description: Optional description
    ///   - alphabet: The sequence alphabet
    ///   - bases: String of bases/residues
    ///   - qualityScores: Optional quality scores for each base (from FASTQ)
    /// - Throws: `SequenceError.invalidCharacter` if bases contain invalid characters
    public init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        alphabet: SequenceAlphabet,
        bases: String,
        qualityScores: [UInt8]? = nil
    ) throws {
        self.id = id
        self.name = name
        self.description = description
        self.alphabet = alphabet
        self.storage = try SequenceStorage(bases: bases, alphabet: alphabet)
        self.qualityScores = qualityScores
    }

    /// Creates a new sequence from raw storage (internal use).
    internal init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        alphabet: SequenceAlphabet,
        storage: SequenceStorage,
        qualityScores: [UInt8]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.alphabet = alphabet
        self.storage = storage
        self.qualityScores = qualityScores
    }

    /// Access a subsequence by range
    public subscript(range: Range<Int>) -> String {
        storage.subsequence(range: range)
    }

    /// Access a single base at an index
    public subscript(index: Int) -> Character {
        storage.base(at: index)
    }

    /// Returns the entire sequence as a string
    public func asString() -> String {
        storage.subsequence(range: 0..<length)
    }

    /// Returns the complement of this sequence (DNA/RNA only)
    public func complement() -> Sequence? {
        guard alphabet.supportsComplement else { return nil }
        guard let complementedStorage = storage.complement(using: alphabet) else { return nil }
        return Sequence(
            id: UUID(),
            name: "\(name)_complement",
            description: description,
            alphabet: alphabet,
            storage: complementedStorage,
            qualityScores: qualityScores
        )
    }

    /// Returns the reverse complement of this sequence (DNA/RNA only)
    public func reverseComplement() -> Sequence? {
        guard alphabet.supportsComplement else { return nil }
        guard let rcStorage = storage.reverseComplement(using: alphabet) else { return nil }
        // Reverse quality scores along with the sequence
        let reversedQuality = qualityScores?.reversed().map { $0 }
        return Sequence(
            id: UUID(),
            name: "\(name)_rc",
            description: description,
            alphabet: alphabet,
            storage: rcStorage,
            qualityScores: reversedQuality.map { Array($0) }
        )
    }

    /// Returns a subsequence as a new Sequence object
    public func subsequence(region: GenomicRegion) throws -> Sequence {
        let subStorage = try storage.subsequence(startIndex: region.start, length: region.length)
        // Extract quality scores for the subsequence region if available
        let subQuality: [UInt8]?
        if let quality = qualityScores {
            let start = max(0, region.start)
            let end = min(quality.count, region.end)
            if start < end {
                subQuality = Array(quality[start..<end])
            } else {
                subQuality = nil
            }
        } else {
            subQuality = nil
        }
        return Sequence(
            id: UUID(),
            name: "\(name):\(region.start)-\(region.end)",
            description: nil,
            alphabet: alphabet,
            storage: subStorage,
            qualityScores: subQuality
        )
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: Sequence, rhs: Sequence) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - SequenceStorage

/// Internal storage for sequence data using 2-bit encoding for DNA.
internal struct SequenceStorage: Hashable, Sendable {
    /// Packed data: 4 bases per byte for DNA
    private let packedData: [UInt8]

    /// Positions and values of ambiguous bases (N, R, Y, etc.)
    private let ambiguousBases: [Int: Character]

    /// Total length in bases
    let length: Int

    /// The alphabet used for encoding
    private let alphabet: SequenceAlphabet

    /// 2-bit encoding for DNA bases
    private static let dnaEncode: [Character: UInt8] = [
        "A": 0b00, "a": 0b00,
        "C": 0b01, "c": 0b01,
        "G": 0b10, "g": 0b10,
        "T": 0b11, "t": 0b11
    ]

    /// Decode from 2-bit to character
    private static let dnaDecode: [Character] = ["A", "C", "G", "T"]

    init(bases: String, alphabet: SequenceAlphabet) throws {
        self.alphabet = alphabet
        self.length = bases.count

        var packed: [UInt8] = []
        var ambiguous: [Int: Character] = [:]

        if alphabet == .dna || alphabet == .rna {
            // Use 2-bit encoding for DNA/RNA
            var currentByte: UInt8 = 0
            var bitPosition = 0

            for (index, char) in bases.enumerated() {
                let base = (alphabet == .rna && char == "U") ? Character("T") :
                           (alphabet == .rna && char == "u") ? Character("t") : char

                if let encoded = Self.dnaEncode[base] {
                    currentByte |= (encoded << (6 - bitPosition))
                    bitPosition += 2

                    if bitPosition == 8 {
                        packed.append(currentByte)
                        currentByte = 0
                        bitPosition = 0
                    }
                } else if alphabet.validCharacters.contains(char) {
                    // Ambiguous base - store separately
                    ambiguous[index] = char
                    // Still need to advance in packed array (use A as placeholder)
                    bitPosition += 2
                    if bitPosition == 8 {
                        packed.append(currentByte)
                        currentByte = 0
                        bitPosition = 0
                    }
                } else {
                    throw SequenceError.invalidCharacter(char, position: index)
                }
            }

            // Append remaining partial byte
            if bitPosition > 0 {
                packed.append(currentByte)
            }
        } else {
            // For protein, store directly as ASCII bytes
            for (index, char) in bases.enumerated() {
                if alphabet.validCharacters.contains(char) {
                    packed.append(UInt8(char.asciiValue ?? 0))
                } else {
                    throw SequenceError.invalidCharacter(char, position: index)
                }
            }
        }

        self.packedData = packed
        self.ambiguousBases = ambiguous
    }

    /// Creates storage from existing packed data (internal use)
    private init(packedData: [UInt8], ambiguousBases: [Int: Character], length: Int, alphabet: SequenceAlphabet) {
        self.packedData = packedData
        self.ambiguousBases = ambiguousBases
        self.length = length
        self.alphabet = alphabet
    }

    /// Get a single base at the specified index
    func base(at index: Int) -> Character {
        precondition(index >= 0 && index < length, "Index out of bounds")

        // Check for ambiguous base first
        if let ambig = ambiguousBases[index] {
            let result = alphabet == .rna && ambig == "T" ? Character("U") :
                         alphabet == .rna && ambig == "t" ? Character("u") : ambig
            return result
        }

        if alphabet == .dna || alphabet == .rna {
            let byteIndex = index / 4
            let bitOffset = (index % 4) * 2
            let encoded = (packedData[byteIndex] >> (6 - bitOffset)) & 0b11
            var base = Self.dnaDecode[Int(encoded)]
            if alphabet == .rna && base == "T" {
                base = "U"
            }
            return base
        } else {
            return Character(UnicodeScalar(packedData[index]))
        }
    }

    /// Get a subsequence as a string
    func subsequence(range: Range<Int>) -> String {
        let clampedRange = max(0, range.lowerBound)..<min(length, range.upperBound)
        var result = ""
        result.reserveCapacity(clampedRange.count)
        for i in clampedRange {
            result.append(base(at: i))
        }
        return result
    }

    /// Create a new storage for a subsequence
    func subsequence(startIndex: Int, length subLength: Int) throws -> SequenceStorage {
        let bases = subsequence(range: startIndex..<(startIndex + subLength))
        return try SequenceStorage(bases: bases, alphabet: alphabet)
    }

    /// Returns complemented storage
    func complement(using alphabet: SequenceAlphabet) -> SequenceStorage? {
        guard let complementMap = alphabet.complementMap else { return nil }

        var result = ""
        result.reserveCapacity(length)
        for i in 0..<length {
            let original = base(at: i)
            if let comp = complementMap[original] {
                result.append(comp)
            } else {
                result.append(original)
            }
        }

        return try? SequenceStorage(bases: result, alphabet: alphabet)
    }

    /// Returns reverse complemented storage
    func reverseComplement(using alphabet: SequenceAlphabet) -> SequenceStorage? {
        guard let complementMap = alphabet.complementMap else { return nil }

        var result = ""
        result.reserveCapacity(length)
        for i in stride(from: length - 1, through: 0, by: -1) {
            let original = base(at: i)
            if let comp = complementMap[original] {
                result.append(comp)
            } else {
                result.append(original)
            }
        }

        return try? SequenceStorage(bases: result, alphabet: alphabet)
    }
}

// MARK: - SequenceError

/// Errors that can occur during sequence operations
public enum SequenceError: Error, LocalizedError {
    case invalidCharacter(Character, position: Int)
    case invalidRange(Range<Int>)
    case alphabetMismatch(expected: SequenceAlphabet, got: SequenceAlphabet)
    case emptySequence

    public var errorDescription: String? {
        switch self {
        case .invalidCharacter(let char, let pos):
            return "Invalid character '\(char)' at position \(pos)"
        case .invalidRange(let range):
            return "Invalid range: \(range)"
        case .alphabetMismatch(let expected, let got):
            return "Alphabet mismatch: expected \(expected), got \(got)"
        case .emptySequence:
            return "Sequence cannot be empty"
        }
    }
}
