import SwiftUI
import LungfishCore
import LungfishIO

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

    private var taxonomyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Exclude Human", isOn: Binding(
                get: { viewModel.displayState.excludeHuman },
                set: { viewModel.setExcludeHuman($0) }
            ))
            .controlSize(.small)

            Toggle("Only Rows With Alternates", isOn: Binding(
                get: { viewModel.displayState.requireAlternateMatches },
                set: { viewModel.setRequireAlternateMatches($0) }
            ))
            .controlSize(.small)

            HStack(spacing: 8) {
                Menu {
                    ForEach(viewModel.taxonGroupOptions, id: \.self) { group in
                        Toggle(group, isOn: Binding(
                            get: { viewModel.displayState.includedTaxonGroups.contains(group) },
                            set: { viewModel.setIncludedTaxonGroup(group, isIncluded: $0) }
                        ))
                    }
                } label: {
                    Label("Include", systemImage: "line.3.horizontal.decrease.circle")
                }
                .controlSize(.small)

                Menu {
                    ForEach(viewModel.taxonGroupOptions, id: \.self) { group in
                        Toggle(group, isOn: Binding(
                            get: { viewModel.displayState.excludedTaxonGroups.contains(group) },
                            set: { viewModel.setExcludedTaxonGroup(group, isExcluded: $0) }
                        ))
                    }
                } label: {
                    Label("Exclude", systemImage: "line.3.horizontal.decrease.circle.fill")
                }
                .controlSize(.small)
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
