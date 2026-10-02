// SamtoolsOutputParseError.swift - Errors raised by the static samtools output parsers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

/// Errors raised by the static samtools output parsers.
public enum SamtoolsOutputParseError: Error, LocalizedError, Sendable, Equatable {

    /// The output contained no parseable rows.
    case emptyOutput(String)

    /// An `idxstats` row did not have the four expected fields.
    case malformedIdxstatsRow(line: Int, content: String)

    /// The text was not valid JSON, or was JSON of an unexpected shape.
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .emptyOutput(let tool):
            return "samtools \(tool) produced no parseable output"
        case .malformedIdxstatsRow(let line, let content):
            return "samtools idxstats line \(line) is malformed: '\(content)'"
        case .invalidJSON(let detail):
            return "samtools flagstat JSON could not be parsed: \(detail)"
        }
    }
}
