// SunburstGeometry.swift - Arc segment geometry for sunburst chart rendering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

// MARK: - SunburstSegment

/// Precomputed geometry for a single arc segment in the sunburst chart.
///
/// Each segment represents one taxon node at a particular ring level. The
/// geometry is computed once per layout pass and cached for both rendering
/// and hit testing.
///
/// ## Coordinate System
///
/// Angles are measured in radians, starting from the 12-o'clock position
/// (negative Y in flipped coordinates) and increasing clockwise:
/// - 0 radians = 12 o'clock (top)
/// - pi/2 = 3 o'clock (right)
/// - pi = 6 o'clock (bottom)
/// - 3*pi/2 = 9 o'clock (left)
@MainActor
public struct SunburstSegment {

    /// The taxon node this segment represents.
    public let node: TaxonNode

    /// The ring index (0 = innermost visible ring, increasing outward).
    public let ring: Int

    /// Inner radius of the annular sector, in points.
    public let innerRadius: CGFloat

    /// Outer radius of the annular sector, in points.
    public let outerRadius: CGFloat

    /// Start angle in radians (clockwise from 12 o'clock).
    public let startAngle: CGFloat

    /// End angle in radians (clockwise from 12 o'clock).
    public let endAngle: CGFloat

    /// The fill color for this segment.
    public let color: NSColor

    /// Whether this is an "Other" aggregation segment for small taxa.
    public let isOther: Bool

    /// The angular span of this segment in radians.
    public var angularSpan: CGFloat {
        endAngle - startAngle
    }

    /// The angular span of this segment in degrees.
    public var angularSpanDegrees: CGFloat {
        angularSpan * 180.0 / .pi
    }

    /// The mid-angle of this segment in radians.
    public var midAngle: CGFloat {
        (startAngle + endAngle) / 2.0
    }

    /// The mid-radius of the annular sector.
    public var midRadius: CGFloat {
        (innerRadius + outerRadius) / 2.0
    }

    /// The arc length at the mid-radius, in points.
    public var arcLengthAtMid: CGFloat {
        midRadius * angularSpan
    }

    /// The ring thickness (outer - inner radius).
    public var ringThickness: CGFloat {
        outerRadius - innerRadius
    }

    /// Creates an `NSBezierPath` for this annular sector.
    ///
    /// The path traces:
    /// 1. Arc along the outer radius from `startAngle` to `endAngle`
    /// 2. Line to the inner radius at `endAngle`
    /// 3. Arc along the inner radius from `endAngle` to `startAngle` (reversed)
    /// 4. Close path
    ///
    /// - Parameter center: The center point of the sunburst.
    /// - Returns: A closed bezier path for the segment.
    public func bezierPath(center: NSPoint) -> NSBezierPath {
        let path = NSBezierPath()

        // Convert from our clockwise-from-top convention to AppKit's
        // counterclockwise-from-right convention.
        // Our 0 = top (12 o'clock), AppKit's 0 = right (3 o'clock).
        // Our angles increase clockwise, AppKit increases counterclockwise.
        //
        // Conversion: appKitAngle = 90 - ourAngleDegrees
        // And we flip the arc direction.

        let startDeg = 90.0 - startAngle * 180.0 / .pi
        let endDeg = 90.0 - endAngle * 180.0 / .pi

        // Outer arc (counterclockwise in AppKit = clockwise in our system)
        path.appendArc(
            withCenter: center,
            radius: outerRadius,
            startAngle: startDeg,
            endAngle: endDeg,
            clockwise: true
        )

        // Line to inner radius
        path.appendArc(
            withCenter: center,
            radius: innerRadius,
            startAngle: endDeg,
            endAngle: startDeg,
            clockwise: false
        )

        path.close()
        return path
    }

    /// Tests whether a point (in polar coordinates relative to the center)
    /// falls within this segment.
    ///
    /// - Parameters:
    ///   - radius: Distance from center.
    ///   - angle: Angle in radians (clockwise from 12 o'clock).
    /// - Returns: `true` if the point is inside this segment.
    public func containsPoint(radius: CGFloat, angle: CGFloat) -> Bool {
        guard radius >= innerRadius, radius <= outerRadius else { return false }

        // Normalize the angle to [0, 2*pi)
        let normalizedAngle = normalizeAngle(angle)
        let normalizedStart = normalizeAngle(startAngle)
        let normalizedEnd = normalizeAngle(endAngle)

        if normalizedStart <= normalizedEnd {
            return normalizedAngle >= normalizedStart && normalizedAngle <= normalizedEnd
        } else {
            // Segment wraps around 0/2pi
            return normalizedAngle >= normalizedStart || normalizedAngle <= normalizedEnd
        }
    }
}

// MARK: - SunburstLayout

/// Computes the layout geometry for a sunburst chart from a `TaxonTree`.
///
/// The layout engine converts a taxonomy tree into an array of
/// ``SunburstSegment`` values suitable for rendering and hit testing.
///
/// ## Algorithm
///
/// 1. Starting from the zoom root, recursively assign angular spans
///    proportional to each node's clade fraction relative to its parent.
/// 2. Skip nodes whose angular span is below ``minAngleDegrees`` and
///    aggregate them into an "Other" segment per ring.
/// 3. Compute ring radii from the center radius outward.
///
/// ## Usage
///
/// ```swift
/// let layout = SunburstLayout(
///     tree: taxonomyTree,
///     bounds: view.bounds,
///     maxRings: 8,
///     minFractionToShow: 0.001
/// )
/// let segments = layout.computeSegments()
/// ```
@MainActor
public struct SunburstLayout {

    /// The taxonomy tree to visualize.
    public let tree: TaxonTree

    /// The current zoom root (nil = tree root).
    public let zoomRoot: TaxonNode?

    /// The bounding rectangle for the chart.
    public let bounds: CGRect

    /// Maximum number of concentric rings to display.
    public let maxRings: Int

    /// Minimum clade fraction (relative to zoom root) for a segment to be shown.
    /// Segments below this threshold are aggregated into "Other".
    public let minFractionToShow: Double

    /// Minimum angular span in degrees for a segment to be drawn individually.
    /// Segments below this threshold contribute to the "Other" aggregation.
    public static let minAngleDegrees: CGFloat = 0.5

    /// The center radius as a fraction of the available radius (15%).
    public static let centerRadiusFraction: CGFloat = 0.15

    /// Outer padding in points.
    public static let outerPadding: CGFloat = 16.0

    /// Creates a sunburst layout.
    ///
    /// - Parameters:
    ///   - tree: The taxonomy tree.
    ///   - zoomRoot: The node to use as the visual root (nil for tree root).
    ///   - bounds: The view bounds.
    ///   - maxRings: Maximum rings to display (default 8).
    ///   - minFractionToShow: Minimum fraction to show (default 0.001).
    public init(
        tree: TaxonTree,
        zoomRoot: TaxonNode? = nil,
        bounds: CGRect,
        maxRings: Int = 8,
        minFractionToShow: Double = 0.001
    ) {
        self.tree = tree
        self.zoomRoot = zoomRoot
        self.bounds = bounds
        self.maxRings = maxRings
        self.minFractionToShow = minFractionToShow
    }

    // MARK: - Geometry Calculations

    /// The center point of the sunburst chart.
    public var center: NSPoint {
        NSPoint(x: bounds.midX, y: bounds.midY)
    }

    /// The available radius (from center to outermost ring).
    public var availableRadius: CGFloat {
        let side = min(bounds.width, bounds.height)
        return max(0, side / 2.0 - Self.outerPadding)
    }

    /// The center circle radius.
    public var centerRadius: CGFloat {
        availableRadius * Self.centerRadiusFraction
    }

    /// The thickness of each ring.
    public var ringThickness: CGFloat {
        let ringSpace = availableRadius - centerRadius
        guard maxRings > 0 else { return ringSpace }
        return ringSpace / CGFloat(maxRings)
    }

    /// Returns the inner radius for a given ring index.
    ///
    /// - Parameter ring: Zero-based ring index (0 = innermost).
    /// - Returns: The inner radius in points.
    public func innerRadius(forRing ring: Int) -> CGFloat {
        centerRadius + CGFloat(ring) * ringThickness
    }

    /// Returns the outer radius for a given ring index.
    ///
    /// - Parameter ring: Zero-based ring index (0 = innermost).
    /// - Returns: The outer radius in points.
    public func outerRadius(forRing ring: Int) -> CGFloat {
        centerRadius + CGFloat(ring + 1) * ringThickness
    }

    // MARK: - Segment Computation

    /// Computes all segments for the current tree, zoom root, and bounds.
    ///
    /// - Returns: An array of ``SunburstSegment`` values for rendering.
    public func computeSegments() -> [SunburstSegment] {
        let root = effectiveRoot
        guard root.readsClade > 0 else { return [] }
        guard availableRadius > 0, ringThickness > 0 else { return [] }

        var segments: [SunburstSegment] = []
        let totalAngle: CGFloat = 2.0 * .pi

        // Recursively lay out children starting at ring 0
        layoutChildren(
            of: root,
            startAngle: 0,
            angularSpan: totalAngle,
            ring: 0,
            segments: &segments
        )

        return segments
    }

    /// The effective root node (zoom root or tree root).
    public var effectiveRoot: TaxonNode {
        zoomRoot ?? tree.root
    }

    // MARK: - Recursive Layout

    /// Recursively lays out children of a node, assigning angular spans
    /// proportional to their clade counts.
    ///
    /// - Parameters:
    ///   - parent: The parent node whose children to lay out.
    ///   - startAngle: The starting angle for the first child.
    ///   - angularSpan: The total angular span available for all children.
    ///   - ring: The ring index for the children.
    ///   - segments: Accumulator for computed segments.
    private func layoutChildren(
        of parent: TaxonNode,
        startAngle: CGFloat,
        angularSpan: CGFloat,
        ring: Int,
        segments: inout [SunburstSegment]
    ) {
        guard ring < maxRings else { return }
        guard !parent.children.isEmpty else { return }
        guard parent.readsClade > 0 else { return }

        let minAngleRad = Self.minAngleDegrees * .pi / 180.0
        let rootClade = Double(effectiveRoot.readsClade)

        var currentAngle = startAngle
        var otherAngle: CGFloat = 0

        // Sort children by clade count descending for visual stability
        let sortedChildren = parent.children.sorted { $0.readsClade > $1.readsClade }

        for child in sortedChildren {
            guard child.readsClade > 0 else { continue }

            let fraction = CGFloat(child.readsClade) / CGFloat(parent.readsClade)
            let childSpan = angularSpan * fraction

            // Check minimum thresholds
            let cladeToRoot = Double(child.readsClade) / rootClade
            if childSpan < minAngleRad || cladeToRoot < minFractionToShow {
                otherAngle += childSpan
                continue
            }

            let segment = SunburstSegment(
                node: child,
                ring: ring,
                innerRadius: innerRadius(forRing: ring),
                outerRadius: outerRadius(forRing: ring),
                startAngle: currentAngle,
                endAngle: currentAngle + childSpan,
                color: PhylumPalette.color(for: child),
                isOther: false
            )
            segments.append(segment)

            // Recurse into children
            layoutChildren(
                of: child,
                startAngle: currentAngle,
                angularSpan: childSpan,
                ring: ring + 1,
                segments: &segments
            )

            currentAngle += childSpan
        }

        // Aggregate "Other" segments
        if otherAngle > 0 {
            let otherSegment = SunburstSegment(
                node: parent,  // parent as placeholder
                ring: ring,
                innerRadius: innerRadius(forRing: ring),
                outerRadius: outerRadius(forRing: ring),
                startAngle: currentAngle,
                endAngle: currentAngle + otherAngle,
                color: PhylumPalette.otherColor,
                isOther: true
            )
            segments.append(otherSegment)
        }
    }
}

// MARK: - Hit Testing

extension SunburstLayout {

    /// Converts a view-space point to polar coordinates relative to the center.
    ///
    /// - Parameter point: A point in the view's coordinate system.
    /// - Returns: A tuple of (radius, angle) where angle is in radians,
    ///   clockwise from 12 o'clock (top).
    public func polarCoordinates(for point: NSPoint) -> (radius: CGFloat, angle: CGFloat) {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = sqrt(dx * dx + dy * dy)

        // atan2 gives angle from positive X axis, counterclockwise positive.
        // We want clockwise from top (negative Y in flipped coords).
        // In flipped coords: Y increases downward.
        // atan2(dy, dx): 0 = right, pi/2 = down, -pi/2 = up
        // We want: 0 = up, pi/2 = right, pi = down, 3pi/2 = left
        // Conversion: angle = atan2(dx, -dy) for flipped coords
        let rawAngle = atan2(dx, -dy)
        let angle = rawAngle < 0 ? rawAngle + 2.0 * .pi : rawAngle

        return (radius, angle)
    }

    /// Finds the segment at a given view-space point.
    ///
    /// - Parameters:
    ///   - point: A point in the view's coordinate system.
    ///   - segments: The precomputed segment array.
    /// - Returns: The segment at the point, or `nil` if the point is in
    ///   empty space or the center circle.
    public func hitTest(point: NSPoint, segments: [SunburstSegment]) -> SunburstSegment? {
        let (radius, angle) = polarCoordinates(for: point)

        // Check if in center circle
        if radius <= centerRadius {
            return nil  // center circle handled separately
        }

        // Check if outside the chart
        if radius > availableRadius {
            return nil
        }

        // Search segments
        for segment in segments {
            if segment.containsPoint(radius: radius, angle: angle) {
                return segment
            }
        }
        return nil
    }

    /// Tests whether a point is inside the center circle.
    ///
    /// - Parameter point: A point in the view's coordinate system.
    /// - Returns: `true` if the point is within the center circle.
    public func isInCenter(point: NSPoint) -> Bool {
        let dx = point.x - center.x
        let dy = point.y - center.y
        return sqrt(dx * dx + dy * dy) <= centerRadius
    }
}

// MARK: - Angle Normalization

/// Normalizes an angle to the range [0, 2*pi).
///
/// - Parameter angle: An angle in radians.
/// - Returns: The equivalent angle in [0, 2*pi).
func normalizeAngle(_ angle: CGFloat) -> CGFloat {
    var a = angle.truncatingRemainder(dividingBy: 2.0 * .pi)
    if a < 0 { a += 2.0 * .pi }
    return a
}
