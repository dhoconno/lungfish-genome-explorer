import SwiftUI

/// A selectable Inspector key/value row that stays aligned when it fits and
/// moves the value below its label before either string becomes compressed.
public struct GenotypeInspectorValueRow: View {
    private let label: String
    private let value: String
    private let font: Font
    private let valueAccessibilityIdentifier: String?

    public init(
        _ label: String,
        value: String,
        font: Font,
        valueAccessibilityIdentifier: String? = nil
    ) {
        self.label = label
        self.value = value
        self.font = font
        self.valueAccessibilityIdentifier = valueAccessibilityIdentifier
    }

    public var body: some View {
        GenotypeInspectorAdaptiveRowLayout {
            labelText.fixedSize(horizontal: false, vertical: true)
            valueText
        }
        .font(font)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var labelText: some View {
        Text(label)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var valueText: some View {
        if let valueAccessibilityIdentifier {
            styledValueText
                .accessibilityIdentifier(valueAccessibilityIdentifier)
        } else {
            styledValueText
        }
    }

    private var styledValueText: some View {
        Text(value)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `ViewThatFits` cannot reliably reject a SwiftUI `Text` candidate because Text
/// accepts compression before reporting that it does not fit. This layout makes
/// the decision from the uncompressed label/value widths, then proposes the full
/// row width to the value only after choosing the label-over-value presentation.
private struct GenotypeInspectorAdaptiveRowLayout: Layout {
    private let horizontalSpacing: CGFloat = 12
    private let verticalSpacing: CGFloat = 2

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? intrinsicWidth(of: subviews)
        let sizes = measuredSizes(for: width, subviews: subviews)
        return CGSize(width: width, height: sizes.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        let sizes = measuredSizes(for: bounds.width, subviews: subviews)
        let origin = CGPoint(x: bounds.minX, y: bounds.minY)
        if sizes.isHorizontal {
            subviews[0].place(
                at: origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(sizes.label)
            )
            subviews[1].place(
                at: CGPoint(
                    x: bounds.maxX - sizes.value.width,
                    y: bounds.minY
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(sizes.value)
            )
        } else {
            subviews[0].place(
                at: origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: sizes.label.height)
            )
            subviews[1].place(
                at: CGPoint(
                    x: bounds.minX,
                    y: bounds.minY + sizes.label.height + verticalSpacing
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: sizes.value.height)
            )
        }
    }

    private func intrinsicWidth(of subviews: Subviews) -> CGFloat {
        let label = subviews[0].sizeThatFits(.unspecified)
        let value = subviews[1].sizeThatFits(.unspecified)
        return label.width + horizontalSpacing + value.width
    }

    private func measuredSizes(
        for width: CGFloat,
        subviews: Subviews
    ) -> (label: CGSize, value: CGSize, height: CGFloat, isHorizontal: Bool) {
        let intrinsicLabel = subviews[0].sizeThatFits(.unspecified)
        let intrinsicValue = subviews[1].sizeThatFits(.unspecified)
        if intrinsicLabel.width + horizontalSpacing + intrinsicValue.width <= width {
            return (
                intrinsicLabel,
                intrinsicValue,
                max(intrinsicLabel.height, intrinsicValue.height),
                true
            )
        }

        let wrappedLabel = subviews[0].sizeThatFits(
            ProposedViewSize(width: width, height: nil)
        )
        let wrappedValue = subviews[1].sizeThatFits(
            ProposedViewSize(width: width, height: nil)
        )
        return (
            wrappedLabel,
            wrappedValue,
            wrappedLabel.height + verticalSpacing + wrappedValue.height,
            false
        )
    }
}
