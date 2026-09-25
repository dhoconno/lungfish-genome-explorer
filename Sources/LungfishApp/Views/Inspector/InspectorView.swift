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
    private let provenanceDetailsInitiallyExpanded: Bool

    init(
        viewModel: InspectorViewModel,
        provenanceDetailsInitiallyExpanded: Bool = false
    ) {
        self.viewModel = viewModel
        self.provenanceDetailsInitiallyExpanded = provenanceDetailsInitiallyExpanded
    }

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
        .font(LungfishInspectorStyle.controlFont)
        .controlSize(.regular)
    }

    // MARK: - Tab Picker

    @ViewBuilder
    private var tabPicker: some View {
        let tabs = viewModel.availableTabs
        if tabs.count > 1 {
            InspectorTabGrid(
                tabs: tabs,
                selectedTab: $viewModel.selectedTab,
                minimumLabelScale: viewModel.contentMode == .genotype ? 0.75 : 1
            )
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
        case .bundle, .selectedItem, .annotations, .view, .analysis, .fastqMetadata, .resultSummary, .twelveSDetail, .files, .provenance:
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
                        .font(LungfishInspectorStyle.sectionTitleFont)
                    Text("Enable AI services in Settings > AI Services to use the assistant.")
                        .font(LungfishInspectorStyle.controlFont)
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
            if let document = viewModel.primerAnalysisDocument {
                PrimerAnalysisInspectorBundleSection(document: document)
            } else {
                DocumentSection(viewModel: viewModel.documentSectionViewModel)
                if let record = viewModel.documentSectionViewModel.projectCopyRecord {
                    Divider().padding(.vertical, 4)
                    MissingSourcesSection(record: record)
                }
                if viewModel.readStyleSectionViewModel.hasAlignmentTracks {
                    Divider()
                    AlignmentBundleSection(viewModel: viewModel.readStyleSectionViewModel)
                }
                // Show FASTQ metadata in Document tab when in FASTQ mode
                if viewModel.contentMode == .fastq {
                    FASTQMetadataSection(viewModel: viewModel.fastqMetadataSectionViewModel)
                    FASTQPBAAArtifactsSection(viewModel: viewModel.fastqPBAAArtifactsSectionViewModel)
                }
            }

        case .selectedItem:
            if !viewModel.variantSectionViewModel.hasVariantSelection {
                SelectionSection(viewModel: viewModel.selectionSectionViewModel)
            }

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
            if viewModel.primerAnalysisDocument != nil,
               let session = viewModel.primerAnalysisDisplaySession, session.isAvailable {
                PrimerAnalysisDisplaySection(session: session)
            } else {
                InspectorReadStyleSection(viewModel: viewModel)
            }

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
            ProvenanceSection(
                viewModel: viewModel.provenanceSectionViewModel,
                usesGenotypePresentation: viewModel.contentMode == .genotype,
                detailsInitiallyExpanded: provenanceDetailsInitiallyExpanded
            )

        case .files:
            if let document = viewModel.primerAnalysisDocument {
                PrimerAnalysisInspectorFilesSection(document: document)
            }

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
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(InspectorAccessibilityID.analystIdentityLabel)
            Spacer(minLength: 0)
            Button("Settings", action: openSettingsPane)
                .controlSize(.regular)
                .accessibilityIdentifier(InspectorAccessibilityID.analystIdentitySettingsButton)
        }
    }
}

// MARK: - InspectorTab Helpers

private struct InspectorTabGrid: View {
    let tabs: [InspectorTab]
    @Binding var selectedTab: InspectorTab
    let minimumLabelScale: CGFloat

    var body: some View {
        LungfishInspectorSegmentedButtonGrid(
            options: tabs,
            selection: $selectedTab,
            accessibilityLabel: "Inspector",
            label: \.displayLabel,
            minimumLabelScale: minimumLabelScale
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
        case .files: return "doc.on.doc"
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
        case .files: return "Files"
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

            if let capabilities = viewModel.readStyleSectionViewModel.classifierEvidenceCapabilities {
                ClassifierEvidenceInventorySection(capabilities: capabilities)
                Divider()
            }
        }
    }

    @ViewBuilder
    private var subsectionContent: some View {
        switch viewModel.selectedReadStyleViewSubsection {
        case .alignment:
            AlignmentViewSection(viewModel: viewModel.readStyleSectionViewModel)
        case .annotations:
            if let capabilities = viewModel.readStyleSectionViewModel.classifierEvidenceCapabilities {
                Text(capabilities.availability(of: .annotationAppearance).reason)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            } else {
                InspectorAnnotationDisplaySection(viewModel: viewModel)
            }
        case .reads:
            ReadStyleSection(viewModel: viewModel.readStyleSectionViewModel)
        }
    }
}

private struct ClassifierEvidenceInventorySection: View {
    let capabilities: ClassifierAlignmentInspectorCapabilities
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Classifier alignment evidence").font(LungfishInspectorStyle.sectionTitleFont)
            ForEach(capabilities.inventoryRows, id: \.self) { Text($0).textSelection(.enabled) }
            ForEach(capabilities.unavailableReasons, id: \.self) { Text($0).font(LungfishInspectorStyle.controlFont).foregroundStyle(.secondary) }
        }
        .accessibilityIdentifier("classifier-evidence-inventory")
    }
}

private extension ClassifierAlignmentInspectorCapabilities.Availability {
    var reason: String {
        switch self {
        case .available: "Available"
        case .disabled(let reason), .hidden(let reason): reason
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
                .font(LungfishInspectorStyle.controlFont)
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


private struct MappingViewSettingsSection: View {
    @Bindable var viewModel: DocumentSectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mapping Layout")
                .font(LungfishInspectorStyle.sectionTitleFont)

            Text("Choose how the contig list and genome detail panes share the mapping viewer.")
                .font(LungfishInspectorStyle.controlFont)
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
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a metagenomics result in the sidebar to view its summary here.")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Panel Layout")
                    .font(LungfishInspectorStyle.controlFont.weight(.semibold))

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
                            .font(LungfishInspectorStyle.controlFont.weight(.semibold))

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
                    .controlSize(.regular)
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
            .font(LungfishInspectorStyle.controlFont.weight(.semibold))

            if let record = viewModel.projectCopyRecord {
                Divider()
                    .padding(.vertical, 4)
                MissingSourcesSection(record: record)
            }

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
                            .font(LungfishInspectorStyle.controlFont)
                            .foregroundStyle(.secondary)
                        ForEach(twelveSViewModel.sampleMetadataSourceDetails, id: \.self) { detail in
                            Text(detail)
                                .font(LungfishInspectorStyle.controlFont)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                if !twelveSViewModel.sampleMetadataWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Warnings")
                            .font(LungfishInspectorStyle.controlFont)
                            .foregroundStyle(.secondary)
                        ForEach(twelveSViewModel.sampleMetadataWarnings, id: \.self) { warning in
                            Text(warning)
                                .font(LungfishInspectorStyle.controlFont)
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
                        .font(LungfishInspectorStyle.controlFont)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    @ViewBuilder
    private func naoMgsSection(_ manifest: NaoMgsManifest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NAO-MGS Result")
                .font(LungfishInspectorStyle.controlFont.weight(.semibold))
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
                .font(LungfishInspectorStyle.controlFont.weight(.semibold))
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
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(LungfishInspectorStyle.controlFont)
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
        case .primerAnalysisBundle: return "Primer Analysis"
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
