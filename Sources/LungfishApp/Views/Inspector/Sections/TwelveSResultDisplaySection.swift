import LungfishTwelveSUI
import SwiftUI
import LungfishCore
import LungfishIO

/// Tri-state for a taxon-group filter pill: neutral (no constraint), included
/// (only this group passes), or excluded (this group is hidden). Include and
/// exclude are mutually exclusive — enforced by the view-model's setters.
enum TaxonPillState {
    case neutral
    case included
    case excluded
}

@Observable
@MainActor
final class TwelveSResultDisplaySectionViewModel {
    var displayState = TwelveSResultDisplayState()
    var isAvailable = false
    var summaryRowLabel = "Species Rows"
    var visibleRowCount = 0
    var totalRowCount = 0
    var sampleCount = 0
    var sampleMetadataStore: SampleMetadataStore?
    var sampleMetadataManifest: TwelveSSampleMetadataSnapshotManifest?
    var isExpanded = true
    var taxonGroupOptions = ["Mammal", "Fish", "Bird", "Reptile", "Amphibian"]

    var onDisplayStateChanged: ((TwelveSResultDisplayState) -> Void)?
    var onExportRequested: ((TwelveSAmpliconResultExportFormat) -> Void)?

    func update(isAvailable: Bool, state: TwelveSResultDisplayState = TwelveSResultDisplayState()) {
        self.isAvailable = isAvailable
        displayState = state
    }

    func updateSummary(_ summary: TwelveSResultDisplaySummary) {
        summaryRowLabel = summary.rowLabel
        visibleRowCount = summary.visibleRows
        totalRowCount = summary.totalRows
    }

    func updateSamples(
        count: Int,
        metadata: ResolvedSampleMetadata?,
        manifest: TwelveSSampleMetadataSnapshotManifest?
    ) {
        sampleCount = count
        sampleMetadataManifest = manifest
        sampleMetadataStore = metadata.flatMap { resolved in
            resolved.hasMetadataFields ? SampleMetadataStore(resolved: resolved) : nil
        }
    }

    var sampleMetadataSourceSummary: String {
        guard let manifest = sampleMetadataManifest else {
            return sampleMetadataStore == nil ? "Sample IDs frozen in result bundle" : "Resolved sample metadata"
        }
        switch (manifest.hasAnalysisMetadata, manifest.hasFASTQMetadata) {
        case (true, true):
            return "Analysis metadata layered over FASTQ metadata"
        case (true, false):
            return "Analysis metadata"
        case (false, true):
            return "FASTQ metadata"
        case (false, false):
            return "Sample IDs frozen in result bundle"
        }
    }

    var sampleMetadataSourceDetails: [String] {
        sampleMetadataManifest?.sources.map(sourceDetail) ?? []
    }

    var sampleMetadataWarnings: [String] {
        sampleMetadataManifest?.warnings ?? []
    }

    func updateTaxonGroupOptions(_ groups: [String]) {
        let known = Set(taxonGroupOptions)
        let discovered = Set(groups.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        taxonGroupOptions = Array(known.union(discovered)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func updateDisplayState(_ state: TwelveSResultDisplayState) {
        displayState = state
    }

    func setMinimumExactReads(_ value: Int) {
        displayState.minimumExactReads = max(0, value)
        notifyStateChanged()
    }

    func setFilterText(_ value: String) {
        displayState.filterText = value
        notifyStateChanged()
    }

    func setIncludedTaxonGroups(_ values: Set<String>) {
        displayState.includedTaxonGroups = values
        notifyStateChanged()
    }

    func setIncludedTaxonGroup(_ value: String, isIncluded: Bool) {
        var included = displayState.includedTaxonGroups
        var excluded = displayState.excludedTaxonGroups
        if isIncluded {
            included.insert(value)
            excluded.remove(value)
        } else {
            included.remove(value)
        }
        displayState.includedTaxonGroups = included
        displayState.excludedTaxonGroups = excluded
        notifyStateChanged()
    }

    func setExcludedTaxonGroups(_ values: Set<String>) {
        displayState.excludedTaxonGroups = values
        notifyStateChanged()
    }

    func setExcludedTaxonGroup(_ value: String, isExcluded: Bool) {
        var included = displayState.includedTaxonGroups
        var excluded = displayState.excludedTaxonGroups
        if isExcluded {
            excluded.insert(value)
            included.remove(value)
        } else {
            excluded.remove(value)
        }
        displayState.includedTaxonGroups = included
        displayState.excludedTaxonGroups = excluded
        notifyStateChanged()
    }

    /// Reports the current tri-state for a taxon group by reading the single
    /// source of truth (`displayState`). Include and exclude are mutually
    /// exclusive, so at most one set contains the group.
    func pillState(for group: String) -> TaxonPillState {
        if displayState.includedTaxonGroups.contains(group) {
            return .included
        }
        if displayState.excludedTaxonGroups.contains(group) {
            return .excluded
        }
        return .neutral
    }

    /// Advances a taxon group's pill through neutral → included → excluded →
    /// neutral. All transitions route through the existing mutually-exclusive
    /// setters so the display-state-change callback fires and exclusivity is
    /// preserved through one code path (no parallel filter logic here).
    func cycleTaxonGroup(_ group: String) {
        switch pillState(for: group) {
        case .neutral:
            setIncludedTaxonGroup(group, isIncluded: true)
        case .included:
            setExcludedTaxonGroup(group, isExcluded: true)
        case .excluded:
            setExcludedTaxonGroup(group, isExcluded: false)
        }
    }

    func setExcludeHuman(_ value: Bool) {
        displayState.excludeHuman = value
        notifyStateChanged()
    }

    func setRequireAlternateMatches(_ value: Bool) {
        displayState.requireAlternateMatches = value
        notifyStateChanged()
    }

    func setMinimumUnresolvedReads(_ value: Int) {
        displayState.minimumUnresolvedReads = max(0, value)
        notifyStateChanged()
    }

    func setChimeraFilter(_ value: TwelveSChimeraStatusFilter) {
        displayState.chimeraFilter = value
        notifyStateChanged()
    }

    func export(format: TwelveSAmpliconResultExportFormat) {
        onExportRequested?(format)
    }

    func clear() {
        displayState = TwelveSResultDisplayState()
        isAvailable = false
        summaryRowLabel = "Species Rows"
        visibleRowCount = 0
        totalRowCount = 0
        sampleCount = 0
        sampleMetadataStore = nil
        sampleMetadataManifest = nil
        taxonGroupOptions = ["Mammal", "Fish", "Bird", "Reptile", "Amphibian"]
    }

    private func notifyStateChanged() {
        onDisplayStateChanged?(displayState)
    }

    private func sourceDetail(_ source: SampleMetadataSourceSummary) -> String {
        var parts = [source.kind.displayName]
        if let matched = source.matchedSampleCount, let total = source.totalRows {
            parts.append("\(matched) of \(total) matched")
        } else if let matched = source.matchedSampleCount {
            parts.append("\(matched) matched")
        }
        if let unmatched = source.unmatchedRowCount, unmatched > 0 {
            parts.append("\(unmatched) unmatched")
        }
        if let missing = source.missingSampleCount, missing > 0 {
            parts.append("\(missing) missing")
        }
        if let path = source.path?.split(separator: "/").last {
            parts.append(String(path))
        }
        return parts.joined(separator: " · ")
    }
}

struct TwelveSResultDisplaySection: View {
    @Bindable var viewModel: TwelveSResultDisplaySectionViewModel
    @State private var areTargetFiltersExpanded = true
    @State private var areUnmatchedFiltersExpanded = false

    var body: some View {
        if viewModel.isAvailable {
            DisclosureGroup(isExpanded: $viewModel.isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    summary
                    Divider()
                    DisclosureGroup("Target Rows", isExpanded: $areTargetFiltersExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            filterControls
                            taxonomyControls
                        }
                        .padding(.top, 4)
                    }
                    DisclosureGroup("Unmatched Reads", isExpanded: $areUnmatchedFiltersExpanded) {
                        unresolvedControls
                            .padding(.top, 4)
                    }
                    exportControls
                }
                .padding(.top, 4)
            } label: {
                Label("12S Results", systemImage: "tablecells")
                    .font(.headline)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(viewModel.summaryRowLabel, value: "\(viewModel.visibleRowCount) of \(viewModel.totalRowCount)")
        }
        .font(.callout)
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Minimum Exact Reads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Minimum", value: Binding(
                        get: { viewModel.displayState.minimumExactReads },
                        set: { viewModel.setMinimumExactReads($0) }
                    ), format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 74)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                    Stepper(
                        "",
                        value: Binding(
                            get: { viewModel.displayState.minimumExactReads },
                            set: { viewModel.setMinimumExactReads($0) }
                        ),
                        in: 0...1_000_000
                    )
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        }
    }

    // Converges on the genotype quick-filter pill idiom (pill-shaped toggles in
    // a row, selected state in Lungfish Orange). The genotype bar is AppKit
    // `pushOnPushOff` buttons; this is SwiftUI, so we match the visual and
    // interaction idiom rather than reusing the AppKit view. A shared
    // cross-framework pill component is deferred to P2.
    private var taxonomyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Attributes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowingPillRow {
                    BooleanFilterPill(
                        title: "Exclude Human",
                        isOn: viewModel.displayState.excludeHuman,
                        action: { viewModel.setExcludeHuman(!viewModel.displayState.excludeHuman) }
                    )
                    .accessibilityIdentifier("twelve-s-bool-pill-exclude-human")

                    BooleanFilterPill(
                        title: "Only With Alternates",
                        isOn: viewModel.displayState.requireAlternateMatches,
                        action: { viewModel.setRequireAlternateMatches(!viewModel.displayState.requireAlternateMatches) }
                    )
                    .accessibilityIdentifier("twelve-s-bool-pill-only-with-alternates")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Taxon Groups")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowingPillRow {
                    ForEach(viewModel.taxonGroupOptions, id: \.self) { group in
                        TaxonGroupPill(
                            title: group,
                            state: viewModel.pillState(for: group),
                            action: { viewModel.cycleTaxonGroup(group) }
                        )
                        .accessibilityIdentifier("twelve-s-taxon-pill-\(group)")
                    }
                }
            }
        }
    }

    private var unresolvedControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Minimum Unresolved Reads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Minimum", value: Binding(
                        get: { viewModel.displayState.minimumUnresolvedReads },
                        set: { viewModel.setMinimumUnresolvedReads($0) }
                    ), format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 74)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                    Stepper(
                        "",
                        value: Binding(
                            get: { viewModel.displayState.minimumUnresolvedReads },
                            set: { viewModel.setMinimumUnresolvedReads($0) }
                        ),
                        in: 0...1_000_000
                    )
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            Picker("Chimera", selection: Binding(
                get: { viewModel.displayState.chimeraFilter },
                set: { viewModel.setChimeraFilter($0) }
            )) {
                ForEach(TwelveSChimeraStatusFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .controlSize(.small)
        }
    }

    private var exportControls: some View {
        Menu {
            ForEach(TwelveSAmpliconResultExportFormat.allCases) { format in
                Button(format.displayName) {
                    viewModel.export(format: format)
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .controlSize(.small)
        .accessibilityIdentifier("twelve-s-export-menu")
    }
}

// MARK: - Filter pills

/// A binary filter pill matching the genotype quick-filter bar idiom: a
/// pill-shaped toggle that fills with Lungfish Orange when on. This is the
/// faithful SwiftUI equivalent of the AppKit `pushOnPushOff` pills in
/// `GenotypeQuickFilterBarView`.
private struct BooleanFilterPill: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isOn ? Color.lungfishOrangeFallback : Color.clear)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isOn ? Color.lungfishOrangeFallback : Color.lungfishStroke,
                            lineWidth: 1
                        )
                )
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// A tri-state taxon-group pill. Visual distinctions (documented so the three
/// states are unambiguous):
///   - neutral  → outlined capsule, no glyph (no constraint applied)
///   - included → filled Lungfish Orange with a leading "+" (only this group)
///   - excluded → orange-outlined capsule with a leading "−" and a struck-out
///                 label (this group is hidden)
/// Tapping cycles neutral → included → excluded → neutral via the view-model's
/// `cycleTaxonGroup`, which routes through the mutually-exclusive setters.
private struct TaxonGroupPill: View {
    let title: String
    let state: TaxonPillState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let glyph = leadingGlyph {
                    Image(systemName: glyph)
                        .font(.caption2.weight(.bold))
                }
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .strikethrough(state == .excluded, color: Color.lungfishOrangeFallback)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(fillColor)
            )
            .overlay(
                Capsule().strokeBorder(strokeColor, lineWidth: 1)
            )
            .foregroundStyle(labelColor)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var leadingGlyph: String? {
        switch state {
        case .neutral:  return nil
        case .included: return "plus"
        case .excluded: return "minus"
        }
    }

    private var fillColor: Color {
        state == .included ? Color.lungfishOrangeFallback : Color.clear
    }

    private var strokeColor: Color {
        switch state {
        case .neutral:  return Color.lungfishStroke
        case .included, .excluded: return Color.lungfishOrangeFallback
        }
    }

    private var labelColor: Color {
        switch state {
        case .neutral:  return Color.primary
        case .included: return Color.white
        case .excluded: return Color.lungfishOrangeFallback
        }
    }

    private var helpText: String {
        switch state {
        case .neutral:  return "\(title): no filter (tap to include)"
        case .included: return "\(title): included (tap to exclude)"
        case .excluded: return "\(title): excluded (tap to clear)"
        }
    }
}

/// A wrapping horizontal row of pills. Lays children left-to-right, wrapping to
/// a new line when the available width is exceeded, so the Inspector's narrow
/// column never clips the pill set.
private struct FlowingPillRow: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for size in sizes {
            if rowWidth > 0, rowWidth + horizontalSpacing + size.width > maxWidth {
                totalHeight += rowHeight + verticalSpacing
                maxRowWidth = max(maxRowWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? horizontalSpacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, rowWidth)

        let resolvedWidth = proposal.width ?? maxRowWidth
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            if x > bounds.minX, x + size.width - bounds.minX > maxWidth {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private extension ResolvedSampleMetadata {
    var hasMetadataFields: Bool {
        columns.contains { normalizedSampleMetadataColumn($0) != "sample_id" }
    }
}

private extension SampleMetadataSourceKind {
    var displayName: String {
        switch self {
        case .intrinsic:
            return "Intrinsic sample list"
        case .fastqFolder:
            return "FASTQ folder metadata"
        case .fastqBundle:
            return "FASTQ bundle metadata"
        case .analysisOverride:
            return "Analysis metadata"
        case .importedCSV:
            return "Imported metadata"
        }
    }
}

private func normalizedSampleMetadataColumn(_ column: String) -> String {
    column.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: " ", with: "_")
}
