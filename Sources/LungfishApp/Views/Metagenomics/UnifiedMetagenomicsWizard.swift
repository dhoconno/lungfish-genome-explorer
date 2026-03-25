// UnifiedMetagenomicsWizard.swift - Unified entry point for all metagenomics analyses
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishWorkflow

// MARK: - UnifiedMetagenomicsWizard

/// A unified SwiftUI wizard that serves as the single entry point for all metagenomics
/// analysis workflows in Lungfish.
///
/// ## Analysis Types
///
/// | Type               | Tool         | Description                           | Speed  |
/// |--------------------|-------------|---------------------------------------|--------|
/// | Taxonomic          | Kraken2     | Broad taxonomic classification        | Fast   |
/// | Viral Detection    | EsViritu    | Virus-specific detection + coverage   | Medium |
/// | Clinical Triage    | TaxTriage   | End-to-end with confidence scoring    | Slow   |
///
/// ## Two-Step Flow
///
/// 1. **Choose Analysis Type**: User selects from the three analysis types.
///    Each option shows a description, estimated runtime, and tool availability.
/// 2. **Tool Configuration**: The wizard shows the appropriate sub-wizard for
///    the selected tool.
///
/// ## Presentation
///
/// Hosted in an `NSPanel` via `NSHostingController` and presented with
/// `beginSheetModal` (per macOS 26 rules -- never `runModal()`).
struct UnifiedMetagenomicsWizard: View {

    /// The input FASTQ files to analyze.
    let inputFiles: [URL]

    // MARK: - State

    @State private var currentStep: WizardStep = .chooseType
    @State private var selectedType: AnalysisType? = nil

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

    // MARK: - Enums

    /// The steps in the wizard flow.
    enum WizardStep {
        case chooseType
        case configure
    }

    /// The available metagenomics analysis types.
    enum AnalysisType: String, CaseIterable, Identifiable {
        case classification = "Taxonomic Classification"
        case viralDetection = "Viral Detection"
        case clinicalTriage = "Comprehensive Triage"

        var id: String { rawValue }

        /// SF Symbol name for the analysis type card.
        var symbolName: String {
            switch self {
            case .classification: return "magnifyingglass"
            case .viralDetection: return "ant"
            case .clinicalTriage: return "stethoscope"
            }
        }

        /// The underlying tool name.
        var toolName: String {
            switch self {
            case .classification: return "Kraken2 / Bracken"
            case .viralDetection: return "EsViritu"
            case .clinicalTriage: return "TaxTriage (Nextflow)"
            }
        }

        /// Brief description of what this analysis does.
        var analysisDescription: String {
            switch self {
            case .classification:
                return "Fast k-mer classification of sequencing reads. Assigns each read to a taxon and estimates community abundance using Kraken2 and Bracken."
            case .viralDetection:
                return "Virus-focused read mapping pipeline. Detects and quantifies viral pathogens with per-genome coverage metrics, consensus sequences, and iterative alignment."
            case .clinicalTriage:
                return "End-to-end metagenomic classification with alignment validation and TASS confidence scoring. Supports multiple classifiers, host removal, and PDF reporting."
            }
        }

        /// Estimated runtime for a typical sample.
        var estimatedRuntime: String {
            switch self {
            case .classification: return "~2-5 min"
            case .viralDetection: return "~10-20 min"
            case .clinicalTriage: return "~20-45 min"
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
                if currentStep == .configure, let type = selectedType {
                    Button {
                        currentStep = .chooseType
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .help("Back to analysis selection")

                    Text(type.rawValue)
                        .font(.headline)
                } else {
                    Text("Metagenomics Analysis")
                        .font(.headline)
                }
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

            // Content
            switch currentStep {
            case .chooseType:
                analysisTypeSelector

            case .configure:
                configurationStep
            }
        }
        .frame(width: 560, height: currentStep == .chooseType ? 520 : 680)
        .animation(.easeInOut(duration: 0.2), value: currentStep)
        .onAppear {
            checkToolAvailability()
        }
    }

    // MARK: - Step 1: Analysis Type Selector

    private var analysisTypeSelector: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose an analysis type for your sequencing data.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    ForEach(AnalysisType.allCases) { type in
                        analysisTypeCard(type)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }

            Divider()

            // Action buttons
            HStack {
                if let selected = selectedType, !selected.isConfigurable {
                    Text("\(selected.toolName) wizard not yet available")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()

                Button("Cancel") {
                    onCancel?()
                }
                .keyboardShortcut(.cancelAction)

                Button("Next") {
                    if let selected = selectedType, selected.isConfigurable {
                        currentStep = .configure
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedType == nil || !(selectedType?.isConfigurable ?? false))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    /// A single analysis type selection card.
    private func analysisTypeCard(_ type: AnalysisType) -> some View {
        Button {
            selectedType = type
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: type.symbolName)
                    .font(.system(size: 24))
                    .foregroundStyle(selectedType == type ? .white : Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedType == type ? Color.accentColor : Color.accentColor.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(type.rawValue)
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

                    HStack {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(type.estimatedRuntime)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selectedType == type
                          ? Color.accentColor.opacity(0.08)
                          : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        selectedType == type ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: selectedType == type ? 2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(type.rawValue)
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
        switch selectedType {
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

        case nil:
            EmptyView()
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
