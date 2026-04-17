// UnifiedMetagenomicsWizard.swift - Unified entry point for all metagenomics analyses
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishWorkflow

// MARK: - UnifiedMetagenomicsWizard

/// A unified SwiftUI shell for all metagenomics analysis workflows in Lungfish.
///
/// ## Analysis Types
///
/// | Type               | Tool         | Description                           | Speed  |
/// |--------------------|-------------|---------------------------------------|--------|
/// | Taxonomic          | Kraken2     | Broad taxonomic classification        | Fast   |
/// | Viral Detection    | EsViritu    | Virus-specific detection + coverage   | Medium |
/// | Clinical Triage    | TaxTriage   | End-to-end with confidence scoring    | Slow   |
///
/// ## Presentation
///
/// Hosted in an `NSPanel` via `NSHostingController` and presented with
/// `beginSheetModal` (per macOS 26 rules -- never `runModal()`).
struct UnifiedMetagenomicsWizard: View {

    /// The input FASTQ files to analyze.
    let inputFiles: [URL]
    let initialSelection: AnalysisType

    /// Stable shared section identifiers for the unified runner shell.
    private enum SharedSection: CaseIterable {
        case overview
        case prerequisites
        case samples
        case database
        case toolSettings
        case advancedSettings

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .prerequisites: return "Prerequisites"
            case .samples: return "Samples"
            case .database: return "Database"
            case .toolSettings: return "Tool Settings"
            case .advancedSettings: return "Advanced Settings"
            }
        }
    }

    /// Section order shared by the unified runner shell.
    static let sharedSectionOrder = SharedSection.allCases.map(\.title)

    // MARK: - State

    @State private var sidebarSelection: AnalysisType

    // Tool availability (checked asynchronously)
    @State private var kraken2Available: Bool? = nil
    @State private var esvirituAvailable: Bool? = nil
    @State private var nextflowAvailable: Bool? = nil
    @State private var containerAvailable: Bool? = nil

    // MARK: - Callbacks

    /// Called when the user configures and launches a Kraken2 classification.
    var onRunClassification: (([ClassificationConfig]) -> Void)?

    /// Called when the user configures and launches an EsViritu run.
    var onRunEsViritu: (([EsVirituConfig]) -> Void)?

    /// Called when the user configures and launches a TaxTriage run.
    var onRunTaxTriage: ((TaxTriageConfig) -> Void)?

    /// Called when the user cancels.
    var onCancel: (() -> Void)?

    init(
        inputFiles: [URL],
        initialSelection: AnalysisType = .classification,
        onRunClassification: (([ClassificationConfig]) -> Void)? = nil,
        onRunEsViritu: (([EsVirituConfig]) -> Void)? = nil,
        onRunTaxTriage: ((TaxTriageConfig) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.inputFiles = inputFiles
        self.initialSelection = initialSelection
        self.onRunClassification = onRunClassification
        self.onRunEsViritu = onRunEsViritu
        self.onRunTaxTriage = onRunTaxTriage
        self.onCancel = onCancel
        _sidebarSelection = State(initialValue: initialSelection)
    }

    #if DEBUG
    var testingSidebarSelection: AnalysisType { sidebarSelection }
    var testingInitialSelection: AnalysisType { initialSelection }
    #endif

    // MARK: - Enums

    /// The available metagenomics analysis types.
    enum AnalysisType: CaseIterable, Identifiable {
        case classification
        case viralDetection
        case clinicalTriage

        var id: Self { self }

        var sidebarTitle: String {
            switch self {
            case .classification: return "Kraken2"
            case .viralDetection: return "EsViritu"
            case .clinicalTriage: return "TaxTriage"
            }
        }

        var runnerTitle: String { sidebarTitle }

        /// SF Symbol name for the analysis type card.
        var symbolName: String {
            switch self {
            case .classification: return "k.circle"
            case .viralDetection: return "e.circle"
            case .clinicalTriage: return "t.circle"
            }
        }

        /// The underlying tool name.
        var toolName: String {
            switch self {
            case .classification: return "Classify & Profile (Kraken2)"
            case .viralDetection: return "Detect Viruses (EsViritu)"
            case .clinicalTriage: return "Detect Pathogens (TaxTriage)"
            }
        }

        /// Brief description of what this analysis does.
        var analysisDescription: String {
            switch self {
            case .classification:
                return "Fast k-mer classification of sequencing reads. Assigns each read to a taxon and estimates community abundance using Kraken2 and Bracken. Fast and can classify many types of sequences but prone to false positives."
            case .viralDetection:
                return "Virus-focused read mapping pipeline. Detects and quantifies viral pathogens with per-genome coverage metrics, consensus sequences, and iterative alignment."
            case .clinicalTriage:
                return "End-to-end metagenomic classification with alignment validation and TASS confidence scoring. Supports multiple classifiers, host removal, and PDF reporting. Can classify many types of sequences but prone to false negatives."
            }
        }

        /// All analysis types are configurable — tool availability is checked
        /// separately and shown as badges on each card.
        var isConfigurable: Bool { true }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            HStack {
                Text("Classify Reads")
                    .font(.headline)
                Spacer()
                if inputFiles.count == 1 {
                    Text(inputFiles.first?.lastPathComponent ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("\(inputFiles.count) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            runnerSidebar
        }
        .frame(width: 560, height: 520)
        .onAppear {
            checkToolAvailability()
        }
    }

    // MARK: - Runner Sidebar

    private var runnerSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Self.SharedSection.allCases, id: \.self) { section in
                        Text(section.title)
                            .font(.system(size: 12, weight: .semibold))
                    }

                    Picker("Analysis Type", selection: $sidebarSelection) {
                        ForEach(AnalysisType.allCases) { type in
                            Text(type.sidebarTitle).tag(type)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    /// A single analysis type selection card.
    private func analysisTypeCard(_ type: AnalysisType) -> some View {
        Button {
            sidebarSelection = type
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: type.symbolName)
                    .font(.system(size: 24))
                    .foregroundStyle(sidebarSelection == type ? .white : Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(sidebarSelection == type ? Color.accentColor : Color.accentColor.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(type.sidebarTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        toolAvailabilityBadge(for: type)
                    }

                    Text(type.toolName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(type.analysisDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(sidebarSelection == type
                          ? Color.accentColor.opacity(0.08)
                          : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        sidebarSelection == type ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: sidebarSelection == type ? 2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(type.sidebarTitle)
        .accessibilityHint(type.analysisDescription)
    }

    /// Shows availability status for a tool type.
    @ViewBuilder
    private func toolAvailabilityBadge(for type: AnalysisType) -> some View {
        switch type {
        case .classification:
            availabilityIndicator(available: kraken2Available)

        case .viralDetection:
            availabilityIndicator(available: esvirituAvailable)

        case .clinicalTriage:
            if let nf = nextflowAvailable, let ct = containerAvailable {
                availabilityIndicator(available: nf && ct ? true : false)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private func availabilityIndicator(available: Bool?) -> some View {
        if let available {
            if available {
                HStack(spacing: 2) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Ready")
                        .foregroundStyle(.green)
                }
                .font(.system(size: 10, weight: .medium))
            } else {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Text("Install in Plugin Manager")
                        .foregroundStyle(.orange)
                }
                .font(.system(size: 10, weight: .medium))
            }
        } else {
            ProgressView()
                .controlSize(.mini)
        }
    }

    // MARK: - Step 2: Configuration

    @ViewBuilder
    private var configurationStep: some View {
        switch sidebarSelection {
        case .classification:
            ClassificationWizardSheet(
                inputFiles: inputFiles,
                onRun: { configs in
                    onRunClassification?(configs)
                },
                onCancel: { onCancel?() }
            )

        case .viralDetection:
            EsVirituWizardSheet(
                inputFiles: inputFiles,
                onRun: { configs in
                    onRunEsViritu?(configs)
                },
                onCancel: { onCancel?() }
            )

        case .clinicalTriage:
            TaxTriageWizardSheet(
                initialFiles: inputFiles,
                onRun: { config in
                    onRunTaxTriage?(config)
                },
                onCancel: { onCancel?() }
            )
        }
    }

    // MARK: - Tool Availability Checks

    private func checkToolAvailability() {
        Task { @MainActor in
            // Check Kraken2 via conda
            let condaMgr = CondaManager.shared
            let kraken2Installed = await condaMgr.isToolInstalled("kraken2")
            kraken2Available = kraken2Installed

            // Check EsViritu via conda
            let esvirituInstalled = await condaMgr.isToolInstalled("EsViritu")
            esvirituAvailable = esvirituInstalled

            // Check Nextflow
            let nfRunner = NextflowRunner()
            nextflowAvailable = await nfRunner.isAvailable()

            // Check container runtime
            let containerRT = await NewContainerRuntimeFactory.createRuntime()
            containerAvailable = containerRT != nil
        }
    }
}
