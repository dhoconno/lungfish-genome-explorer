import AppKit
import Combine
import LungfishCore
import LungfishIO
import LungfishKit
import SwiftUI

struct ManualHaplotypeLocusLayout: Layout {
    enum Mode: Equatable {
        case sideBySide
        case stacked
    }

    struct Geometry: Equatable {
        let mode: Mode
        let frames: [CGRect]

        var size: CGSize {
            CGSize(
                width: frames.map(\.maxX).max() ?? 0,
                height: frames.map(\.maxY).max() ?? 0
            )
        }
    }

    static let sideBySideBreakpoint: CGFloat = 430
    static let horizontalSpacing: CGFloat = 12
    static let verticalSpacing: CGFloat = 5

    let typographyScale: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let naturalSizes = subviews.map {
            $0.sizeThatFits(.unspecified)
        }
        let naturalWidth =
            naturalSizes.map(\.width).reduce(0, +)
            + Self.horizontalSpacing * CGFloat(max(0, subviews.count - 1))
        let availableWidth = max(
            0,
            proposal.width ?? naturalWidth
        )
        let measuredSizes = measuredSizes(
            for: subviews,
            availableWidth: availableWidth,
            proposedHeight: proposal.height,
            naturalSizes: naturalSizes
        )
        return Self.geometry(
            availableWidth: availableWidth,
            typographyScale: typographyScale,
            childSizes: measuredSizes
        ).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let availableWidth = max(0, bounds.width)
        let naturalSizes = subviews.map {
            $0.sizeThatFits(.unspecified)
        }
        let measuredSizes = measuredSizes(
            for: subviews,
            availableWidth: availableWidth,
            proposedHeight: proposal.height,
            naturalSizes: naturalSizes
        )
        let geometry = Self.geometry(
            availableWidth: availableWidth,
            typographyScale: typographyScale,
            childSizes: measuredSizes
        )
        for (index, subview) in subviews.enumerated()
        where index < geometry.frames.count {
            let frame = geometry.frames[index].offsetBy(
                dx: bounds.minX,
                dy: bounds.minY
            )
            subview.place(
                at: frame.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    static func testingGeometry(
        availableWidth: CGFloat,
        typographyScale: CGFloat,
        childSizes: [CGSize]
    ) -> Geometry {
        geometry(
            availableWidth: availableWidth,
            typographyScale: typographyScale,
            childSizes: childSizes
        )
    }

    private func measuredSizes(
        for subviews: Subviews,
        availableWidth: CGFloat,
        proposedHeight: CGFloat?,
        naturalSizes: [CGSize]
    ) -> [CGSize] {
        guard subviews.count == 3 else {
            return subviews.map {
                $0.sizeThatFits(
                    ProposedViewSize(
                        width: availableWidth,
                        height: proposedHeight
                    )
                )
            }
        }
        let mode = Self.mode(
            availableWidth: availableWidth,
            typographyScale: typographyScale
        )
        switch mode {
        case .sideBySide:
            let locusWidth = min(naturalSizes[0].width, availableWidth)
            let slotWidth = max(
                0,
                (
                    availableWidth
                        - locusWidth
                        - Self.horizontalSpacing * 2
                ) / 2
            )
            return [
                subviews[0].sizeThatFits(
                    ProposedViewSize(
                        width: locusWidth,
                        height: proposedHeight
                    )
                ),
                subviews[1].sizeThatFits(
                    ProposedViewSize(
                        width: slotWidth,
                        height: proposedHeight
                    )
                ),
                subviews[2].sizeThatFits(
                    ProposedViewSize(
                        width: slotWidth,
                        height: proposedHeight
                    )
                ),
            ]
        case .stacked:
            return subviews.map {
                $0.sizeThatFits(
                    ProposedViewSize(
                        width: availableWidth,
                        height: proposedHeight
                    )
                )
            }
        }
    }

    private static func mode(
        availableWidth: CGFloat,
        typographyScale: CGFloat
    ) -> Mode {
        availableWidth
            >= sideBySideBreakpoint * max(typographyScale, 0.01)
            ? .sideBySide
            : .stacked
    }

    private static func geometry(
        availableWidth: CGFloat,
        typographyScale: CGFloat,
        childSizes: [CGSize]
    ) -> Geometry {
        guard childSizes.count == 3 else {
            return Geometry(mode: .stacked, frames: [])
        }
        switch mode(
            availableWidth: availableWidth,
            typographyScale: typographyScale
        ) {
        case .sideBySide:
            let locusWidth = min(childSizes[0].width, availableWidth)
            let slotWidth = max(
                0,
                (
                    availableWidth
                        - locusWidth
                        - horizontalSpacing * 2
                ) / 2
            )
            return Geometry(
                mode: .sideBySide,
                frames: [
                    CGRect(
                        x: 0,
                        y: 0,
                        width: locusWidth,
                        height: childSizes[0].height
                    ),
                    CGRect(
                        x: locusWidth + horizontalSpacing,
                        y: 0,
                        width: slotWidth,
                        height: childSizes[1].height
                    ),
                    CGRect(
                        x:
                            locusWidth
                            + horizontalSpacing * 2
                            + slotWidth,
                        y: 0,
                        width: slotWidth,
                        height: childSizes[2].height
                    ),
                ]
            )
        case .stacked:
            let first = CGRect(
                x: 0,
                y: 0,
                width: availableWidth,
                height: childSizes[0].height
            )
            let second = CGRect(
                x: 0,
                y: first.maxY + verticalSpacing,
                width: availableWidth,
                height: childSizes[1].height
            )
            let third = CGRect(
                x: 0,
                y: second.maxY + verticalSpacing,
                width: availableWidth,
                height: childSizes[2].height
            )
            return Geometry(
                mode: .stacked,
                frames: [first, second, third]
            )
        }
    }
}
