// ContentTextSizePreference.swift - User-selected scaling for primary list, table, and detail content
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

/// User-selected scaling for primary list, table, and detail content.
///
/// `system` uses the semantic AppKit preferred font sizes without applying an
/// additional Lungfish scale. Custom values are normalized to one of the
/// supported percentages before persistence or use.
public enum ContentTextSizePreference: Sendable, Equatable, Codable {
    case system
    case custom(Int)

    public static let supportedPercentages = [90, 100, 125, 150, 175, 200]

    public var normalized: Self {
        switch self {
        case .system:
            return .system
        case .custom(let percentage):
            let boundedPercentage = max(
                Self.supportedPercentages[0],
                min(Self.supportedPercentages[Self.supportedPercentages.count - 1], percentage)
            )
            let nearest = Self.supportedPercentages.min { lhs, rhs in
                let lhsDistance = abs(lhs - boundedPercentage)
                let rhsDistance = abs(rhs - boundedPercentage)
                return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
            } ?? 100
            return .custom(nearest)
        }
    }

    public var percentage: Int? {
        guard case .custom(let percentage) = normalized else { return nil }
        return percentage
    }

    public var scaleFactor: Double {
        Double(percentage ?? 100) / 100
    }

    public var larger: Self {
        switch normalized {
        case .system:
            return .custom(125)
        case .custom(let percentage):
            return .custom(Self.adjacentPercentage(to: percentage, direction: 1))
        }
    }

    public var smaller: Self {
        switch normalized {
        case .system:
            return .custom(90)
        case .custom(let percentage):
            return .custom(Self.adjacentPercentage(to: percentage, direction: -1))
        }
    }

    private static func adjacentPercentage(to percentage: Int, direction: Int) -> Int {
        guard let index = supportedPercentages.firstIndex(of: percentage) else {
            return percentage
        }
        let destination = max(0, min(supportedPercentages.count - 1, index + direction))
        return supportedPercentages[destination]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .custom(value).normalized
        } else {
            self = .system
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch normalized {
        case .system:
            try container.encode("system")
        case .custom(let percentage):
            try container.encode(percentage)
        }
    }
}
