// SequenceAlphabet.swift - Sequence type definitions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Defines the type of biological sequence.
public enum SequenceAlphabet: String, Codable, Sendable, CaseIterable {
    /// DNA sequence (A, T, G, C, N)
    case dna
    /// RNA sequence (A, U, G, C, N)
    case rna
    /// Protein/amino acid sequence
    case protein

    /// Valid characters for this alphabet
    public var validCharacters: Set<Character> {
        switch self {
        case .dna:
            return Set("ATGCNatgcnRYSWKMBDHVryswkmbdhv")
        case .rna:
            return Set("AUGCNaugcnRYSWKMBDHVryswkmbdhv")
        case .protein:
            return Set("ACDEFGHIKLMNPQRSTVWYacdefghiklmnpqrstvwy*X")
        }
    }

    /// The complement mapping for nucleotide sequences
    public var complementMap: [Character: Character]? {
        switch self {
        case .dna:
            return [
                "A": "T", "T": "A", "G": "C", "C": "G",
                "a": "t", "t": "a", "g": "c", "c": "g",
                "N": "N", "n": "n",
                "R": "Y", "Y": "R", "S": "S", "W": "W",
                "K": "M", "M": "K", "B": "V", "V": "B",
                "D": "H", "H": "D",
                "r": "y", "y": "r", "s": "s", "w": "w",
                "k": "m", "m": "k", "b": "v", "v": "b",
                "d": "h", "h": "d"
            ]
        case .rna:
            return [
                "A": "U", "U": "A", "G": "C", "C": "G",
                "a": "u", "u": "a", "g": "c", "c": "g",
                "N": "N", "n": "n",
                "R": "Y", "Y": "R", "S": "S", "W": "W",
                "K": "M", "M": "K", "B": "V", "V": "B",
                "D": "H", "H": "D",
                "r": "y", "y": "r", "s": "s", "w": "w",
                "k": "m", "m": "k", "b": "v", "v": "b",
                "d": "h", "h": "d"
            ]
        case .protein:
            return nil
        }
    }

    /// Whether this alphabet supports complement operations
    public var supportsComplement: Bool {
        complementMap != nil
    }

    /// Whether this alphabet can be translated to protein
    public var canTranslate: Bool {
        self == .dna || self == .rna
    }
}

/// Strand orientation for genomic features
public enum Strand: String, Codable, Sendable {
    case forward = "+"
    case reverse = "-"
    case unknown = "."

    /// Returns the opposite strand
    public var opposite: Strand {
        switch self {
        case .forward: return .reverse
        case .reverse: return .forward
        case .unknown: return .unknown
        }
    }
}

/// Reading frame for translation (6-frame: three forward, three reverse).
public enum ReadingFrame: String, CaseIterable, Sendable, Codable {
    case plus1 = "+1"
    case plus2 = "+2"
    case plus3 = "+3"
    case minus1 = "-1"
    case minus2 = "-2"
    case minus3 = "-3"

    /// The offset from the sequence start (0, 1, or 2).
    public var offset: Int {
        switch self {
        case .plus1, .minus1: return 0
        case .plus2, .minus2: return 1
        case .plus3, .minus3: return 2
        }
    }

    /// Whether this is a reverse strand frame.
    public var isReverse: Bool {
        switch self {
        case .plus1, .plus2, .plus3: return false
        case .minus1, .minus2, .minus3: return true
        }
    }

    /// Forward frames only.
    public static var forwardFrames: [ReadingFrame] {
        [.plus1, .plus2, .plus3]
    }

    /// Reverse frames only.
    public static var reverseFrames: [ReadingFrame] {
        [.minus1, .minus2, .minus3]
    }
}
