// SRASearchResults.swift - Results from an SRA search
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import os.log

// MARK: - SRA Search Results

/// Results from an SRA search.
public struct SRASearchResults: Sendable {
    /// Total count of matching runs
    public let totalCount: Int

    /// SRA run information
    public let runs: [SRARunInfo]

    /// Whether more results are available
    public let hasMore: Bool

    public init(totalCount: Int, runs: [SRARunInfo], hasMore: Bool = false) {
        self.totalCount = totalCount
        self.runs = runs
        self.hasMore = hasMore
    }
}
