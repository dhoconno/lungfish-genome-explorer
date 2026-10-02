// VariantColorScheme.swift - Color schemes for variant visualization
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - VariantColorScheme

/// Color schemes for variant visualization.
public enum VariantColorScheme: String, Sendable, CaseIterable {
    /// Color by variant type (SNP, indel, etc.)
    case byType

    /// Color by quality score (gradient)
    case byQuality

    /// Color by allele frequency
    case byFrequency

    /// Single color for all variants
    case uniform
}

extension VariantColorScheme: Codable {}
