// ClassificationWizardSheet.swift - SwiftUI wizard for starting a Kraken2 classification
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishWorkflow

// MARK: - ClassificationWizardSheet

/// A SwiftUI sheet for configuring and launching a Kraken2 classification run.
///
/// The wizard guides the user through selecting a goal, database, and sensitivity
/// preset. Advanced settings are available in a collapsed disclosure group.
///
/// ## Database Loading
///
/// Installed Kraken2 databases are loaded asynchronously via a `.task` modifier
/// from ``MetagenomicsDatabaseRegistry``. The first ready database is
/// auto-selected.
///
/// ## RAM Warning
///
/// When a database is selected that requires more RAM than the system has available,
/// a warning banner is shown below the database picker. The warning also suggests
/// enabling memory mapping and, when enabled, auto-checks the memory mapping toggle.
///
/// ## Presentation
///
/// Accessible from:
/// - Tools menu: "Classify Reads..."
/// - Right-click on a FASTQ in sidebar: "Classify with Kraken2..."
/// - The TaxonomyViewController (for re-running with different settings)
///
/// ## Layout
///
/// ```
/// +----------------------------------------------------+
/// | Classify Reads                                     |
/// +----------------------------------------------------+
/// | Goal:                                              |
/// |   [k.circle]  [chart.pie]  [scissors]       |
/// |   Classify Reads     Profile      Extract          |
/// +----------------------------------------------------+
/// | Database: [ Standard-8 (8 GB, ~8 GB RAM)     v ]   |
/// |           Download more databases...               |
/// |  [!] This database requires X GB RAM...            |
/// +----------------------------------------------------+
/// | Sensitivity: [ Sensitive | Balanced | Precise ]    |
/// |              General-purpose classification         |
/// +----------------------------------------------------+
/// | > Advanced Settings                                |
/// |   Confidence: [---|----0.2--------]  0.20          |
/// |   Min hit groups: [ 2 ]                            |
/// |   Threads: [ 4 ]                                   |
/// |   Memory mapping: [ ]                              |
/// +----------------------------------------------------+
/// |                        [Cancel]  [Run]             |
/// +----------------------------------------------------+
/// ```
struct ClassificationWizardSheet: View {

    /// The input FASTQ files to classify.
    let inputFiles: [URL]

    /// Installed Kraken2 databases, loaded asynchronously from the registry.
    @State private var installedDatabases: [MetagenomicsDatabaseInfo] = []

    // MARK: - State

    @State private var selectedGoal: ClassificationGoal = .classify
    @State private var selectedDatabaseName: String = ""
    @State private var preset: ClassificationConfig.Preset = .balanced
    @State private var showAdvanced: Bool = false

    // Advanced settings
    @State private var confidence: Double = 0.2
    @State private var minimumHitGroups: Int = 2
    @State private var threads: Int = 4
    @State private var memoryMapping: Bool = false

    // MARK: - Callbacks

    /// Called when the user clicks Run.
    ///
    /// The wizard always emits one config per logical sample. For single-sample
    /// runs this array has one element.
    var onRun: (([ClassificationConfig]) -> Void)?

    /// Called when the user clicks Cancel.
    var onCancel: (() -> Void)?

    // MARK: - Classification Goal

    /// The user's high-level intent for the classification.
    ///
    /// This is the UI-layer representation. The ``performRun()`` method maps it
    /// to ``ClassificationConfig.Goal`` when building the config.
    enum ClassificationGoal: String, CaseIterable, Identifiable {
        case classify = "Classify Reads"
        case profile = "Profile Community"
        case extract = "Extract by Organism"

        var id: String { rawValue }

        /// SF Symbol name for this goal.
        var symbolName: String {
            switch self {
            case .classify: return "k.circle"
            case .profile:  return "chart.pie"
            case .extract:  return "scissors"
            }
        }

        /// Description text shown below the goal button.
        var goalDescription: String {
            switch self {
            case .classify: return "Assign each read to a taxon"
            case .profile:  return "Estimate abundance of each organism"
            case .extract:  return "Pull out reads matching specific taxa"
            }
        }

        /// Maps to the workflow-level ``ClassificationConfig.Goal``.
        var configGoal: ClassificationConfig.Goal {
            switch self {
            case .classify: return .classify
            case .profile:  return .profile
            case .extract:  return .extract
            }
        }
    }

    // MARK: - Initialization

    init(
        inputFiles: [URL],
        onRun: (([ClassificationConfig]) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.inputFiles = inputFiles
        self.onRun = onRun
        self.onCancel = onCancel
    }

    // MARK: - Database Loading

    /// Asynchronously loads installed Kraken2 databases from the registry.
    private func loadDatabases() async {
        let registry = MetagenomicsDatabaseRegistry.shared
        let allDbs = (try? await registry.availableDatabases()) ?? []
        let kraken2Dbs = allDbs.filter { $0.tool == "kraken2" && $0.isDownloaded }
        installedDatabases = kraken2Dbs
        if selectedDatabaseName.isEmpty, let first = kraken2Dbs.first(where: { $0.status == .ready }) {
            selectedDatabaseName = first.name
        }
    }

    // MARK: - Computed Properties

    /// The currently selected database info, if any.
    private var selectedDatabase: MetagenomicsDatabaseInfo? {
        installedDatabases.first { $0.name == selectedDatabaseName }
    }

    /// Databases that are ready to use.
    private var readyDatabases: [MetagenomicsDatabaseInfo] {
        installedDatabases.filter { $0.status == .ready }
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
        !groupedSamples.isEmpty && selectedDatabase != nil && selectedDatabase?.status == .ready
    }

    /// Description text for the current preset.
    private var presetDescription: String {
        switch preset {
        case .sensitive:
            return "Maximum recall -- more results, lower confidence"
        case .balanced:
            return "General-purpose classification"
        case .precise:
            return "High-confidence calls -- fewer results, higher accuracy"
        }
    }

    /// The system's physical memory in bytes.
    private var systemRAMBytes: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    /// Whether the selected database requires more RAM than available.
    ///
    /// Returns `true` when the database's ``MetagenomicsDatabaseInfo/recommendedRAM``
    /// exceeds the system's physical memory.
    private var databaseExceedsRAM: Bool {
        guard let db = selectedDatabase else { return false }
        return db.recommendedRAM > systemRAMBytes
    }

    /// Human-readable warning text when the database exceeds available RAM.
    var ramWarningText: String {
        guard let db = selectedDatabase else { return "" }
        let requiredGB = Double(db.recommendedRAM) / 1_073_741_824
        let availableGB = Double(systemRAMBytes) / 1_073_741_824
        return "This database requires \(String(format: "%.0f", requiredGB)) GB RAM. "
            + "Your system has \(String(format: "%.0f", availableGB)) GB. "
            + "Consider enabling memory mapping."
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            HStack {
                Text("Classify & Profile Reads")
                    .font(.headline)
                Spacer()
                if inputFiles.count == 1 {
                    Text(inputFiles.first?.lastPathComponent ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("\(groupedSamples.count) sample\(groupedSamples.count == 1 ? "" : "s") · \(inputFiles.count) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Brief description of what will happen
                    Text("Classify reads using Kraken2 and estimate organism abundances with Bracken. Results will be shown as an interactive taxonomy browser.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if isBatchMode {
                        sampleOverviewSection
                        Divider()
                    }

                    Divider()

                    // Database picker
                    databasePicker

                    Divider()

                    // Preset selector
                    presetSelector

                    Divider()

                    // Advanced settings
                    advancedSettings
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }

            Divider()

            // Action buttons
            HStack {
                if !canRun && inputFiles.isEmpty {
                    Text("No input files selected")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !canRun && groupedSamples.isEmpty {
                    Text("Could not detect valid sample inputs")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !canRun && readyDatabases.isEmpty {
                    Text("No databases installed")
                        .font(.caption)
                        .foregroundStyle(.red)
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
        .frame(width: 520, height: 520)
        .task { await loadDatabases() }
        .onChange(of: preset) { _, newPreset in
            applyPreset(newPreset)
        }
        .onChange(of: selectedDatabaseName) { _, _ in
            // Auto-enable memory mapping when database exceeds RAM
            if databaseExceedsRAM && !memoryMapping {
                memoryMapping = true
            }
        }
    }

    // MARK: - Goal Selector

    private var sampleOverviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Batch Samples")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("One Kraken2/Bracken run will be executed per sample.")
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
        }
    }

    private var goalSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Goal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ForEach(ClassificationGoal.allCases) { goal in
                    goalButton(goal)
                }
            }
        }
    }

    /// A single goal selection button with icon and description.
    private func goalButton(_ goal: ClassificationGoal) -> some View {
        Button {
            selectedGoal = goal
        } label: {
            VStack(spacing: 6) {
                Image(systemName: goal.symbolName)
                    .font(.system(size: 20))
                    .frame(height: 24)
                Text(goal.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                Text(goal.goalDescription)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedGoal == goal
                          ? Color.accentColor.opacity(0.15)
                          : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        selectedGoal == goal ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: selectedGoal == goal ? 2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(goal.rawValue)
        .accessibilityHint(goal.goalDescription)
    }

    // MARK: - Database Picker

    private var databasePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Database")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if readyDatabases.isEmpty {
                HStack {
                    Text("No databases installed.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Button("Download Database\u{2026}") {
                        // Open Plugin Manager directly to the Databases tab
                        PluginManagerWindowController.show(tab: .databases)
                    }
                    .font(.system(size: 12))
                }
                .padding(.vertical, 4)
            } else {
                Picker("", selection: $selectedDatabaseName) {
                    ForEach(readyDatabases) { db in
                        HStack {
                            Text(db.name)
                            Spacer()
                            Text(formatSize(db.sizeBytes))
                                .foregroundStyle(.secondary)
                        }
                        .tag(db.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            if let db = selectedDatabase {
                HStack(spacing: 4) {
                    Text(db.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if db.recommendedRAM > 0 {
                        Text("-- \(formatSize(db.recommendedRAM)) RAM recommended")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // RAM warning banner
            if databaseExceedsRAM {
                ramWarningBanner
            }
        }
    }

    /// Warning banner shown when the selected database exceeds available RAM.
    private var ramWarningBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 12))
            Text(ramWarningText)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yellow.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.yellow.opacity(0.3), lineWidth: 0.5)
        )
        .accessibilityLabel("RAM warning: \(ramWarningText)")
    }

    // MARK: - Preset Selector

    private var presetSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sensitivity")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Picker("", selection: $preset) {
                Text("Sensitive").tag(ClassificationConfig.Preset.sensitive)
                Text("Balanced").tag(ClassificationConfig.Preset.balanced)
                Text("Precise").tag(ClassificationConfig.Preset.precise)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(presetDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Advanced Settings

    private var advancedSettings: some View {
        DisclosureGroup("Advanced Settings", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                // Confidence threshold
                HStack {
                    Text("Confidence:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Slider(value: $confidence, in: 0...1, step: 0.05)
                        .frame(maxWidth: 200)
                    Text(String(format: "%.2f", confidence))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 40)
                }

                // Minimum hit groups
                HStack {
                    Text("Min hit groups:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Stepper("\(minimumHitGroups)", value: $minimumHitGroups, in: 1...10)
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

                // Memory mapping
                HStack {
                    Text("Memory mapping:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Toggle("", isOn: $memoryMapping)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    Text("Use when database exceeds available RAM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
        .font(.system(size: 12, weight: .medium))
    }

    // MARK: - Actions

    /// Applies a preset's parameter values to the advanced settings.
    private func applyPreset(_ newPreset: ClassificationConfig.Preset) {
        let params = newPreset.parameters
        confidence = params.confidence
        minimumHitGroups = params.minimumHitGroups
    }

    /// Builds a ClassificationConfig from the current settings and calls onRun.
    private func performRun() {
        guard let db = selectedDatabase, let dbPath = db.path else { return }
        let samples = groupedSamples
        guard !samples.isEmpty else { return }

        let runToken = String(UUID().uuidString.prefix(8))
        let baseDir = inputFiles.first?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let batchRoot = baseDir.appendingPathComponent("classification-batch-\(runToken)")

        let configs = samples.map { sample in
            let outputDir: URL
            if isBatchMode {
                outputDir = batchRoot.appendingPathComponent(
                    MetagenomicsSampleGrouper.sanitizeSampleId(sample.sampleId)
                )
            } else {
                outputDir = baseDir.appendingPathComponent("classification-\(runToken)")
            }

            return ClassificationConfig(
                goal: .profile,  // Always run classify + Bracken profiling
                inputFiles: sample.inputFiles,
                isPairedEnd: sample.isPairedEnd,
                databaseName: db.name,
                databaseVersion: db.version ?? "unknown",
                databasePath: dbPath,
                confidence: confidence,
                minimumHitGroups: minimumHitGroups,
                threads: threads,
                memoryMapping: memoryMapping,
                quickMode: false,
                outputDirectory: outputDir
            )
        }

        onRun?(configs)
    }

    // MARK: - Formatting

    /// Formats a byte count as a human-readable size string.
    private func formatSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.0f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - RAM Checking Utility

extension ClassificationWizardSheet {

    /// Checks whether a database exceeds available system RAM.
    ///
    /// This is exposed as a static method for unit testing without rendering
    /// the SwiftUI view.
    ///
    /// - Parameters:
    ///   - database: The database to check.
    ///   - systemRAM: The system's physical RAM in bytes. Defaults to the
    ///     current system's physical memory.
    /// - Returns: `true` if the database's recommended RAM exceeds the
    ///   system's physical memory.
    static func databaseExceedsSystemRAM(
        _ database: MetagenomicsDatabaseInfo,
        systemRAM: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    ) -> Bool {
        database.recommendedRAM > systemRAM
    }

    /// Builds the RAM warning text for a database that exceeds available RAM.
    ///
    /// - Parameters:
    ///   - database: The database that exceeds RAM.
    ///   - systemRAM: The system's physical RAM in bytes.
    /// - Returns: A warning string suitable for display.
    static func buildRAMWarningText(
        for database: MetagenomicsDatabaseInfo,
        systemRAM: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    ) -> String {
        let requiredGB = Double(database.recommendedRAM) / 1_073_741_824
        let availableGB = Double(systemRAM) / 1_073_741_824
        return "This database requires \(String(format: "%.0f", requiredGB)) GB RAM. "
            + "Your system has \(String(format: "%.0f", availableGB)) GB. "
            + "Consider enabling memory mapping."
    }
}
