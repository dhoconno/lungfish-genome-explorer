// AlignmentConsensusRequest.swift - A reference-coordinate consensus request and its evidence filters
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

/// A reference-coordinate consensus request and its evidence filters.
public struct AlignmentConsensusRequest: Sendable, Equatable {
    public enum InsertionPolicy: String, Sendable {
        case omit
        case include
    }

    public enum DeletionPolicy: String, Sendable {
        case n
        case omit
    }

    public let chromosome: String
    public let start: Int
    public let end: Int
    public let filters: AlignmentConsensusFilters
    public let mode: AlignmentConsensusMode
    public let useAmbiguity: Bool
    public let insertionPolicy: InsertionPolicy
    public let deletionPolicy: DeletionPolicy

    public init(
        chromosome: String,
        start: Int,
        end: Int,
        filters: AlignmentConsensusFilters,
        mode: AlignmentConsensusMode,
        useAmbiguity: Bool,
        insertionPolicy: InsertionPolicy,
        deletionPolicy: DeletionPolicy
    ) {
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.filters = filters
        self.mode = mode
        self.useAmbiguity = useAmbiguity
        self.insertionPolicy = insertionPolicy
        self.deletionPolicy = deletionPolicy
    }
}
