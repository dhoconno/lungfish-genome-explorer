// AlignmentConsensusFilters.swift - The effective read filters applied to both consensus calling and depth
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

/// The effective read filters applied to both consensus calling and depth.
public struct AlignmentConsensusFilters: Sendable, Equatable {
    public let minimumDepth: Int
    public let minimumMapQ: Int
    public let minimumBaseQuality: Int
    public let excludedFlags: UInt16
    public let readGroups: Set<String>

    public init(
        minimumDepth: Int,
        minimumMapQ: Int,
        minimumBaseQuality: Int,
        excludedFlags: UInt16,
        readGroups: Set<String>
    ) {
        self.minimumDepth = minimumDepth
        self.minimumMapQ = minimumMapQ
        self.minimumBaseQuality = minimumBaseQuality
        self.excludedFlags = excludedFlags
        self.readGroups = readGroups
    }
}
