// BundleVariant.swift - Represents a variant from a bundle's variant track
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

// MARK: - BundleVariant

/// Represents a variant from a bundle's variant track.
public struct BundleVariant: Sendable, Equatable, Identifiable {
    /// Unique identifier.
    public let id: String

    /// Chromosome name.
    public let chromosome: String

    /// Position (0-based).
    public let position: Int64

    /// Reference allele.
    public let ref: String

    /// Alternate allele(s).
    public let alt: [String]

    /// Variant quality score.
    public let quality: Float?

    /// Variant ID from source (e.g., rsID).
    public let variantId: String?

    /// Filter status.
    public let filter: String?

    /// Creates a bundle variant.
    public init(
        id: String = UUID().uuidString,
        chromosome: String,
        position: Int64,
        ref: String,
        alt: [String],
        quality: Float? = nil,
        variantId: String? = nil,
        filter: String? = nil
    ) {
        self.id = id
        self.chromosome = chromosome
        self.position = position
        self.ref = ref
        self.alt = alt
        self.quality = quality
        self.variantId = variantId
        self.filter = filter
    }
}
