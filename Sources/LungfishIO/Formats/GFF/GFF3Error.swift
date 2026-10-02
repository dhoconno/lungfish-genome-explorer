// GFF3Error.swift - Errors that can occur when parsing GFF3 files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - GFF3Error

/// Errors that can occur when parsing GFF3 files.
public enum GFF3Error: Error, LocalizedError, Sendable {

    /// Line has wrong number of fields
    case invalidLineFormat(line: Int, expected: Int, got: Int)

    /// Coordinate field is not a valid integer
    case invalidCoordinate(line: Int, field: String, value: String)

    /// Start coordinate is greater than end
    case invalidCoordinateRange(line: Int, start: Int, end: Int)

    /// Score field is not "." or a finite floating-point value
    case invalidScore(line: Int, value: String)

    /// Phase field is not "." or one of 0, 1, or 2
    case invalidPhase(line: Int, value: String)

    /// Parent feature not found
    case parentNotFound(line: Int, parentID: String)

    public var errorDescription: String? {
        switch self {
        case .invalidLineFormat(let line, let expected, let got):
            return "GFF3 line \(line): expected \(expected) fields, got \(got)"
        case .invalidCoordinate(let line, let field, let value):
            return "GFF3 line \(line): invalid \(field) coordinate '\(value)'"
        case .invalidCoordinateRange(let line, let start, let end):
            return "GFF3 line \(line): start (\(start)) > end (\(end))"
        case .invalidScore(let line, let value):
            return "GFF3 line \(line): invalid score '\(value)'"
        case .invalidPhase(let line, let value):
            return "GFF3 line \(line): invalid phase '\(value)'"
        case .parentNotFound(let line, let parentID):
            return "GFF3 line \(line): parent '\(parentID)' not found"
        }
    }
}
