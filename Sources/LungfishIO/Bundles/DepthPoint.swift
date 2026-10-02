// DepthPoint.swift - Per-position read depth from samtools depth
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

// MARK: - DepthPoint

/// Per-position read depth from `samtools depth`.
public struct DepthPoint: Sendable, Equatable {
    /// Chromosome/contig name.
    public let chromosome: String
    /// 0-based reference position.
    public let position: Int
    /// Depth at the position.
    public let depth: Int

    public init(chromosome: String, position: Int, depth: Int) {
        self.chromosome = chromosome
        self.position = position
        self.depth = depth
    }
}
