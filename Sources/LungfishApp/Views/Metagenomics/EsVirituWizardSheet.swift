// EsVirituWizardSheet.swift - SwiftUI wizard for configuring an EsViritu run
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishWorkflow

// MARK: - EsVirituWizardSheet

/// A SwiftUI sheet for configuring and launching an EsViritu viral detection run.
///
/// The wizard guides the user through setting the sample name, input mode,
/// quality filtering, and database selection. Advanced settings include
/// minimum read length and thread count.
///
/// ## RAM Warning
///
/// The EsViritu database is approximately 5 GB extracted. If the system has
/// limited memory, a warning banner is shown.
///
/// ## Presentation
///
/// Hosted in an `NSPanel` via `NSHostingController` and presented with
/// `beginSheetModal` (per macOS 26 rules -- never `runModal()`).
///
/// ## Layout
///
/// ```
/// +----------------------------------------------------+
/// | (e) EsViritu Viral Detection      dataset_name     |
/// |     Identify viral sequences...                     |
/// +----------------------------------------------------+
/// | Sample Name: [  my_sample              ]           |
/// | Paired-End:  [x]                                   |
/// +----------------------------------------------------+
/// | Database: [ EsViritu v3.2.4 (5 GB)           v ]   |
/// |           Download database...                      |
/// +----------------------------------------------------+
/// | Quality Filtering: [x] Enabled                      |
/// +----------------------------------------------------+
/// | > Advanced Settings                                |
/// |   Min Read Length: [ 100 ]                         |
/// |   Threads: [ 8 ]                                   |
/// +----------------------------------------------------+
/// |                        [Cancel]  [Run]             |
/// +----------------------------------------------------+
/// ```
struct EsVirituWizardSheet: View {

    /// The input FASTQ files to analyze.
    let inputFiles: [URL]

    /// Whether the wizard is embedded inside the shared operations dialog shell.
    let embeddedInOperationsDialog: Bool

    /// Incremented by the shared shell to request a run.
    let embeddedRunTrigger: Int

    // MARK: - State

    @State private var sampleName: String = ""
    @State private var qualityFilter: Bool = true
    @State private var showAdvanced: Bool = false

    // Advanced settings
    @State private var minReadLength: Int = 100
    @State private var threads: Int = ProcessInfo.processInfo.activeProcessorCount

    // Database state
    @State private var isDatabaseInstalled: Bool = false
    @State private var databasePath: URL?
    @State private var databaseSizeText: String = ""

    // MARK: - Callbacks

    /// Called when the user clicks Run.
    ///
    /// The wizard always emits one config per logical sample. For single-sample
    /// runs this array has one element.
    var onRun: (([EsVirituConfig]) -> Void)?

    /// Called when the user clicks Cancel.
    var onCancel: (() -> Void)?

    /// Notifies the shared shell whether the current configuration can run.
    var onRunnerAvailabilityChange: ((Bool) -> Void)?

    init(
        inputFiles: [URL],
        embeddedInOperationsDialog: Bool = false,
        embeddedRunTrigger: Int = 0,
        onRun: (([EsVirituConfig]) -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onRunnerAvailabilityChange: ((Bool) -> Void)? = nil
    ) {
        self.inputFiles = inputFiles
        self.embeddedInOperationsDialog = embeddedInOperationsDialog
        self.embeddedRunTrigger = embeddedRunTrigger
        self.onRun = onRun
        self.onCancel = onCancel
        self.onRunnerAvailabilityChange = onRunnerAvailabilityChange
    }

    // MARK: - Computed Properties

    /// Display name for the input dataset, stripping bundle extensions.
    private var inputDisplayName: String {
        inputFiles.first?.lungfishDisplayName ?? ""
    }

    /// Grouped sample inputs inferred from selected FASTQ files.
    private var groupedSamples: [MetagenomicsSampleInput] {
        MetagenomicsSampleGrouper.group(inputFiles)
    }

    /// Whether this run is a multi-sample batch.
    private var isBatchMode: Bool {
        groupedSamples.count > 1
    }

    /// Whether the Run button should be enabled.
    private var canRun: Bool {
        !groupedSamples.isEmpty && isDatabaseInstalled && (isBatchMode || !sampleName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// The system's physical memory in bytes.
    private var systemRAMBytes: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    /// Whether the database may stress the system's memory.
    private var showRAMWarning: Bool {
        // EsViritu databases are ~5 GB; warn if system has <8 GB
        systemRAMBytes < 8_589_934_592
    }

    // MARK: - Body

    var body: some View {
        Group {
            if !embeddedInOperationsDialog {
                standaloneBody
            } else {
                embeddedBody
            }
        }
        .background(Color.lungfishCanvasBackground)
        .tint(.lungfishCreamsicleFallback)
        .onAppear {
            // Auto-populate sample name for single-sample runs
            if sampleName.isEmpty, let sample = groupedSamples.first {
                sampleName = sample.sampleId
            }

            // Check database installation
            checkDatabaseStatus()
            onRunnerAvailabilityChange?(canRun)
        }
        .onReceive(NotificationCenter.default.publisher(for: .managedResourcesDidChange)) { _ in
            checkDatabaseStatus()
        }
        .onChange(of: canRun) { _, newValue in
            onRunnerAvailabilityChange?(newValue)
        }
        .onChange(of: embeddedRunTrigger) { _, _ in
            guard embeddedInOperationsDialog else { return }
            performRun()
        }
    }

    private var embeddedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()

            ScrollView {
                configurationContent
            }

            Divider()
        }
    }

    private var standaloneBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EsViritu Viral Detection")
                        .font(.headline)
                    Text("Identify viral sequences using the EsViritu pipeline")
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }
                Spacer()
                if inputFiles.count == 1 {
                    Text(inputDisplayName)
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("\(groupedSamples.count) sample\(groupedSamples.count == 1 ? "" : "s") \u{00B7} \(inputFiles.count) files")
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                configurationContent
            }

            Divider()

            standaloneFooter
        }
        .frame(width: 520, height: 500)
    }

    private var configurationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Detect viruses from sequencing reads using the EsViritu pipeline. Results will include per-virus detection metrics, genome coverage, and taxonomic profiles.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            sampleSection

            Divider()

            databaseSection

            Divider()

            qualityFilterSection

            Divider()

            advancedSettings
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Samples

    private var sampleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isBatchMode ? "Batch Samples" : "Sample")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if isBatchMode {
                Text("One EsViritu run will be executed per sample.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groupedSamples.prefix(8)) { sample in
                        let mode = sample.isPairedEnd ? "PE" : "SE"
                        Text("\u{2022} \(sample.sampleId) (\(mode))")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if groupedSamples.count > 8 {
                        Text("\u{2026}and \(groupedSamples.count - 8) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                TextField("Enter sample name", text: $sampleName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                if let sample = groupedSamples.first {
                    Text(sample.isPairedEnd ? "Paired-end reads" : "Single-end reads")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Database

    private var databaseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Database")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if isDatabaseInstalled {
                HStack {
                    Circle()
                        .fill(Color.lungfishSageFallback)
                        .frame(width: 8, height: 8)
                    Text("EsViritu \(EsVirituDatabaseManager.currentVersion)")
                        .font(.system(size: 12))
                    if !databaseSizeText.isEmpty {
                        Text("(\(databaseSizeText))")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.lungfishSecondaryText)
                    }
                }
            } else {
                HStack {
                    Circle()
                        .fill(Color.lungfishCreamsicleFallback)
                        .frame(width: 8, height: 8)
                    Text("Database not installed")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.lungfishSecondaryText)

                    Button("Download Database\u{2026}") {
                        PluginManagerWindowController.show(tab: .databases)
                    }
                    .font(.system(size: 12))
                }
            }

            if showRAMWarning && isDatabaseInstalled {
                ramWarningBanner
            }
        }
    }

    /// Warning banner for limited system RAM.
    private var ramWarningBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color.lungfishCreamsicleFallback)
                .frame(width: 8, height: 8)
                .padding(.top, 3)
            Text("This system has limited RAM. EsViritu may run slowly with large databases. Consider closing other applications before running.")
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.lungfishAttentionFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.lungfishCreamsicleFallback.opacity(0.35), lineWidth: 0.5)
        )
    }

    // MARK: - Quality Filtering

    private var qualityFilterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quality Filtering")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Toggle("Enable quality filtering (fastp)", isOn: $qualityFilter)
                .font(.system(size: 12))

            Text(qualityFilter
                 ? "Reads will be adapter-trimmed and quality-filtered before detection."
                 : "Raw reads will be used directly. Use if data is already preprocessed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Advanced Settings

    private var advancedSettings: some View {
        DisclosureGroup("Advanced Settings", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                // Minimum read length
                HStack {
                    Text("Min read length:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Stepper("\(minReadLength) bp", value: $minReadLength, in: 50...500, step: 10)
                        .font(.system(size: 12))
                }

                // Threads
                HStack {
                    Text("Threads:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Stepper(
                        "\(threads)",
                        value: $threads,
                        in: 1...ProcessInfo.processInfo.processorCount
                    )
                    .font(.system(size: 12))
                }
            }
            .padding(.top, 8)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var standaloneFooter: some View {
        HStack {
            if !canRun {
                Text("Finish the settings above to continue")
                    .font(.caption)
                    .foregroundStyle(Color.lungfishOrangeFallback)
            }

            Spacer()

            Button("Cancel") {
                onCancel?()
            }
            .keyboardShortcut(.cancelAction)

            Button("Run") {
                performRun()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canRun)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    /// Checks whether the EsViritu database is installed.
    private func checkDatabaseStatus() {
        // EsVirituDatabaseManager is an actor, so we need Task for async access.
        // This runs on the main actor since we are updating @State.
        Task { @MainActor in
            let manager = EsVirituDatabaseManager.shared
            let installed = await manager.isInstalled()
            isDatabaseInstalled = installed
            if installed {
                if let info = await manager.installedDatabaseInfo() {
                    databasePath = info.path
                    let gb = Double(info.sizeBytes) / 1_073_741_824
                    databaseSizeText = String(format: "%.1f GB", gb)
                }
            } else {
                databasePath = nil
                databaseSizeText = ""
            }
        }
    }

    /// Builds an EsVirituConfig and calls onRun.
    private func performRun() {
        guard let dbPath = databasePath else { return }
        let samples = groupedSamples
        guard !samples.isEmpty else { return }

        let runToken = String(UUID().uuidString.prefix(8))
        let baseDir = inputFiles.first?.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory
        let batchRoot = baseDir.appendingPathComponent("esviritu-batch-\(runToken)")
        let trimmedName = sampleName.trimmingCharacters(in: .whitespaces)

        let configs = samples.map { sample in
            let outputDir: URL
            if isBatchMode {
                outputDir = batchRoot.appendingPathComponent(
                    MetagenomicsSampleGrouper.sanitizeSampleId(sample.sampleId)
                )
            } else {
                outputDir = baseDir.appendingPathComponent("esviritu-\(runToken)")
            }

            return EsVirituConfig(
                inputFiles: sample.inputFiles,
                isPairedEnd: sample.isPairedEnd,
                sampleName: isBatchMode ? sample.sampleId : (trimmedName.isEmpty ? sample.sampleId : trimmedName),
                outputDirectory: outputDir,
                databasePath: dbPath,
                qualityFilter: qualityFilter,
                minReadLength: minReadLength,
                threads: threads
            )
        }

        onRun?(configs)
    }
}
