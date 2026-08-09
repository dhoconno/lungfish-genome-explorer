// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishGenotypeUI
import LungfishWorkflow
import os.log
import LungfishKit


// MARK: - InspectorView (SwiftUI)

/// SwiftUI view for the inspector panel content.
///
/// Displays a Keynote-style tabbed interface with three tabs:
/// - **Document**: Bundle metadata, source info, genome summary, extended metadata
/// - **Selection**: Annotation editing, appearance settings, annotation style, read style
/// - **AI**: Embedded AI assistant chat interface
///
/// Uses fixed-width text controls at the top of the panel for tab switching.
public struct InspectorView: View {
    @Bindable var viewModel: InspectorViewModel
    @State private var settings = AppSettings.shared

    public var body: some View {
        VStack(spacing: 0) {
            // Tab picker at top — only shows tabs available for current content mode
            tabPicker

            Divider()

            tabContent
        }
        .onChange(of: viewModel.selectedTab) { _, tab in
            guard tab == .ai, viewModel.aiAssistantService == nil else { return }
            NotificationCenter.default.post(
                name: .showAIAssistantRequested,
                object: nil,
                userInfo: viewModel.windowScopedUserInfo()
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Tab Picker

    @ViewBuilder
    private var tabPicker: some View {
        let tabs = viewModel.availableTabs
        if tabs.count > 1 {
            InspectorTabGrid(tabs: tabs, selectedTab: $viewModel.selectedTab)
            .padding(.horizontal)
            .padding(.vertical, 8)
        } else if let single = tabs.first {
            // Single-tab mode: show a label instead of a picker
            HStack {
                Text(single.displayLabel)
                    .font(LungfishInspectorStyle.sectionTitleFont)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch viewModel.selectedTab {
        case .bundle, .selectedItem, .annotations, .view, .analysis, .fastqMetadata, .resultSummary, .twelveSDetail, .provenance:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    tabScrollContent
                    Spacer()
                }
                .padding()
            }

        case .ai:
            if let service = viewModel.aiAssistantService {
                EmbeddedAIAssistantView(service: service)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI Assistant")
                        .font(.headline)
                    Text("Enable AI services in Settings > AI Services to use the assistant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private var tabScrollContent: some View {
        switch viewModel.selectedTab {
        case .bundle:
            DocumentSection(viewModel: viewModel.documentSectionViewModel)
            if viewModel.readStyleSectionViewModel.hasAlignmentTracks {
                Divider()
                AlignmentBundleSection(viewModel: viewModel.readStyleSectionViewModel)
            }
            // Show FASTQ metadata in Document tab when in FASTQ mode
            if viewModel.contentMode == .fastq {
                FASTQMetadataSection(viewModel: viewModel.fastqMetadataSectionViewModel)
                FASTQPBAAArtifactsSection(viewModel: viewModel.fastqPBAAArtifactsSectionViewModel)
            }

        case .selectedItem:
            SelectionSection(viewModel: viewModel.selectionSectionViewModel)

            // Variant detail (shown when a variant is selected)
            VariantSection(viewModel: viewModel.variantSectionViewModel)

            if viewModel.readStyleSectionViewModel.selectedRead != nil {
                Divider()
                ReadSelectionSection(viewModel: viewModel.readStyleSectionViewModel)
            }

        case .annotations:
            VStack(alignment: .leading, spacing: 12) {
                GenotypeAnnotationIdentitySection(
                    analystIdentity: settings.resolvedAnalystIdentity(),
                    openSettings: { SettingsNavigationState.shared.open(.general) }
                )
                GenotypeMatrixAnnotationSection(viewModel: viewModel.genotypeResultDisplaySectionViewModel)
            }

        case .view:
            InspectorReadStyleSection(viewModel: viewModel)

        case .analysis:
            InspectorAnalysisWorkflowSection(viewModel: viewModel)

        case .fastqMetadata:
            FASTQMetadataSection(viewModel: viewModel.fastqMetadataSectionViewModel)

        case .resultSummary:
            MetagenomicsResultSummarySection(
                viewModel: viewModel.documentSectionViewModel,
                twelveSViewModel: viewModel.twelveSResultDisplaySectionViewModel,
                windowStateScope: viewModel.windowStateScope
            )

        case .twelveSDetail:
            TwelveSDetailSection(viewModel: viewModel.twelveSDetailSectionViewModel)

        case .provenance:
            ProvenanceSection(viewModel: viewModel.provenanceSectionViewModel)

        case .ai:
            EmptyView()
        }
    }
}

struct GenotypeAnnotationIdentitySection: View {
    let analystIdentity: String
    let openSettings: () -> Void

    var savingAsText: String {
        "Saving as: \(analystIdentity)"
    }

    func openSettingsPane() {
        openSettings()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(savingAsText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(InspectorAccessibilityID.analystIdentityLabel)
            Spacer(minLength: 0)
            Button("Settings", action: openSettingsPane)
                .controlSize(.small)
                .accessibilityIdentifier(InspectorAccessibilityID.analystIdentitySettingsButton)
        }
    }
}

// MARK: - InspectorTab Helpers

private struct InspectorTabGrid: View {
    let tabs: [InspectorTab]
    @Binding var selectedTab: InspectorTab

    var body: some View {
        LungfishInspectorSegmentedButtonGrid(
            options: tabs,
            selection: $selectedTab,
            accessibilityLabel: "Inspector",
            label: \.displayLabel
        )
    }
}

extension InspectorTab {
    /// SF Symbol name for this tab's picker icon.
    var iconName: String {
        switch self {
        case .bundle: return "shippingbox"
        case .selectedItem: return "scope"
        case .annotations: return "text.bubble"
        case .view: return "eye"
        case .analysis: return "arrow.triangle.branch"
        case .ai: return "sparkles"
        case .fastqMetadata: return "tag"
        case .resultSummary: return "chart.bar"
        case .twelveSDetail: return "list.bullet.rectangle"
        case .provenance: return "point.3.connected.trianglepath.dotted"
        }
    }

    /// Human-readable label for single-tab headers.
    var displayLabel: String {
        switch self {
        case .bundle: return "Bundle"
        case .selectedItem: return "Selected Item"
        case .annotations: return "Annotations"
        case .view: return "View"
        case .analysis: return "Analysis"
        case .ai: return "Assistant"
        case .fastqMetadata: return "Sample Metadata"
        case .resultSummary: return "Summary"
        case .twelveSDetail: return "Detail"
        case .provenance: return "Provenance"
        }
    }
}

private struct InspectorReadStyleSection: View {
    @Bindable var viewModel: InspectorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("View Settings")
                .font(LungfishInspectorStyle.sectionTitleFont)

            if viewModel.contentMode == .genotype {
                GenotypeResultDisplaySection(viewModel: viewModel.genotypeResultDisplaySectionViewModel)
            } else {
                if viewModel.contentMode == .mapping {
                    MappingViewSettingsSection(viewModel: viewModel.documentSectionViewModel)
                    Divider()
                }

                InspectorSubsectionGrid(selection: $viewModel.selectedReadStyleViewSubsection)

                subsectionContent
            }
        }
    }

    @ViewBuilder
    private var subsectionContent: some View {
        switch viewModel.selectedReadStyleViewSubsection {
        case .alignment:
            AlignmentViewSection(viewModel: viewModel.readStyleSectionViewModel)
        case .annotations:
            InspectorAnnotationDisplaySection(viewModel: viewModel)
        case .reads:
            ReadStyleSection(viewModel: viewModel.readStyleSectionViewModel)
        }
    }
}

private struct InspectorSubsectionGrid: View {
    @Binding var selection: ReadStyleViewSubsection

    var body: some View {
        LungfishInspectorSegmentedButtonGrid(
            options: ReadStyleViewSubsection.allCases,
            selection: $selection,
            accessibilityLabel: "View Section",
            label: \.displayTitle
        )
    }
}

private struct InspectorAnalysisWorkflowSection: View {
    @Bindable var viewModel: InspectorViewModel

    var body: some View {
        AnalysisSection(viewModel: viewModel.readStyleSectionViewModel)
    }
}

private struct InspectorAnnotationDisplaySection: View {
    @Bindable var viewModel: InspectorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sequence, annotation, and sample display controls are grouped here so the main View tab stays easier to scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AppearanceSection(viewModel: viewModel.appearanceSectionViewModel)

            Divider()

            AnnotationSection(viewModel: viewModel.annotationSectionViewModel)

            if viewModel.sampleSectionViewModel.hasVariantData {
                Divider()
                SampleSection(viewModel: viewModel.sampleSectionViewModel)
            }
        }
    }
}

private struct InspectorAlignmentVisibilitySection: View {
    @Bindable var readStyleViewModel: ReadStyleSectionViewModel
    @Bindable var documentViewModel: DocumentSectionViewModel
    let contentMode: ViewportContentMode

    private let allAlignmentsSelectionID = "__all_alignments__"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if contentMode == .mapping {
                MappingViewSettingsSection(viewModel: documentViewModel)
                Divider()
            }

            if readStyleViewModel.hasAlignmentTracks {
                Text("Choose whether the viewer shows every alignment track together or just one alignment track at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Visible Alignment", selection: visibleAlignmentSelection) {
                    Text("All Alignments").tag(allAlignmentsSelectionID)
                    ForEach(readStyleViewModel.visibleAlignmentTrackOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .disabled(readStyleViewModel.visibleAlignmentTrackOptions.isEmpty)

                Text(visibleAlignmentSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Show reads", isOn: $readStyleViewModel.showReads)
                    .onChange(of: readStyleViewModel.showReads) { _, _ in
                        readStyleViewModel.onSettingsChanged?()
                    }

                HStack {
                    Text("Minimum MAPQ")
                    Spacer()
                    Text("\(Int(readStyleViewModel.minMapQ))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $readStyleViewModel.minMapQ, in: 0...60, step: 1)
                    .onChange(of: readStyleViewModel.minMapQ) { _, _ in
                        readStyleViewModel.onSettingsChanged?()
                    }

                Text("Read Inclusion")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Include duplicate-marked reads", isOn: $readStyleViewModel.showDuplicates)
                    .onChange(of: readStyleViewModel.showDuplicates) { _, _ in
                        readStyleViewModel.onSettingsChanged?()
                    }

                Toggle("Include secondary alignments", isOn: $readStyleViewModel.showSecondary)
                    .onChange(of: readStyleViewModel.showSecondary) { _, _ in
                        readStyleViewModel.onSettingsChanged?()
                    }

                Toggle("Include supplementary alignments", isOn: $readStyleViewModel.showSupplementary)
                    .onChange(of: readStyleViewModel.showSupplementary) { _, _ in
                        readStyleViewModel.onSettingsChanged?()
                    }

                if readStyleViewModel.readGroups.count > 1 {
                    Divider()
                    readGroupControls
                }
            } else {
                Text("No alignment tracks loaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Import a BAM or CRAM file via File > Import Center to enable alignment-specific view controls.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var visibleAlignmentSelection: Binding<String> {
        Binding(
            get: { readStyleViewModel.selectedVisibleAlignmentTrackID ?? allAlignmentsSelectionID },
            set: { newValue in
                readStyleViewModel.selectedVisibleAlignmentTrackID = newValue == allAlignmentsSelectionID ? nil : newValue
                documentViewModel.visibleAlignmentTrackID = readStyleViewModel.selectedVisibleAlignmentTrackID
                readStyleViewModel.onSettingsChanged?()
            }
        )
    }

    private var visibleAlignmentSummary: String {
        guard let selectedVisibleAlignmentTrackID = readStyleViewModel.selectedVisibleAlignmentTrackID else {
            return "Showing reads from every alignment track in this bundle."
        }

        let trackName = readStyleViewModel.visibleAlignmentTrackOptions
            .first(where: { $0.id == selectedVisibleAlignmentTrackID })?.name ?? selectedVisibleAlignmentTrackID
        return "Showing only \(trackName). Choose All Alignments to return to the aggregate view."
    }

    @ViewBuilder
    private var readGroupControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Read Groups")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(readStyleViewModel.readGroups) { rg in
                Toggle(isOn: Binding(
                    get: {
                        readStyleViewModel.selectedReadGroups.isEmpty || readStyleViewModel.selectedReadGroups.contains(rg.rgId)
                    },
                    set: { isOn in
                        if readStyleViewModel.selectedReadGroups.isEmpty {
                            var all = Set(readStyleViewModel.readGroups.map(\.rgId))
                            if !isOn { all.remove(rg.rgId) }
                            readStyleViewModel.selectedReadGroups = all
                        } else if isOn {
                            readStyleViewModel.selectedReadGroups.insert(rg.rgId)
                            if readStyleViewModel.selectedReadGroups.count == readStyleViewModel.readGroups.count {
                                readStyleViewModel.selectedReadGroups = []
                            }
                        } else {
                            readStyleViewModel.selectedReadGroups.remove(rg.rgId)
                        }
                        readStyleViewModel.onSettingsChanged?()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(rg.rgId)
                            .font(.system(.caption, design: .monospaced))
                        if let sample = rg.sample {
                            Text(sample)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct InspectorReadRenderingSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel

    var body: some View {
        if viewModel.hasAlignmentTracks {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Maximum rows")
                    Spacer()
                    Text("\(Int(viewModel.maxReadRows))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .opacity(viewModel.limitReadRows ? 1.0 : 0.5)

                Slider(value: $viewModel.maxReadRows, in: 10...2000, step: 10)
                    .disabled(!viewModel.limitReadRows)
                    .onChange(of: viewModel.maxReadRows) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Toggle("Limit visible rows", isOn: $viewModel.limitReadRows)
                    .onChange(of: viewModel.limitReadRows) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("Off keeps all mapped reads in the active view and enables stable vertical scrolling.")

                Toggle("Use compact row height", isOn: $viewModel.verticallyCompressContig)
                    .onChange(of: viewModel.verticallyCompressContig) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("Compact mode uses smaller row heights to fit more reads on screen.")

                Divider()

                Toggle(viewModel.matchDotsToggleLabel, isOn: $viewModel.showMismatches)
                    .onChange(of: viewModel.showMismatches) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("When on, matching bases are shown as dots and mismatches as colored letters. When off, all bases are shown as letters. Mismatches remain highlighted. At high zoom (≥4 px/base), letters show automatically for legibility even when dots are on.")

                Toggle("Show soft-clipped sequence", isOn: $viewModel.showSoftClips)
                    .onChange(of: viewModel.showSoftClips) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Toggle("Show insertion and deletion markers", isOn: $viewModel.showIndels)
                    .onChange(of: viewModel.showIndels) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Divider()

                Toggle("Color reads by strand", isOn: $viewModel.showStrandColors)
                    .onChange(of: viewModel.showStrandColors) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("When on, forward reads are blue-tinted and reverse reads are pink-tinted. When off, all reads have a neutral gray background.")

                Divider()

                HStack {
                    Text("Forward strand color")
                    Spacer()
                    ColorPicker("", selection: $viewModel.forwardReadColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: viewModel.forwardReadColor) { _, _ in
                            viewModel.onSettingsChanged?()
                        }
                }

                HStack {
                    Text("Reverse strand color")
                    Spacer()
                    ColorPicker("", selection: $viewModel.reverseReadColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: viewModel.reverseReadColor) { _, _ in
                            viewModel.onSettingsChanged?()
                        }
                }
            }
        } else {
            Text("No alignment tracks loaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct InspectorFilteringWorkflowSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel
    @State private var alignmentFilterValidationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Creates a new alignment in this bundle. The original alignment stays unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let latestDerivedAlignmentMessage = viewModel.latestDerivedAlignmentMessage,
               !latestDerivedAlignmentMessage.isEmpty {
                Text(latestDerivedAlignmentMessage)
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }

            if viewModel.hasAlignmentTracks {
                Text("Duplicate handling")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Mark Duplicates in Bundle Tracks") {
                    viewModel.onMarkDuplicatesRequested?()
                }
                .disabled(viewModel.isDuplicateWorkflowRunning)

                if viewModel.isDuplicateWorkflowRunning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Running duplicate workflow...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Picker(
                    "Starting Alignment",
                    selection: Binding(
                        get: { viewModel.selectedAlignmentFilterSourceTrackID ?? "" },
                        set: { newValue in
                            alignmentFilterValidationMessage = nil
                            viewModel.selectedAlignmentFilterSourceTrackID = newValue.isEmpty ? nil : newValue
                        }
                    )
                ) {
                    if viewModel.alignmentFilterTrackOptions.isEmpty {
                        Text("No alignment tracks").tag("")
                    } else {
                        ForEach(viewModel.alignmentFilterTrackOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                }
                .disabled(viewModel.alignmentFilterTrackOptions.isEmpty)

                Toggle("Keep mapped reads only", isOn: Binding(
                    get: { viewModel.alignmentFilterMappedOnly },
                    set: { newValue in
                        alignmentFilterValidationMessage = nil
                        viewModel.alignmentFilterMappedOnly = newValue
                    }
                ))

                Toggle("Keep one primary alignment per read", isOn: Binding(
                    get: { viewModel.alignmentFilterPrimaryOnly },
                    set: { newValue in
                        alignmentFilterValidationMessage = nil
                        viewModel.alignmentFilterPrimaryOnly = newValue
                    }
                ))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Minimum alignment confidence")
                        Spacer()
                        Text("MAPQ \(viewModel.alignmentFilterMinimumMAPQ)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 56, alignment: .trailing)
                        Stepper(
                            "",
                            value: Binding(
                                get: { viewModel.alignmentFilterMinimumMAPQ },
                                set: { newValue in
                                    alignmentFilterValidationMessage = nil
                                    viewModel.alignmentFilterMinimumMAPQ = newValue
                                }
                            ),
                            in: 0...255
                        )
                        .labelsHidden()
                    }
                    Text("Uses SAM MAPQ. Set to 0 to keep every alignment confidence level.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Picker("Duplicate handling", selection: Binding(
                    get: { viewModel.alignmentFilterDuplicateMode },
                    set: { newValue in
                        alignmentFilterValidationMessage = nil
                        viewModel.alignmentFilterDuplicateMode = newValue
                    }
                )) {
                    ForEach(AlignmentFilterInspectorDuplicateChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }

                Toggle("Keep reads with zero mismatches to reference", isOn: Binding(
                    get: { viewModel.alignmentFilterExactMatchOnly },
                    set: { newValue in
                        alignmentFilterValidationMessage = nil
                        viewModel.alignmentFilterExactMatchOnly = newValue
                    }
                ))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Minimum identity to reference (%)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        viewModel.alignmentFilterExactMatchOnly ? "Disabled while exact-match filtering is on" : "Leave blank to keep all",
                        text: Binding(
                            get: { viewModel.alignmentFilterMinimumPercentIdentityText },
                            set: { newValue in
                                alignmentFilterValidationMessage = nil
                                viewModel.alignmentFilterMinimumPercentIdentityText = newValue
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.alignmentFilterExactMatchOnly)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Name for New Alignment")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "Filtered alignment name",
                        text: Binding(
                            get: { viewModel.alignmentFilterOutputTrackName },
                            set: { newValue in
                                alignmentFilterValidationMessage = nil
                                viewModel.alignmentFilterOutputTrackName = newValue
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }

                Button("Create Filtered Alignment") {
                    do {
                        let request = try viewModel.makeAlignmentFilterLaunchRequest()
                        alignmentFilterValidationMessage = nil
                        viewModel.onCreateFilteredAlignmentRequested?(request)
                    } catch {
                        alignmentFilterValidationMessage = error.localizedDescription
                    }
                }
                .disabled(viewModel.isAlignmentFilterWorkflowRunning)

                if viewModel.isAlignmentFilterWorkflowRunning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Running BAM filter workflow...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let alignmentFilterValidationMessage, !alignmentFilterValidationMessage.isEmpty {
                    Text(alignmentFilterValidationMessage)
                        .font(.caption2)
                        .foregroundStyle(Color.lungfishDangerFallback)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No alignment tracks loaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Import a BAM or CRAM file before creating a filtered alignment.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct InspectorConsensusWorkflowSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel

    var body: some View {
        if viewModel.hasAlignmentTracks {
            VStack(alignment: .leading, spacing: 8) {
                Text("Consensus controls live under Analysis so the View tab stays focused on reversible display settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Show consensus track in viewer", isOn: $viewModel.showConsensusTrack)
                    .onChange(of: viewModel.showConsensusTrack) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Picker("Consensus Mode", selection: $viewModel.consensusMode) {
                    Text("Bayesian").tag(AlignmentConsensusMode.bayesian)
                    Text("Simple").tag(AlignmentConsensusMode.simple)
                }
                .pickerStyle(.segmented)
                .onChange(of: viewModel.consensusMode) { _, _ in
                    viewModel.onSettingsChanged?()
                }

                Toggle("Use IUPAC ambiguity codes", isOn: $viewModel.consensusUseAmbiguity)
                    .onChange(of: viewModel.consensusUseAmbiguity) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Toggle("Hide high-gap sites", isOn: $viewModel.consensusMaskingEnabled)
                    .onChange(of: viewModel.consensusMaskingEnabled) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("When enabled, columns where most spanning reads are gaps are masked in packed or base views.")

                HStack {
                    Text("Consensus minimum depth")
                    Spacer()
                    Text("\(Int(viewModel.consensusMinDepth))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.consensusMinDepth, in: 1...50, step: 1)
                    .onChange(of: viewModel.consensusMinDepth) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                if viewModel.consensusMaskingEnabled {
                    HStack {
                        Text("Gap threshold")
                        Spacer()
                        Text("\(Int(viewModel.consensusGapThresholdPercent))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $viewModel.consensusGapThresholdPercent, in: 50...99, step: 1)
                        .onChange(of: viewModel.consensusGapThresholdPercent) { _, _ in
                            viewModel.onSettingsChanged?()
                        }

                    HStack {
                        Text("Masking minimum depth")
                        Spacer()
                        Text("\(Int(viewModel.consensusMaskingMinDepth))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $viewModel.consensusMaskingMinDepth, in: 1...50, step: 1)
                        .onChange(of: viewModel.consensusMaskingMinDepth) { _, _ in
                            viewModel.onSettingsChanged?()
                        }
                }

                HStack {
                    Text("Consensus minimum MAPQ")
                    Spacer()
                    Text("\(Int(viewModel.consensusMinMapQ))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.consensusMinMapQ, in: 0...60, step: 1)
                    .onChange(of: viewModel.consensusMinMapQ) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                HStack {
                    Text("Consensus minimum base quality")
                    Spacer()
                    Text("\(Int(viewModel.consensusMinBaseQ))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.consensusMinBaseQ, in: 0...60, step: 1)
                    .onChange(of: viewModel.consensusMinBaseQ) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Divider()

                Button("Extract Consensus…") {
                    viewModel.onExtractConsensusRequested?()
                }
                .disabled(!viewModel.supportsConsensusExtraction)

                if !viewModel.supportsConsensusExtraction {
                    Text("Consensus extraction is available from the active mapping viewer.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("No alignment tracks loaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct InspectorVariantCallingWorkflowSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel

    var body: some View {
        if viewModel.hasAlignmentTracks {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run BAM-backed variant calling from the current bundle.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if viewModel.hasVariantCallableAlignmentTracks {
                    Text("Use this when you want site-by-site sequence differences summarized as a reusable variant track.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Variant calling is unavailable until this bundle includes an indexed BAM alignment track.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Call Variants…") {
                    viewModel.onCallVariantsRequested?()
                }
                .disabled(!viewModel.hasVariantCallableAlignmentTracks)
            }
        } else {
            Text("No alignment tracks loaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Import a BAM or CRAM file before running variant-calling workflows.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct InspectorExportWorkflowSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel

    var body: some View {
        if viewModel.hasAlignmentTracks {
            VStack(alignment: .leading, spacing: 8) {
                Text("Create a separate bundle-level output from the current alignment tracks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text("Use export when you want a new bundle for downstream work without changing the original mapping bundle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Create Deduplicated Bundle") {
                    viewModel.onCreateDeduplicatedBundleRequested?()
                }
                .disabled(viewModel.isDuplicateWorkflowRunning)

                if viewModel.isDuplicateWorkflowRunning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Running duplicate workflow...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text("No alignment tracks loaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Import a BAM or CRAM file before exporting a deduplicated bundle.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct MappingViewSettingsSection: View {
    @Bindable var viewModel: DocumentSectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mapping Layout")
                .font(LungfishInspectorStyle.sectionTitleFont)

            Text("Choose how the contig list and genome detail panes share the mapping viewer.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Layout", selection: Binding(
                get: { viewModel.mappingPanelLayout },
                set: { newValue in
                    viewModel.mappingPanelLayout = newValue
                    newValue.persist()
                }
            )) {
                Text("Detail left, list right").tag(MappingPanelLayout.detailLeading)
                Text("List left, detail right").tag(MappingPanelLayout.listLeading)
                Text("List above detail").tag(MappingPanelLayout.stacked)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Divider()

            bundleScrollDirectionPicker
        }
    }

    private var bundleScrollDirectionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bundle Scroll Direction")
                .font(LungfishInspectorStyle.sectionTitleFont)

            Picker("Horizontal Scroll", selection: Binding(
                get: { viewModel.bundleHorizontalScrollDirection },
                set: { newValue in
                    viewModel.bundleHorizontalScrollDirection = newValue
                    ReferenceBundleScrollDirectionPreference.persist(newValue)
                }
            )) {
                ForEach(ScrollDirectionPreference.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}

// MARK: - MetagenomicsResultSummarySection

/// A minimal inspector section for metagenomics result views.
///
/// Shows pipeline/run information when a TaxTriage, EsViritu, or Kraken2
/// result is displayed. Re-uses DocumentSectionViewModel data when available,
/// otherwise shows a "No result information" placeholder.
private struct MetagenomicsResultSummarySection: View {
    @Bindable var viewModel: DocumentSectionViewModel
    @Bindable var twelveSViewModel: TwelveSResultDisplaySectionViewModel
    let windowStateScope: WindowStateScope?
    @State private var isSamplesExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if twelveSViewModel.isAvailable {
                TwelveSResultDisplaySection(viewModel: twelveSViewModel)
                Divider()
                    .padding(.vertical, 4)
                twelveSSamplesMetadataSection
            } else {
            if let manifest = viewModel.manifest {
                metadataRow("Organism", value: manifest.source.organism)
                metadataRow("Assembly", value: manifest.source.assembly)
            }

            if let naoManifest = viewModel.naoMgsManifest {
                naoMgsSection(naoManifest)
            }

            if let nvdManifest = viewModel.nvdManifest {
                nvdSection(nvdManifest)
            }

            if viewModel.hasAnyContent {
                Text("See the viewer for detailed results. Use the bottom drawer for BLAST verification and sample navigation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a metagenomics result in the sidebar to view its summary here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Panel Layout")
                    .font(.caption.weight(.semibold))

                Picker("Layout", selection: Binding(
                    get: { viewModel.metagenomicsPanelLayout },
                    set: { newValue in
                        viewModel.metagenomicsPanelLayout = newValue
                        newValue.persist()
                    }
                )) {
                    Label("Detail | List", systemImage: "sidebar.left")
                        .tag(MetagenomicsPanelLayout.detailLeading)
                    Label("List | Detail", systemImage: "sidebar.right")
                        .tag(MetagenomicsPanelLayout.listLeading)
                    Label("List Over Detail", systemImage: "rectangle.split.1x2")
                        .tag(MetagenomicsPanelLayout.stacked)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            if let tool = viewModel.batchOperationTool {
                BatchOperationDetailsSection(
                    tool: tool,
                    parameters: viewModel.batchOperationParameters,
                    timestamp: viewModel.batchOperationTimestamp,
                    manifestStatus: viewModel.batchManifestStatus
                )
                Divider()
                    .padding(.vertical, 4)
            }

            Divider()
                .padding(.vertical, 4)

            DisclosureGroup("Samples & Metadata", isExpanded: $isSamplesExpanded) {
                if let pickerState = viewModel.classifierPickerState,
                   !viewModel.classifierSampleEntries.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sample Filter")
                            .font(.caption.weight(.semibold))

                        ClassifierSamplePickerView(
                            samples: viewModel.classifierSampleEntries,
                            pickerState: pickerState,
                            strippedPrefix: viewModel.classifierStrippedPrefix,
                            isInline: true
                        )
                    }
                    .onChange(of: pickerState.selectedSamples) { _, _ in
                        NotificationCenter.default.post(
                            name: .metagenomicsSampleSelectionChanged,
                            object: nil,
                            userInfo: windowScopedUserInfo()
                        )
                    }
                }

                // Import Metadata button (when no metadata loaded yet)
                if viewModel.sampleMetadataStore == nil {
                    Divider().padding(.vertical, 4)
                    Button("Import Metadata\u{2026}") {
                        NotificationCenter.default.post(
                            name: .metagenomicsMetadataImportRequested,
                            object: nil,
                            userInfo: windowScopedUserInfo()
                        )
                    }
                    .controlSize(.small)
                }

                // Sample Metadata section
                if let metadataStore = viewModel.sampleMetadataStore {
                    Divider().padding(.vertical, 4)
                    SampleMetadataSection(store: metadataStore)
                }

                // Attachments section
                if let attachmentStore = viewModel.bundleAttachmentStore {
                    Divider().padding(.vertical, 4)
                    AttachmentsSection(store: attachmentStore)
                }
            }
            .font(.caption.weight(.semibold))

            if !viewModel.batchSourceSampleURLs.isEmpty {
                Divider()
                    .padding(.vertical, 4)
                SourceSamplesSection(
                    samples: viewModel.batchSourceSampleURLs,
                    onNavigateToBundle: { url in
                        NotificationCenter.default.post(
                            name: .navigateToSidebarItem,
                            object: nil,
                            userInfo: windowScopedUserInfo(["url": url])
                        )
                    }
                )
            }
            }
        }
    }

    func windowScopedUserInfo(_ userInfo: [AnyHashable: Any]? = nil) -> [AnyHashable: Any]? {
        guard let windowStateScope else { return userInfo }
        var scopedUserInfo = userInfo ?? [:]
        scopedUserInfo[NotificationUserInfoKey.windowStateScope] = windowStateScope
        return scopedUserInfo
    }

    private var twelveSSamplesMetadataSection: some View {
        DisclosureGroup("Samples & Metadata", isExpanded: $isSamplesExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                metadataRow("Samples", value: "\(twelveSViewModel.sampleCount)")
                metadataRow("Metadata", value: twelveSViewModel.sampleMetadataSourceSummary)
                if !twelveSViewModel.sampleMetadataSourceDetails.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sources")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(twelveSViewModel.sampleMetadataSourceDetails, id: \.self) { detail in
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                if !twelveSViewModel.sampleMetadataWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Warnings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(twelveSViewModel.sampleMetadataWarnings, id: \.self) { warning in
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                if let store = twelveSViewModel.sampleMetadataStore {
                    SampleMetadataSection(
                        store: store,
                        title: "Resolved Metadata",
                        isEditable: false
                    )
                } else {
                    Text("Sample IDs are frozen in this result. No FASTQ or analysis metadata fields were attached.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder
    private func naoMgsSection(_ manifest: NaoMgsManifest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NAO-MGS Result")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            metadataRow("Sample", value: manifest.sampleName)
            metadataRow("Virus Hits", value: "\(manifest.hitCount)")
            metadataRow("Unique Taxa", value: "\(manifest.taxonCount)")
            if let topTaxon = manifest.topTaxon {
                metadataRow("Top Taxon", value: topTaxon)
            }
            if let version = manifest.workflowVersion {
                metadataRow("Workflow", value: "NAO-MGS v\(version)")
            }
            metadataRow("Source", value: (manifest.sourceFilePath as NSString).lastPathComponent)
            metadataRow("Imported", value: {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                return formatter.string(from: manifest.importDate)
            }())
            if !manifest.fetchedAccessions.isEmpty {
                metadataRow("References", value: "\(manifest.fetchedAccessions.count) fetched")
            }
        }
    }

    @ViewBuilder
    private func nvdSection(_ manifest: NvdManifest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NVD Result")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            metadataRow("Experiment", value: manifest.experiment)
            metadataRow("Samples", value: "\(manifest.sampleCount)")
            metadataRow("Contigs", value: "\(manifest.contigCount)")
            metadataRow("BLAST Hits", value: "\(manifest.hitCount)")
            if let blastDbVersion = manifest.blastDbVersion {
                metadataRow("BLAST DB", value: blastDbVersion)
            }
            if let runId = manifest.snakemakeRunId {
                metadataRow("Run ID", value: runId)
            }
            metadataRow("Imported", value: {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                return formatter.string(from: manifest.importDate)
            }())
        }
    }

    @ViewBuilder
    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }
}

private struct EmbeddedAIAssistantView: NSViewControllerRepresentable {
    let service: AIAssistantService

    func makeNSViewController(context: Context) -> AIAssistantViewController {
        AIAssistantViewController(service: service)
    }

    func updateNSViewController(_ controller: AIAssistantViewController, context: Context) {
        _ = controller
    }
}

// MARK: - SidebarItemType Extension

extension SidebarItemType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .group: return "Group"
        case .folder: return "Folder"
        case .sequence: return "Sequence"
        case .annotation: return "Annotation"
        case .alignment: return "Alignment"
        case .coverage: return "Coverage"
        case .project: return "Project"
        case .document: return "Document"
        case .image: return "Image"
        case .unknown: return "File"
        case .referenceBundle: return "Reference Bundle"
        case .mhcReferenceBundle: return "MHC Reference Bundle"
        case .multipleSequenceAlignmentBundle: return "Multiple Sequence Alignment"
        case .phylogeneticTreeBundle: return "Phylogenetic Tree"
        case .fastqBundle: return "FASTQ Bundle"
        case .primerSchemeBundle: return "Primer Scheme"
        case .genotypeResultBundle: return "ONT Genotyping Result"
        case .twelveSAmpliconResultBundle: return "12S Amplicon Result"
        case .batchGroup: return "Batch Operation"
        case .classificationResult: return "Classification Result"
        case .esvirituResult: return "Viral Detection Result"
        case .taxTriageResult: return "Comprehensive Triage Result"
        case .naoMgsResult: return "NAO-MGS Surveillance Result"
        case .nvdResult: return "NVD Classification Result"
        case .czIdResult: return "CZ-ID Classification Result"
        case .analysisResult: return "Analysis Result"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct InspectorView_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel = InspectorViewModel()
        viewModel.selectedItem = "chr1.fa"
        viewModel.selectedType = "Sequence"

        // Set up sample annotation
        viewModel.selectionSectionViewModel.select(annotation: SequenceAnnotation(
            type: .gene,
            name: "BRCA1",
            start: 1000,
            end: 5000,
            strand: .forward,
            note: "Breast cancer susceptibility gene"
        ))

        // Set up sample quality data
        viewModel.qualitySectionViewModel.update(
            hasData: true,
            statistics: QualityStatistics(
                meanQuality: 32.5,
                q20Percentage: 95.2,
                q30Percentage: 87.8,
                totalBases: 1_234_567,
                minQuality: 2,
                maxQuality: 40
            )
        )

        // Set up sample document metadata
        viewModel.documentSectionViewModel.update(
            manifest: BundleManifest(
                name: "Human Reference Genome",
                identifier: "org.lungfish.hg38",
                source: SourceInfo(
                    organism: "Homo sapiens",
                    commonName: "Human",
                    taxonomyId: 9606,
                    assembly: "GRCh38",
                    assemblyAccession: "GCF_000001405.40",
                    database: "NCBI"
                ),
                genome: GenomeInfo(
                    path: "genome/sequence.fa.gz",
                    indexPath: "genome/sequence.fa.gz.fai",
                    totalLength: 3_088_286_401,
                    chromosomes: [
                        ChromosomeInfo(
                            name: "chr1",
                            length: 248_956_422,
                            offset: 0,
                            lineBases: 80,
                            lineWidth: 81
                        )
                    ]
                )
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/test.lungfishref")
        )

        return InspectorView(viewModel: viewModel)
            .frame(width: 280, height: 800)
    }
}
#endif
