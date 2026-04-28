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
/// | Pathogen Detection  | TaxTriage   | End-to-end pathogen detection         | Slow   |
///
/// ## Presentation
///
/// Hosted in an `NSPanel` via `NSHostingController` and presented with
/// `beginSheetModal` (per macOS 26 rules -- never `runModal()`).
struct UnifiedMetagenomicsWizard: View {
    static let preferredContentSize = CGSize(width: 880, height: 620)

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
    @State private var runnerCanRun: Bool = false
    @State private var runnerRunTrigger: Int = 0
    @State private var runnerReadinessGate: UnifiedRunnerReadinessGate

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
        _runnerReadinessGate = State(initialValue: UnifiedRunnerReadinessGate(initialSelection: initialSelection))
    }

    #if DEBUG
    var testingSidebarSelection: AnalysisType { sidebarSelection }
    var testingInitialSelection: AnalysisType { initialSelection }
    #endif

    // MARK: - Enums

    /// The available metagenomics analysis types.
    enum AnalysisType: CaseIterable, Identifiable, Hashable, Sendable {
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
                return "End-to-end pathogen detection with TaxTriage. Uses alignment validation, host removal, and confidence scoring to help flag likely pathogens in metagenomic samples."
            }
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            runnerSidebar
                .frame(width: 260)
                .background(Color.lungfishSidebarBackground)

            Divider()

            VStack(spacing: 0) {
                UnifiedClassifierRunnerHeader(
                    title: sidebarSelection.sidebarTitle,
                    subtitle: sidebarSelection.analysisDescription,
                    datasetLabel: runnerDatasetLabel
                )

                Divider()

                runnerDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(20)

                Divider()

                footerBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.lungfishCanvasBackground)
        }
        .frame(width: Self.preferredContentSize.width, height: Self.preferredContentSize.height)
    }

    // MARK: - Runner Sidebar

    private var runnerSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                UnifiedClassifierRunnerSection("Classifier", subtitle: "Choose the analysis to configure") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(AnalysisType.allCases) { type in
                            Button {
                                sidebarSelection = type
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(type.sidebarTitle)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.primary)
                                    Text(type.toolName)
                                        .font(.caption)
                                        .foregroundStyle(Color.lungfishSecondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(sidebarSelection == type
                                            ? Color.lungfishCreamsicleFallback.opacity(0.18)
                                            : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(
                                            sidebarSelection == type
                                            ? Color.lungfishCreamsicleFallback.opacity(0.35)
                                            : Color.lungfishStroke,
                                            lineWidth: 1
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private var runnerDetail: some View {
        Group {
            switch sidebarSelection {
            case .classification:
                ClassificationWizardSheet(
                    inputFiles: inputFiles,
                    embeddedInOperationsDialog: true,
                    embeddedRunTrigger: runnerRunTrigger,
                    onRun: { configs in
                        onRunClassification?(configs)
                    },
                    onRunnerAvailabilityChange: { acceptRunnerAvailability($0, for: .classification) }
                )

            case .viralDetection:
                EsVirituWizardSheet(
                    inputFiles: inputFiles,
                    embeddedInOperationsDialog: true,
                    embeddedRunTrigger: runnerRunTrigger,
                    onRun: { configs in
                        onRunEsViritu?(configs)
                    },
                    onRunnerAvailabilityChange: { acceptRunnerAvailability($0, for: .viralDetection) }
                )

            case .clinicalTriage:
                TaxTriageWizardSheet(
                    initialFiles: inputFiles,
                    embeddedInOperationsDialog: true,
                    embeddedRunTrigger: runnerRunTrigger,
                    onRun: { config in
                        onRunTaxTriage?(config)
                    },
                    onRunnerAvailabilityChange: { acceptRunnerAvailability($0, for: .clinicalTriage) }
                )
            }
        }
        .onChange(of: sidebarSelection) { _, newSelection in
            runnerReadinessGate.select(newSelection)
            runnerCanRun = false
        }
    }

    private func acceptRunnerAvailability(_ canRun: Bool, for type: AnalysisType) {
        guard let accepted = runnerReadinessGate.accept(canRun: canRun, for: type) else {
            return
        }
        runnerCanRun = accepted
    }

    private var runnerDatasetLabel: String {
        if inputFiles.count == 1 {
            return inputFiles.first?.lastPathComponent ?? ""
        }
        return "\(inputFiles.count) files"
    }

    private var runnerFooterStatusText: String {
        runnerCanRun ? "Ready to run" : "Finish the settings above to continue"
    }

    private var footerBar: some View {
        UnifiedClassifierRunnerFooter(
            statusText: runnerFooterStatusText,
            isRunEnabled: runnerCanRun,
            onCancel: { onCancel?() },
            onRun: { runnerRunTrigger += 1 }
        )
    }

}

struct UnifiedRunnerReadinessGate {
    private var selected: UnifiedMetagenomicsWizard.AnalysisType
    private var session = AsyncValidationSession<UnifiedMetagenomicsWizard.AnalysisType, Bool>()
    private var tokens: [UnifiedMetagenomicsWizard.AnalysisType: AsyncRequestToken<UnifiedMetagenomicsWizard.AnalysisType>] = [:]

    init(initialSelection: UnifiedMetagenomicsWizard.AnalysisType) {
        selected = initialSelection
        tokens[initialSelection] = session.begin(input: initialSelection)
    }

    mutating func select(_ type: UnifiedMetagenomicsWizard.AnalysisType) {
        selected = type
        tokens[type] = session.begin(input: type)
    }

    mutating func accept(
        canRun: Bool,
        for type: UnifiedMetagenomicsWizard.AnalysisType
    ) -> Bool? {
        guard selected == type else { return nil }
        if tokens[type] == nil {
            tokens[type] = session.begin(input: type)
        }
        guard let token = tokens[type], session.shouldAccept(resultFor: token) else {
            return nil
        }
        return canRun
    }
}
