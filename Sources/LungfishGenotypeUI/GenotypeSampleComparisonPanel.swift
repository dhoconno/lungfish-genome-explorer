import AppKit
import Combine
import LungfishKit
import SwiftUI

@MainActor
final class GenotypeSampleCurationTrailingModel: ObservableObject {
    nonisolated enum Mode: Equatable, Sendable {
        case evidence
        case compareAndCopy
    }

    @Published var mode: Mode = .evidence
    @Published private(set) var evidenceSnapshot:
        GenotypeSupportedAllelesSnapshot
    let comparison: GenotypeSampleComparisonModel

    init(
        evidenceSnapshot: GenotypeSupportedAllelesSnapshot,
        comparison: GenotypeSampleComparisonModel
    ) {
        self.evidenceSnapshot = evidenceSnapshot
        self.comparison = comparison
    }

    func showEvidence() { mode = .evidence }
    func showCompareAndCopy() { mode = .compareAndCopy }

    func refreshEvidence(
        target: GenotypeSupportedAllelesSnapshot,
        comparisonTargetRows: [GenotypeSampleEvidenceRow],
        selectedSourceRows: [GenotypeSampleEvidenceRow]?,
        orderedVisibleRowIDs: [GenotypeCandidateMatrixRowID]? = nil
    ) {
        evidenceSnapshot = target
        comparison.refreshTargetRows(
            comparisonTargetRows,
            selectedSourceRows: selectedSourceRows,
            orderedVisibleRowIDs: orderedVisibleRowIDs
        )
    }
}

@MainActor
struct GenotypeSampleComparisonPanel: View {
    @ObservedObject var model: GenotypeSampleComparisonModel
    var typographyModel: ContentTypographyModel = .shared
    let onBackToEvidence: () -> Void

    private var bodyFont: Font { typographyModel.font(for: .body) }
    private var captionFont: Font {
        typographyModel.font(for: .caption)
    }
    private var headingFont: Font {
        typographyModel.font(for: .emphasizedBody)
    }
    private var typographyScale: CGFloat {
        typographyModel.scaledPointSize(
            fromCanonicalPointSize: 100
        ) / 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare & Copy")
                        .font(headingFont)
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "Compare visible genotype evidence before staging "
                            + "another sample’s haplotype assignments."
                    )
                    .font(captionFont)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Back to Evidence", action: onBackToEvidence)
                    .accessibilityIdentifier(
                        "sample-comparison-back-to-evidence"
                    )
            }
            sourceSelector
            if let source = model.selectedSource {
                summary(source: source)
                rows
                Button("Use \(source) Assignments") {
                    model.requestUseAssignments()
                }
                .disabled(model.pendingSource != nil)
                .accessibilityIdentifier(
                    "sample-comparison-use-assignments"
                )
            } else {
                Text("Choose a source sample to compare genotypes.")
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
            }
            if let status = model.stagedStatus {
                Label(status, systemImage: "checkmark.circle")
                    .font(captionFont)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "sample-comparison-staged-status"
                    )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .confirmationDialog(
            model.confirmationText ?? "",
            isPresented: Binding(
                get: { model.confirmationText != nil },
                set: { presented in
                    if !presented, model.confirmationText != nil {
                        model.cancelUseAssignments()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Replace Draft", role: .destructive) {
                model.confirmUseAssignments()
            }
            Button("Cancel", role: .cancel) {
                model.cancelUseAssignments()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sourceSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                "Search source samples",
                text: Binding(
                    get: { model.searchText },
                    set: { model.updateSearch($0) }
                )
            )
            .font(bodyFont)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(
                "Search samples to compare haplotype assignments"
            )
            .accessibilityIdentifier("sample-comparison-source-search")
            if model.filteredCandidates.isEmpty {
                Text("No samples match this search.")
                    .font(captionFont)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(model.filteredCandidates) { candidate in
                            Button {
                                model.selectSource(candidate.sample)
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(candidate.sample)
                                            .font(bodyFont)
                                        Text(
                                            candidate.completenessSummary
                                                + " · "
                                                + candidate.compactSummary
                                        )
                                        .font(captionFont)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    }
                                    Spacer(minLength: 4)
                                    if model.selectedSource
                                        == candidate.sample {
                                        Image(systemName: "checkmark")
                                            .accessibilityHidden(true)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(candidate.accessibilityLabel)
                            .accessibilityValue(
                                model.selectedSource == candidate.sample
                                    ? "Selected"
                                    : "Not selected"
                            )
                            .accessibilityIdentifier(
                                "sample-comparison-source-\(candidate.sample)"
                            )
                        }
                    }
                }
                .frame(maxHeight: 132 * typographyScale)
                .accessibilityIdentifier(
                    "sample-comparison-source-selector"
                )
            }
        }
    }

    private func summary(source: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(model.targetSample) compared with \(source)")
                .font(headingFont)
            Text(
                "\(model.summary.shared) shared · "
                    + "\(model.summary.targetOnly) "
                    + "\(model.targetSample) only · "
                    + "\(model.summary.sourceOnly) \(source) only"
            )
            .font(captionFont)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sample-comparison-summary")
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.comparisonRows) { row in
                    GenotypeSampleComparisonRowLayout(
                        typographyScale: typographyScale
                    ) {
                        Text(row.allele)
                            .font(bodyFont)
                            .lineLimit(nil)
                            .accessibilityHidden(true)
                        relationshipAndIndicators(row)
                            .accessibilityHidden(true)
                        support(
                            model.targetSample,
                            value: row.targetReadSupport
                        )
                        .accessibilityHidden(true)
                        support(
                            model.selectedSource ?? "Source",
                            value: row.sourceReadSupport
                        )
                        .accessibilityHidden(true)
                    }
                    .padding(.vertical, 5)
                    .overlay(alignment: .bottom) { Divider() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(rowAccessibilityLabel(row))
                    .background(
                        GenotypeSampleComparisonAccessibilityElement(
                            label: rowAccessibilityLabel(row)
                        )
                    )
                    .accessibilityIdentifier(
                        "sample-comparison-row-"
                            + String(describing: row.id)
                    )
                }
            }
        }
        .frame(maxHeight: 340 * typographyScale)
        .accessibilityIdentifier("sample-comparison-rows")
    }

    private func relationshipAndIndicators(
        _ row: GenotypeSampleComparisonRow
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(
                relationshipText(row.relationship),
                systemImage: relationshipSymbol(row.relationship)
            )
            .font(captionFont)
            .foregroundStyle(.secondary)
            if let indicators = row.indicatorSummary {
                Label(indicators, systemImage: "note.text")
                    .font(captionFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func support(_ sample: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(sample)
                .font(captionFont)
                .foregroundStyle(.secondary)
            Text(value).font(bodyFont)
        }
    }

    private func relationshipText(
        _ relationship: GenotypeSampleComparisonRow.Relationship
    ) -> String {
        switch relationship {
        case .shared:
            return "Shared"
        case .targetOnly:
            return "\(model.targetSample) only"
        case .sourceOnly:
            return "\(model.selectedSource ?? "Source") only"
        }
    }

    private func relationshipSymbol(
        _ relationship: GenotypeSampleComparisonRow.Relationship
    ) -> String {
        switch relationship {
        case .shared:
            return "equal.circle.fill"
        case .targetOnly:
            return "arrow.left.circle.fill"
        case .sourceOnly:
            return "arrow.right.circle.fill"
        }
    }

    private func rowAccessibilityLabel(
        _ row: GenotypeSampleComparisonRow
    ) -> String {
        var parts = [
            row.allele,
            relationshipText(row.relationship),
            "\(model.targetSample) read support \(row.targetReadSupport)",
            "\(model.selectedSource ?? "Source") read support "
                + row.sourceReadSupport,
        ]
        if let indicators = row.indicatorSummary {
            parts.append(
                indicators
                    .replacingOccurrences(
                        of: "FP",
                        with: "false positive"
                    )
                    .replacingOccurrences(
                        of: "FN",
                        with: "false negative"
                    )
            )
        }
        return parts.joined(separator: ", ") + "."
    }
}

private struct GenotypeSampleComparisonAccessibilityElement:
    NSViewRepresentable
{
    let label: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSView) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel(label)
    }
}

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

@MainActor
struct GenotypeSampleCurationTrailingPane: View {
    @ObservedObject var model: GenotypeSampleCurationTrailingModel
    var typographyModel: ContentTypographyModel

    var body: some View {
        GenotypeSampleCurationModeOverlayLayout(mode: model.mode) {
            GenotypeSupportedAllelesPanel(
                snapshot: model.evidenceSnapshot,
                typographyModel: typographyModel
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

@MainActor
func makeGenotypeSampleCurationTrailingHostingView(
    model: GenotypeSampleCurationTrailingModel,
    typographyModel: ContentTypographyModel
) -> NSHostingView<GenotypeSampleCurationTrailingPane> {
    let host = NSHostingView(
        rootView: GenotypeSampleCurationTrailingPane(
            model: model,
            typographyModel: typographyModel
        )
    )
    host.sizingOptions = [.intrinsicContentSize]
    host.setContentHuggingPriority(.defaultLow, for: .horizontal)
    host.setContentCompressionResistancePriority(
        .defaultLow,
        for: .horizontal
    )
    host.setAccessibilityIdentifier("sample-curation-trailing-pane")
    return host
}
