// ViewerFigureFrame.swift - The base-to-point maths of one viewer figure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// The coordinate frame of one viewer figure. It holds a contig, the region of it the figure
/// shows, the width the figure draws that region across and the insets either side.
///
/// This is a value copy of the maths of the live viewer's `ReferenceFrame`
/// (`ViewerViewController.swift`, a `@MainActor` class that stays where it is), so a figure
/// places a base where the viewer places it. `ViewerFigureFrameParityTests` in
/// LungfishAppWorkflowTests holds the two equal, bit for bit, on the 20 regions that
/// `ReferenceFramePinTests` pinned from the live class first. Change neither formula alone.
///
/// Widths and positions are in points. The rasterizer multiplies them by its pixel scale.
public struct ViewerFigureFrame: Sendable, Hashable, Codable {
    /// The trailing inset the live viewer keeps between the data and the right edge.
    public static let defaultTrailingInset: CGFloat = 12

    /// The contig name.
    public let chromosome: String

    /// The first base position shown, 0-based.
    public let start: Double

    /// The end of the shown region, exclusive.
    public let end: Double

    /// The figure width in points, never below 1.
    public let pixelWidth: Int

    /// The contig length, for bounds checks by the builders.
    public let sequenceLength: Int

    /// Points reserved at the left for a name gutter. Data is drawn to its right.
    public let leadingInset: CGFloat

    /// Points kept clear at the right edge.
    public let trailingInset: CGFloat

    public init(
        chromosome: String,
        start: Double,
        end: Double,
        pixelWidth: Int,
        sequenceLength: Int = Int.max,
        leadingInset: CGFloat = 0,
        trailingInset: CGFloat = 0
    ) {
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.pixelWidth = max(1, pixelWidth)
        self.sequenceLength = sequenceLength
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
    }

    /// The width of the data area in points, the figure width less both insets, never below 1.
    public var dataPixelWidth: CGFloat {
        max(1, CGFloat(pixelWidth) - leadingInset - trailingInset)
    }

    /// Bases per point in the data area.
    public var scale: Double {
        (end - start) / Double(dataPixelWidth)
    }

    /// The genomic position at a figure x. An x inside the leading inset maps before `start`.
    public func genomicPosition(for screenX: CGFloat) -> Double {
        start + Double(screenX - leadingInset) * scale
    }

    /// The figure x of a genomic position, offset by the leading inset.
    public func screenPosition(for genomicPos: Double) -> CGFloat {
        leadingInset + CGFloat((genomicPos - start) / scale)
    }

    private enum CodingKeys: String, CodingKey {
        case chromosome, start, end, pixelWidth, sequenceLength, leadingInset, trailingInset
    }

    /// Decodes through the memberwise initializer, so a decoded width is clamped as a built one is.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            chromosome: try container.decode(String.self, forKey: .chromosome),
            start: try container.decode(Double.self, forKey: .start),
            end: try container.decode(Double.self, forKey: .end),
            pixelWidth: try container.decode(Int.self, forKey: .pixelWidth),
            sequenceLength: try container.decode(Int.self, forKey: .sequenceLength),
            leadingInset: try container.decode(CGFloat.self, forKey: .leadingInset),
            trailingInset: try container.decode(CGFloat.self, forKey: .trailingInset)
        )
    }
}
