import AppKit
import Combine
import LungfishIO
import LungfishKit
import SwiftUI

@MainActor
struct GenotypeSampleCurationTrailingPane: View {
    @ObservedObject var model: GenotypeSampleCurationTrailingModel
    var typographyModel: ContentTypographyModel

    var body: some View {
        GenotypeSampleCurationModeOverlayLayout(mode: model.mode) {
            GenotypeSupportedAllelesPanel(
                snapshot: model.evidenceSnapshot,
                typographyModel: typographyModel,
                availableHeight: model.availableEvidenceHeight,
                usesCompactHeight: model.usesCompactEvidenceHeight
            )
            .opacity(model.mode == .evidence ? 1 : 0)
            .disabled(model.mode != .evidence)
            .allowsHitTesting(model.mode == .evidence)
            .accessibilityHidden(model.mode != .evidence)

            GenotypeSampleComparisonPanel(
                model: model.comparison,
                typographyModel: typographyModel,
                onBackToEvidence: model.showEvidence
            )
            .opacity(model.mode == .compareAndCopy ? 1 : 0)
            .disabled(model.mode != .compareAndCopy)
            .allowsHitTesting(model.mode == .compareAndCopy)
            .accessibilityHidden(model.mode != .compareAndCopy)
        }
        .clipped()
        .animation(nil, value: model.mode)
    }
}

private struct GenotypeSampleCurationModeOverlayLayout: Layout {
    let mode: GenotypeSampleCurationTrailingModel.Mode

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        return subviews[mode == .evidence ? 0 : 1]
            .sizeThatFits(proposal)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for subview in subviews {
            subview.place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: bounds.width,
                    height: bounds.height
                )
            )
        }
    }
}
