// BarcodePairingMode.swift - How barcode sequences are paired within a read during demultiplexing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Barcode Pairing Mode

/// How barcode sequences are paired within a read during demultiplexing.
public enum BarcodePairingMode: String, Codable, Sendable, CaseIterable {
    /// Barcode at one end only (e.g., ONT rapid barcoding).
    case singleEnd
    /// Same barcode on both ends, forward + reverse complement (e.g., ONT native barcoding).
    case symmetric
    /// Barcode entries define explicit forward/reverse pairs (e.g., Illumina TruSeq HT dual index).
    case fixedDual
    /// Any two barcodes from the same set may form a valid asymmetric pair (e.g., PacBio).
    case combinatorialDual
}
