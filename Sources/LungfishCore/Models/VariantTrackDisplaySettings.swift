// VariantTrackDisplaySettings.swift - Display settings for variant track visualization
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - VariantTrackDisplaySettings

/// Display settings for variant track visualization.
public struct VariantTrackDisplaySettings: Sendable {

    /// Color scheme for variant rendering
    public var colorScheme: VariantColorScheme

    /// Custom colors per variant type (overrides scheme)
    public var customColors: [VariantType: AnnotationColor]

    /// Track height in pixels
    public var trackHeight: Double

    /// Whether to show variant labels
    public var showLabels: Bool

    /// Minimum quality score to display
    public var minQualityFilter: Double?

    /// Variant types to show (nil = all)
    public var visibleTypes: Set<VariantType>?

    /// Whether to show only passing variants
    public var showOnlyPassing: Bool

    /// Creates default display settings.
    public init(
        colorScheme: VariantColorScheme = .byType,
        customColors: [VariantType: AnnotationColor] = [:],
        trackHeight: Double = 20.0,
        showLabels: Bool = true,
        minQualityFilter: Double? = nil,
        visibleTypes: Set<VariantType>? = nil,
        showOnlyPassing: Bool = false
    ) {
        self.colorScheme = colorScheme
        self.customColors = customColors
        self.trackHeight = trackHeight
        self.showLabels = showLabels
        self.minQualityFilter = minQualityFilter
        self.visibleTypes = visibleTypes
        self.showOnlyPassing = showOnlyPassing
    }
}

// MARK: - VariantTrackDisplaySettings Codable

// Hand-rolled Codable is REQUIRED here: the VariantType-keyed `customColors`
// dictionary and the `visibleTypes` Set must serialize using VariantType's
// String rawValues rather than the synthesized (non-String-keyed) form.
extension VariantTrackDisplaySettings: Codable {

    enum CodingKeys: String, CodingKey {
        case colorScheme
        case customColors
        case trackHeight
        case showLabels
        case minQualityFilter
        case visibleTypes
        case showOnlyPassing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colorScheme = try container.decode(VariantColorScheme.self, forKey: .colorScheme)

        // Decode custom colors with String keys, convert to VariantType
        let stringColors = try container.decodeIfPresent(
            [String: AnnotationColor].self,
            forKey: .customColors
        ) ?? [:]
        customColors = Dictionary(uniqueKeysWithValues: stringColors.compactMap { key, value in
            guard let variantType = VariantType(rawValue: key) else { return nil }
            return (variantType, value)
        })

        trackHeight = try container.decode(Double.self, forKey: .trackHeight)
        showLabels = try container.decode(Bool.self, forKey: .showLabels)
        minQualityFilter = try container.decodeIfPresent(Double.self, forKey: .minQualityFilter)

        // Decode visible types
        if let typeStrings = try container.decodeIfPresent([String].self, forKey: .visibleTypes) {
            visibleTypes = Set(typeStrings.compactMap { VariantType(rawValue: $0) })
        } else {
            visibleTypes = nil
        }

        showOnlyPassing = try container.decode(Bool.self, forKey: .showOnlyPassing)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colorScheme, forKey: .colorScheme)

        // Encode custom colors with String keys
        let stringColors = Dictionary(uniqueKeysWithValues: customColors.map { ($0.key.rawValue, $0.value) })
        try container.encode(stringColors, forKey: .customColors)

        try container.encode(trackHeight, forKey: .trackHeight)
        try container.encode(showLabels, forKey: .showLabels)
        try container.encodeIfPresent(minQualityFilter, forKey: .minQualityFilter)

        // Encode visible types
        if let types = visibleTypes {
            try container.encode(types.map(\.rawValue), forKey: .visibleTypes)
        } else {
            try container.encodeNil(forKey: .visibleTypes)
        }

        try container.encode(showOnlyPassing, forKey: .showOnlyPassing)
    }
}
