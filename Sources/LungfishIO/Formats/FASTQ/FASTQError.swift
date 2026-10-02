// FASTQError.swift - Errors that can occur when parsing FASTQ files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - FASTQError

/// Errors that can occur when parsing FASTQ files.
public enum FASTQError: Error, LocalizedError, Sendable {

    /// Header line doesn't start with '@'
    case invalidHeader(line: Int, content: String)

    /// Separator line doesn't start with '+'
    case invalidSeparator(line: Int, content: String)

    /// Quality line length doesn't match sequence length
    case qualityLengthMismatch(line: Int, sequenceLength: Int, qualityLength: Int)

    /// Record is incomplete (missing fields)
    case incompleteRecord(line: Int)

    /// Invalid character in sequence
    case invalidSequenceCharacter(line: Int, character: String)

    /// Line exceeds maximum length
    case lineTooLong(line: Int, length: Int)

    /// Unexpected end of file
    case unexpectedEndOfFile

    /// File not found
    case fileNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader(let line, let content):
            return "Invalid FASTQ header at line \(line): '\(content.prefix(50))'"
        case .invalidSeparator(let line, let content):
            return "Invalid separator at line \(line): '\(content.prefix(50))'"
        case .qualityLengthMismatch(let line, let seqLen, let qualLen):
            return "Quality length (\(qualLen)) doesn't match sequence length (\(seqLen)) at line \(line)"
        case .incompleteRecord(let line):
            return "Incomplete FASTQ record at line \(line)"
        case .invalidSequenceCharacter(let line, let char):
            return "Invalid sequence character '\(char)' at line \(line)"
        case .lineTooLong(let line, let length):
            return "Line \(line) exceeds maximum length (\(length) characters)"
        case .unexpectedEndOfFile:
            return "Unexpected end of file (incomplete record)"
        case .fileNotFound(let url):
            return "FASTQ file not found: \(url.path)"
        }
    }
}
