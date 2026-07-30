import AppKit
import Combine
import LungfishIO
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
    @State private var keyboardHighlightedSource: String?

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
                GenotypeSampleComparisonActionButton(
                    title: "Back to Evidence",
                    font: typographyModel.resolvedNSFont(for: .body),
                    isEnabled: true,
                    accessibilityIdentifier:
                        "sample-comparison-back-to-evidence",
                    action: onBackToEvidence
                )
            }
            sourceSelector
            if let source = model.selectedSource {
                summary(source: source)
                assignmentChooser
                rows
                GenotypeSampleComparisonActionButton(
                    title:
                        "Stage \(model.selectedSlotAddresses.count) "
                        + "Selected Assignments",
                    font: typographyModel.resolvedNSFont(for: .body),
                    isEnabled: model.canStageSelected,
                    accessibilityIdentifier:
                        "sample-comparison-stage-selected",
                    action: model.requestStageSelected
                )
            } else {
                Text("Choose a source sample to compare genotypes.")
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
            }
            if let status = model.stagedStatus {
                Label(
                    status,
                    systemImage:
                        status.contains("Review")
                        ? "exclamationmark.triangle"
                        : "checkmark.circle"
                )
                    .font(captionFont)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "sample-comparison-staged-status"
                    )
            }
            if let readOnlyStatus = model.readOnlyStatus {
                Label(readOnlyStatus, systemImage: "lock")
                    .font(captionFont)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "sample-comparison-read-only-status"
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
                        model.cancelStageSelected()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Stage Selected Assignments") {
                model.confirmStageSelected()
            }
            Button("Cancel", role: .cancel) {
                model.cancelStageSelected()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sourceSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            GenotypeSampleSourceSearchField(
                text: Binding(
                    get: { model.searchText },
                    set: { query in
                        model.updateSearch(query)
                        reconcileKeyboardHighlight()
                    }
                ),
                font: typographyModel.resolvedNSFont(for: .body),
                keyboardHighlightedSource: keyboardHighlightedSource,
                onMove: moveKeyboardHighlight,
                onCommit: selectKeyboardHighlightedSource
            )
            .disabled(model.isInteractionPending)
            .frame(
                minHeight: max(
                    22,
                    typographyModel.scaledPointSize(
                        fromCanonicalPointSize: 22
                    )
                )
            )
            if model.filteredCandidates.isEmpty {
                Text("No samples match this search.")
                    .font(captionFont)
                    .foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(model.filteredCandidates) { candidate in
                                Button {
                                    keyboardHighlightedSource =
                                        candidate.sample
                                    model.selectSource(candidate.sample)
                                } label: {
                                    HStack(alignment: .firstTextBaseline) {
                                        VStack(
                                            alignment: .leading,
                                            spacing: 1
                                        ) {
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
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(
                                                keyboardHighlightedSource
                                                    == candidate.sample
                                                    ? Color.accentColor.opacity(
                                                        0.14
                                                    )
                                                    : Color.clear
                                            )
                                    )
                                }
                                .disabled(model.isInteractionPending)
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    candidate.accessibilityLabel
                                )
                                .accessibilityValue(
                                    sourceCandidateAccessibilityValue(
                                        candidate.sample
                                    )
                                )
                                .accessibilityIdentifier(
                                    "sample-comparison-source-"
                                        + candidate.sample
                                )
                                .id(candidate.sample)
                            }
                        }
                    }
                    .onChange(of: keyboardHighlightedSource) {
                        _, highlightedSource in
                        if let highlightedSource {
                            proxy.scrollTo(
                                highlightedSource,
                                anchor: .center
                            )
                        }
                    }
                    .frame(maxHeight: 132 * typographyScale)
                    .accessibilityIdentifier(
                        "sample-comparison-source-selector"
                    )
                }
            }
        }
        .background(GenotypeSampleSourceSelectorIdentityView())
    }

    private var assignmentChooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Choose Haplotype Assignments")
                    .font(headingFont)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                GenotypeSampleComparisonActionButton(
                    title: "Select All Assigned",
                    font: typographyModel.resolvedNSFont(for: .caption),
                    isEnabled:
                        !model.isInteractionPending
                        && model.assignmentChoices.contains(
                            where: \.isSelectable
                        ),
                    accessibilityIdentifier:
                        "sample-comparison-select-all-assigned",
                    action: model.selectAllAssigned
                )
            }
            Text(
                "Select only the locus and haplotype slots you want to "
                    + "stage. Nothing is selected automatically."
            )
            .font(captionFont)
            .foregroundStyle(.secondary)

            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(
                    GenotypeManualHaplotypeLocus.allCases,
                    id: \.self
                ) { locus in
                    assignmentLocus(locus)
                }
            }
            .accessibilityIdentifier(
                "sample-comparison-assignment-chooser"
            )
        }
    }

    private func assignmentLocus(
        _ locus: GenotypeManualHaplotypeLocus
    ) -> some View {
        let choices = model.assignmentChoices.filter {
            $0.address.locus == locus
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(locus.workbookLabel)
                    .font(headingFont)
                Spacer(minLength: 4)
                GenotypeSampleComparisonActionButton(
                    title: "Select Assigned",
                    font: typographyModel.resolvedNSFont(for: .caption),
                    isEnabled:
                        !model.isInteractionPending
                        && choices.contains(where: \.isSelectable),
                    accessibilityIdentifier:
                        "sample-comparison-select-locus-"
                        + locus.rawValue,
                    action: { model.selectAssigned(in: locus) }
                )
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(choices) { choice in
                        assignmentChoice(choice)
                            .frame(maxWidth: .infinity)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(choices) { choice in
                        assignmentChoice(choice)
                    }
                }
            }
            Divider()
        }
    }

    private func assignmentChoice(
        _ choice: GenotypeSampleComparisonModel.AssignmentChoice
    ) -> some View {
        let description = assignmentChoiceDescription(choice)
        return HStack(alignment: .top, spacing: 6) {
            GenotypeSampleAssignmentCheckbox(
                isOn: model.selectedSlotAddresses.contains(
                    choice.address
                ),
                isEnabled:
                    choice.isSelectable
                    && !model.isInteractionPending,
                accessibilityIdentifier:
                    "sample-comparison-choice-"
                    + choice.address.locus.rawValue
                    + "-"
                    + choice.address.slot.rawValue,
                accessibilityLabel:
                    "\(choice.address.locus.workbookLabel) "
                    + "\(choice.address.slot.displayName). "
                    + description,
                accessibilityValue: description,
                onChange: {
                    model.setSelected($0, at: choice.address)
                }
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(choice.address.slot.displayName)
                    .font(headingFont)
                Text(description)
                    .font(captionFont)
                    .foregroundStyle(
                        choice.isSelectable ? .primary : .secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }

    private func assignmentChoiceDescription(
        _ choice: GenotypeSampleComparisonModel.AssignmentChoice
    ) -> String {
        let source = choice.sourceLabel ?? "Unassigned"
        let target = choice.targetLabel ?? "Unassigned"
        let outcome: String
        if choice.sourceLabel == nil {
            outcome = "Source slot is unassigned."
        } else {
            switch choice.outcome {
            case .fillsEmpty:
                outcome = "Fills empty slot."
            case .replaces(let label):
                outcome = "Replaces \(label)."
            case .sameAssignment:
                outcome = "Same assignment."
            case .unavailableHiddenMetadata:
                outcome =
                    "Unavailable until hidden legacy metadata is cleared."
            }
        }
        return "Source: \(source). Target: \(target). \(outcome)"
    }

    private func moveKeyboardHighlight(_ direction: Int) -> Bool {
        let candidates = model.filteredCandidates.map(\.sample)
        guard !candidates.isEmpty else { return false }
        if let keyboardHighlightedSource,
           let current = candidates.firstIndex(
               of: keyboardHighlightedSource
           ) {
            let next = min(
                max(current + direction, candidates.startIndex),
                candidates.index(before: candidates.endIndex)
            )
            self.keyboardHighlightedSource = candidates[next]
        } else {
            keyboardHighlightedSource =
                direction < 0 ? candidates.last : candidates.first
        }
        return true
    }

    private func selectKeyboardHighlightedSource() -> Bool {
        guard let keyboardHighlightedSource,
              model.filteredCandidates.contains(where: {
                  $0.sample == keyboardHighlightedSource
              }) else {
            return false
        }
        model.selectSource(keyboardHighlightedSource)
        return true
    }

    private func reconcileKeyboardHighlight() {
        guard let keyboardHighlightedSource else { return }
        if !model.filteredCandidates.contains(where: {
            $0.sample == keyboardHighlightedSource
        }) {
            self.keyboardHighlightedSource = nil
        }
    }

    private func sourceCandidateAccessibilityValue(
        _ sample: String
    ) -> String {
        switch (
            model.selectedSource == sample,
            keyboardHighlightedSource == sample
        ) {
        case (true, true):
            return "Selected and keyboard highlighted"
        case (true, false):
            return "Selected"
        case (false, true):
            return "Keyboard highlighted"
        case (false, false):
            return "Not selected"
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
            if !row.semanticQualifiers.isEmpty {
                Label(
                    row.semanticQualifiers.joined(separator: ", "),
                    systemImage: "tag"
                )
                .font(captionFont)
                .foregroundStyle(.secondary)
            }
            if let commentSummary = compactScopedCommentSummary(row) {
                Label(commentSummary, systemImage: "text.bubble")
                    .font(captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
        if let commentSummary = scopedCommentSummary(row) {
            parts.append(commentSummary)
        }
        if let targetAccessibilityLabel =
            row.targetAccessibilityLabel {
            parts.append(targetAccessibilityLabel)
        }
        if let sourceAccessibilityLabel =
            row.sourceAccessibilityLabel {
            parts.append(sourceAccessibilityLabel)
        }
        return parts.joined(separator: ", ") + "."
    }

    private func scopedCommentSummary(
        _ row: GenotypeSampleComparisonRow
    ) -> String? {
        let summary = [
            scopedCommentSummary(
                sample: model.targetSample,
                counts: row.targetCommentCounts
            ),
            scopedCommentSummary(
                sample: model.selectedSource ?? "Source",
                counts: row.sourceCommentCounts
            ),
        ]
        .compactMap { $0 }
        .joined(separator: "; ")
        return summary.isEmpty ? nil : summary
    }

    private func compactScopedCommentSummary(
        _ row: GenotypeSampleComparisonRow
    ) -> String? {
        let summaries = [
            compactScopedCommentSummary(
                sample: model.targetSample,
                counts: row.targetCommentCounts
            ),
            compactScopedCommentSummary(
                sample: model.selectedSource ?? "Source",
                counts: row.sourceCommentCounts
            ),
        ].compactMap { $0 }
        guard !summaries.isEmpty else { return nil }
        return "Comments · " + summaries.joined(separator: " · ")
    }

    private func compactScopedCommentSummary(
        sample: String,
        counts: GenotypeMatrixScopedCommentCounts
    ) -> String? {
        var scopes: [String] = []
        if counts.alleleRow > 0 {
            scopes.append("row")
        }
        if counts.sampleColumn > 0 {
            scopes.append("column")
        }
        if counts.cell > 0 {
            scopes.append("cell")
        }
        guard !scopes.isEmpty else { return nil }
        return "\(sample): \(scopes.joined(separator: ", "))"
    }

    private func scopedCommentSummary(
        sample: String,
        counts: GenotypeMatrixScopedCommentCounts
    ) -> String? {
        var scopes: [String] = []
        if counts.alleleRow > 0 {
            scopes.append("allele row")
        }
        if counts.sampleColumn > 0 {
            scopes.append("sample column")
        }
        if counts.cell > 0 {
            scopes.append("cell")
        }
        guard !scopes.isEmpty else { return nil }
        return "\(sample) comments: \(scopes.joined(separator: ", "))"
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
private struct GenotypeSampleSourceSearchField: NSViewRepresentable {
    @Environment(\.isEnabled) private var environmentIsEnabled
    @Binding var text: String
    let font: NSFont
    let keyboardHighlightedSource: String?
    let onMove: (Int) -> Bool
    let onCommit: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onMove: onMove,
            onCommit: onCommit
        )
    }

    func makeNSView(context: Context) -> InteractionSearchField {
        let field = InteractionSearchField()
        field.delegate = context.coordinator
        configure(field, coordinator: context.coordinator)
        return field
    }

    func updateNSView(
        _ field: InteractionSearchField,
        context: Context
    ) {
        configure(field, coordinator: context.coordinator)
    }

    private func configure(
        _ field: InteractionSearchField,
        coordinator: Coordinator
    ) {
        coordinator.text = $text
        coordinator.onMove = onMove
        coordinator.onCommit = onCommit
        if field.stringValue != text {
            field.stringValue = text
        }
        field.isEnabled = environmentIsEnabled
        field.allowsUserInteraction = environmentIsEnabled
        field.setAccessibilityElement(environmentIsEnabled)
        field.font = font
        field.placeholderString = "Search source samples"
        field.setAccessibilityLabel(
            "Search samples to compare haplotype assignments"
        )
        let keyboardInstructions =
            "Use Up and Down Arrow to highlight a filtered sample, "
            + "then press Return to select it."
        if let keyboardHighlightedSource {
            field.setAccessibilityHelp(
                "Keyboard highlighted sample: "
                    + "\(keyboardHighlightedSource). "
                    + keyboardInstructions
            )
        } else {
            field.setAccessibilityHelp(keyboardInstructions)
        }
        field.setAccessibilityIdentifier(
            "sample-comparison-source-search"
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onMove: (Int) -> Bool
        var onCommit: () -> Bool

        init(
            text: Binding<String>,
            onMove: @escaping (Int) -> Bool,
            onCommit: @escaping () -> Bool
        ) {
            self.text = text
            self.onMove = onMove
            self.onCommit = onCommit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else {
                return
            }
            text.wrappedValue = field.stringValue
        }

        func control(
            _: NSControl,
            textView _: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                return onMove(1)
            case #selector(NSResponder.moveUp(_:)):
                return onMove(-1)
            case #selector(NSResponder.insertNewline(_:)):
                return onCommit()
            default:
                return false
            }
        }
    }

    @MainActor
    final class InteractionSearchField: NSSearchField {
        var allowsUserInteraction = true

        override func hitTest(_ point: NSPoint) -> NSView? {
            allowsUserInteraction ? super.hitTest(point) : nil
        }
    }
}

@MainActor
private struct GenotypeSampleComparisonActionButton:
    NSViewRepresentable
{
    @Environment(\.isEnabled) private var environmentIsEnabled
    let title: String
    let font: NSFont
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> InteractionButton {
        let button = InteractionButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.performAction)
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        configure(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(
        _ button: InteractionButton,
        context: Context
    ) {
        configure(button, coordinator: context.coordinator)
    }

    private func configure(
        _ button: InteractionButton,
        coordinator: Coordinator
    ) {
        coordinator.action = action
        let interactionEnabled = environmentIsEnabled && isEnabled
        button.title = title
        button.font = font
        button.isEnabled = interactionEnabled
        button.allowsUserInteraction = interactionEnabled
        button.setAccessibilityElement(interactionEnabled)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }

    @MainActor
    final class InteractionButton: NSButton {
        var allowsUserInteraction = true

        override var isEnabled: Bool {
            get { allowsUserInteraction && super.isEnabled }
            set { super.isEnabled = newValue }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            allowsUserInteraction ? super.hitTest(point) : nil
        }
    }
}

@MainActor
private struct GenotypeSampleAssignmentCheckbox:
    NSViewRepresentable
{
    let isOn: Bool
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> KeyboardCheckbox {
        let button = KeyboardCheckbox(
            checkboxWithTitle: "",
            target: context.coordinator,
            action: #selector(Coordinator.performAction(_:))
        )
        button.controlSize = .small
        configure(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(
        _ button: KeyboardCheckbox,
        context: Context
    ) {
        configure(button, coordinator: context.coordinator)
    }

    private func configure(
        _ button: KeyboardCheckbox,
        coordinator: Coordinator
    ) {
        coordinator.onChange = onChange
        button.state = isOn ? .on : .off
        button.interactionEnabled = isEnabled
        button.isEnabled = isEnabled
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.checkBox)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(
            "\(isOn ? "Selected" : "Not selected"). "
                + accessibilityValue
        )
        button.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }

        @objc func performAction(_ sender: NSButton) {
            onChange(sender.state == .on)
        }
    }

    @MainActor
    final class KeyboardCheckbox: NSButton {
        override var acceptsFirstResponder: Bool { isEnabled }
        var interactionEnabled = true {
            didSet { super.isEnabled = interactionEnabled }
        }

        override var isEnabled: Bool {
            get { interactionEnabled && super.isEnabled }
            set { super.isEnabled = newValue }
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123, 126:
                window?.selectPreviousKeyView(self)
            case 124, 125:
                window?.selectNextKeyView(self)
            default:
                super.keyDown(with: event)
            }
        }
    }
}

@MainActor
private struct GenotypeSampleSourceSelectorIdentityView:
    NSViewRepresentable
{
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        view.setAccessibilityIdentifier(
            "sample-comparison-source-selector"
        )
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        view.setAccessibilityElement(false)
        view.setAccessibilityIdentifier(
            "sample-comparison-source-selector"
        )
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
) -> NSView {
    GenotypeSampleCurationTrailingHostView(
        model: model,
        typographyModel: typographyModel
    )
}

@MainActor
private final class GenotypeSampleCurationTrailingHostView: NSView {
    private let hostingController:
        NSHostingController<GenotypeSampleCurationTrailingPane>
    private var cancellables: Set<AnyCancellable> = []
    private var cachedMeasurement: (width: CGFloat, height: CGFloat)?

    init(
        model: GenotypeSampleCurationTrailingModel,
        typographyModel: ContentTypographyModel
    ) {
        hostingController = NSHostingController(
            rootView: GenotypeSampleCurationTrailingPane(
                model: model,
                typographyModel: typographyModel
            )
        )
        super.init(frame: .zero)

        let hostedView = hostingController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        setContentCompressionResistancePriority(
            .required,
            for: .vertical
        )
        setAccessibilityIdentifier("sample-curation-trailing-pane")

        model.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async {
                    self?.invalidateWidthAwareIntrinsicSize()
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(
            for: .contentTextSizeDidChange
        )
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.invalidateWidthAwareIntrinsicSize()
                }
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let proposedWidth = bounds.width > 0 ? bounds.width : 420
        if let cachedMeasurement,
           abs(cachedMeasurement.width - proposedWidth) <= 0.5 {
            return NSSize(
                width: NSView.noIntrinsicMetric,
                height: cachedMeasurement.height
            )
        }
        let measured = hostingController.sizeThatFits(
            in: NSSize(
                width: proposedWidth,
                height: .greatestFiniteMagnitude
            )
        )
        let measuredHeight = ceil(measured.height)
        cachedMeasurement = (proposedWidth, measuredHeight)
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: measuredHeight
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            invalidateWidthAwareIntrinsicSize()
        }
    }

    private func invalidateWidthAwareIntrinsicSize() {
        cachedMeasurement = nil
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }
}
