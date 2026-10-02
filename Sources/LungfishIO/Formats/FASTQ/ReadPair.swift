// ReadPair.swift - Information about paired-end read relationships
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - ReadPair

/// Information about paired-end read relationships.
public struct ReadPair: Sendable, Equatable {

    /// The pair identifier (shared between read 1 and read 2)
    public let pairId: String

    /// Read number in pair (1 or 2)
    public let readNumber: Int

    /// Parses pair information from a read identifier.
    ///
    /// Supports common formats:
    /// - Illumina: `@INSTRUMENT:RUN:FLOWCELL:LANE:TILE:X:Y 1:N:0:SAMPLE`
    /// - Older: `@READ_ID/1` or `@READ_ID/2`
    ///
    /// - Parameter identifier: Read identifier
    /// - Returns: Pair information, or nil if not paired
    public static func parse(from identifier: String) -> ReadPair? {
        // Check for /1 or /2 suffix
        if identifier.hasSuffix("/1") {
            let pairId = String(identifier.dropLast(2))
            return ReadPair(pairId: pairId, readNumber: 1)
        }
        if identifier.hasSuffix("/2") {
            let pairId = String(identifier.dropLast(2))
            return ReadPair(pairId: pairId, readNumber: 2)
        }

        // Check for Illumina format with space separator
        // @INSTRUMENT:RUN:FLOWCELL:LANE:TILE:X:Y 1:N:0:SAMPLE
        if let spaceIndex = identifier.firstIndex(of: " ") {
            let afterSpace = identifier[identifier.index(after: spaceIndex)...]
            if afterSpace.hasPrefix("1:") {
                return ReadPair(pairId: String(identifier[..<spaceIndex]), readNumber: 1)
            }
            if afterSpace.hasPrefix("2:") {
                return ReadPair(pairId: String(identifier[..<spaceIndex]), readNumber: 2)
            }
        }

        return nil
    }
}
