import AppKit
import Combine
import LungfishIO
import LungfishKit
import SwiftUI

struct GenotypeSampleComparisonRowLayout: Layout {
    let typographyScale: CGFloat
    private let horizontalSpacing: CGFloat = 12
    private let verticalSpacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = max(0, proposal.width ?? 0)
        let frames = frames(width: width, subviews: subviews)
        return CGSize(
            width: width,
            height: frames.map(\.maxY).max() ?? 0
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for (subview, frame) in zip(
            subviews,
            frames(width: bounds.width, subviews: subviews)
        ) {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + frame.minX,
                    y: bounds.minY + frame.minY
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func frames(
        width: CGFloat,
        subviews: Subviews
    ) -> [CGRect] {
        guard subviews.count == 4 else { return [] }
        let usesColumns = width >= 620 * max(1, typographyScale)
        if usesColumns {
            let usable = max(0, width - horizontalSpacing * 3)
            let widths = [
                usable * 0.40,
                usable * 0.22,
                usable * 0.19,
                usable * 0.19,
            ]
            let sizes = zip(subviews, widths).map { view, columnWidth in
                view.sizeThatFits(
                    ProposedViewSize(width: columnWidth, height: nil)
                )
            }
            let height = sizes.map(\.height).max() ?? 0
            var x: CGFloat = 0
            return widths.enumerated().map { index, columnWidth in
                defer { x += columnWidth + horizontalSpacing }
                return CGRect(
                    x: x,
                    y: 0,
                    width: columnWidth,
                    height: max(height, sizes[index].height)
                )
            }
        }

        var result: [CGRect] = []
        var y: CGFloat = 0
        for index in 0..<2 {
            let size = subviews[index].sizeThatFits(
                ProposedViewSize(width: width, height: nil)
            )
            result.append(
                CGRect(x: 0, y: y, width: width, height: size.height)
            )
            y += size.height + verticalSpacing
        }
        let supportWidth = max(
            0,
            (width - horizontalSpacing) / 2
        )
        let supportSizes = (2..<4).map {
            subviews[$0].sizeThatFits(
                ProposedViewSize(width: supportWidth, height: nil)
            )
        }
        let supportHeight = supportSizes.map(\.height).max() ?? 0
        result.append(
            CGRect(
                x: 0,
                y: y,
                width: supportWidth,
                height: supportHeight
            )
        )
        result.append(
            CGRect(
                x: supportWidth + horizontalSpacing,
                y: y,
                width: supportWidth,
                height: supportHeight
            )
        )
        return result
    }
}
