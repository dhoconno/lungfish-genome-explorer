// BarcodeLocation.swift - Where barcodes are located within reads, affecting cutadapt adapter
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Barcode Location

/// Where barcodes are located within reads, affecting cutadapt adapter specification.
public enum BarcodeLocation: String, Codable, Sendable, CaseIterable {
    /// Barcode at the 5' (start) of the read. Uses cutadapt `-g ^SEQUENCE`.
    case fivePrime

    /// Barcode at the 3' (end) of the read. Uses cutadapt `-a SEQUENCE$`.
    case threePrime

    /// Dual-end barcode matching (5' and 3' together), typically linked adapters.
    case bothEnds

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "fivePrime":
            self = .fivePrime
        case "threePrime":
            self = .threePrime
        case "bothEnds":
            self = .bothEnds
        case "anywhere":
            // Backward compatibility for persisted settings from older builds.
            self = .bothEnds
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown BarcodeLocation '\(raw)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
