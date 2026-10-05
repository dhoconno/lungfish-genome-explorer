// SamplePair.swift - One sample's read files, as batch import detected them
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A detected R1/R2 pair (or single-end sample) ready for batch import.
public struct SamplePair: Sendable {
    public let sampleName: String
    public let r1: URL
    public let r2: URL?
    /// The reads of a pair's sample whose mate is missing, from the file an
    /// SRA download names after the run alone beside `<run>_1` and `<run>_2`.
    /// Nil for every other sample.
    public let unpaired: URL?
    /// Relative path from the scanned root directory (nil for root-level files).
    public let relativePath: String?
    /// Optional metadata imported from a sample sheet row.
    public let metadata: [String: String]
    /// CSV sample sheet that supplied this pair, when applicable.
    public let sampleSheetURL: URL?

    public init(
        sampleName: String,
        r1: URL,
        r2: URL?,
        unpaired: URL? = nil,
        relativePath: String? = nil,
        metadata: [String: String] = [:],
        sampleSheetURL: URL? = nil
    ) {
        self.sampleName = sampleName
        self.r1 = r1
        self.r2 = r2
        self.unpaired = unpaired
        self.relativePath = relativePath
        self.metadata = metadata
        self.sampleSheetURL = sampleSheetURL
    }

    /// Every read file of the sample, R1, then R2, then the unpaired reads.
    public var inputFiles: [URL] {
        [r1] + [r2, unpaired].compactMap { $0 }
    }
}
