// BarcodeEntry.swift - A single barcode entry with index sequences
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A single barcode entry with index sequences.
///
/// For Illumina kits, `sequence` is the i7 index and `secondarySequence` is the i5 index.
/// For ONT/PacBio, `sequence` is the barcode and `secondarySequence` is nil (symmetric)
/// or the 3' barcode (asymmetric).
public struct BarcodeEntry: Codable, Sendable, Equatable {
    /// Barcode ID (e.g., "D701", "N501", "BC01").
    public let id: String

    /// Primary barcode sequence (Illumina i7, ONT barcode, PacBio barcode).
    public let i7Sequence: String

    /// Secondary barcode sequence (Illumina i5, PacBio asymmetric 3' barcode).
    /// Nil for single-indexed / symmetric kits.
    public let i5Sequence: String?

    /// Optional user-assigned sample name.
    public var sampleName: String?

    public init(
        id: String,
        i7Sequence: String,
        i5Sequence: String? = nil,
        sampleName: String? = nil
    ) {
        self.id = id
        self.i7Sequence = i7Sequence
        self.i5Sequence = i5Sequence
        self.sampleName = sampleName
    }

    /// Platform-neutral alias for the primary barcode sequence.
    public var sequence: String { i7Sequence }

    /// Platform-neutral alias for the secondary barcode sequence.
    public var secondarySequence: String? { i5Sequence }
}
