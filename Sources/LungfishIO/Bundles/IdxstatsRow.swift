// IdxstatsRow.swift - One row of samtools idxstats output
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

/// One row of `samtools idxstats` output.
public struct IdxstatsRow: Sendable, Equatable {

    /// Reference sequence name. `*` is the unmapped-reads summary row.
    public let chromosome: String

    /// Reference sequence length in bases.
    public let length: Int64

    /// Reads mapped to this reference.
    public let mappedReads: Int64

    /// Reads placed on this reference but unmapped.
    public let unmappedReads: Int64

    public init(chromosome: String, length: Int64, mappedReads: Int64, unmappedReads: Int64) {
        self.chromosome = chromosome
        self.length = length
        self.mappedReads = mappedReads
        self.unmappedReads = unmappedReads
    }
}
