// CoverageScaleMode.swift - Vertical scaling for coverage/depth tracks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How depth is mapped to height in a coverage track.
///
/// A viral or amplicon genome routinely mixes a few very deep peaks with long
/// shallow stretches. On a linear axis the peak sets the scale and every
/// low-coverage region collapses onto the baseline, which is exactly where
/// dropouts need to be visible. Compressing the axis keeps the peak on screen
/// while lifting shallow regions into a readable range.
public enum CoverageScaleMode: String, CaseIterable, Sendable, Codable {
    case linear
    case log10
    case squareRoot

    /// The default: depth is proportional to height, which is the correct
    /// reading for a track whose dynamic range is narrow.
    public static let `default`: CoverageScaleMode = .linear

    public var displayName: String {
        switch self {
        case .linear: "Linear"
        case .log10: "Log10"
        case .squareRoot: "Square root"
        }
    }

    /// A short axis annotation naming the transform, so a compressed track is
    /// never mistaken for a linear one.
    public var axisLabel: String? {
        switch self {
        case .linear: nil
        case .log10: "log₁₀"
        case .squareRoot: "√"
        }
    }

    /// Maps a depth to its position in the transformed space.
    ///
    /// Negative depth cannot occur but is clamped rather than trusted, since
    /// `log10`/`sqrt` of a negative would yield NaN and corrupt the path.
    /// `log10` uses `depth + 1` so zero depth maps to zero instead of `-inf`,
    /// keeping uncovered positions flat on the baseline.
    public func transform(_ depth: Double) -> Double {
        let value = max(0, depth)
        switch self {
        case .linear: return value
        case .log10: return Foundation.log10(value + 1)
        case .squareRoot: return value.squareRoot()
        }
    }

    /// The fraction of the track height a depth occupies given the track's
    /// maximum depth. Always within `0...1`, and `0` when the axis would be
    /// degenerate, so a caller can multiply it by a height unconditionally.
    public func normalizedHeight(depth: Double, maxDepth: Double) -> Double {
        let transformedMax = transform(maxDepth)
        guard transformedMax > 0, transformedMax.isFinite else { return 0 }
        let transformed = transform(depth)
        guard transformed.isFinite else { return 0 }
        return min(1, max(0, transformed / transformedMax))
    }
}
