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
    static let preferredContentSize = CGSize(width: 760, height: 520)

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

        var symbolName: String {
            switch self {
            case .classification: return "k.circle"
            case .viralDetection: return "e.circle"
            case .clinicalTriage: return "t.circle"
            }
        }

        var toolName: String {
            switch self {
            case .classification: return "Classify & Profile (Kraken2)"
            case .viralDetection: return "Detect Viruses (EsViritu)"
            case .clinicalTriage: return "Detect Pathogens (TaxTriage)"
            }
        }

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

            HStack(spacing: 0) {
                runnerSidebar
                    .frame(width: 280)

                Divider()

                configurationStep
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(
            width: Self.preferredContentSize.width,
            height: Self.preferredContentSize.height
        )
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

}
