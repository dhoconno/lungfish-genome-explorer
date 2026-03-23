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
/// |   [magnifyingglass]  [chart.pie]  [scissors]       |
/// |   Classify Reads     Profile      Extract          |
/// +----------------------------------------------------+
/// | Database: [ Standard-8 (8 GB, ~8 GB RAM)     v ]   |
/// |           Download more databases...               |
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

    /// Installed databases available for selection.
    let installedDatabases: [MetagenomicsDatabaseInfo]

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
    var onRun: ((ClassificationConfig) -> Void)?

    /// Called when the user clicks Cancel.
    var onCancel: (() -> Void)?

    // MARK: - Classification Goal

    /// The user's high-level intent for the classification.
    enum ClassificationGoal: String, CaseIterable, Identifiable {
        case classify = "Classify Reads"
        case profile = "Profile Community"
        case extract = "Extract by Organism"

        var id: String { rawValue }

        /// SF Symbol name for this goal.
        var symbolName: String {
            switch self {
            case .classify: return "magnifyingglass"
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
    }

    // MARK: - Initialization

    init(
        inputFiles: [URL],
        installedDatabases: [MetagenomicsDatabaseInfo] = [],
        onRun: ((ClassificationConfig) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.inputFiles = inputFiles
        self.installedDatabases = installedDatabases
        self.onRun = onRun
        self.onCancel = onCancel

        // Default to first installed database
        let defaultDB = installedDatabases.first(where: { $0.status == .ready })?.name ?? ""
        _selectedDatabaseName = State(initialValue: defaultDB)
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

    /// Whether the Run button should be enabled.
    private var canRun: Bool {
        !inputFiles.isEmpty && selectedDatabase != nil && selectedDatabase?.status == .ready
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

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Goal selector
                    goalSelector

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
        .onChange(of: preset) { _, newPreset in
            applyPreset(newPreset)
        }
    }

    // MARK: - Goal Selector

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
                        // Open Plugin Manager to the database management section
                        PluginManagerWindowController.show()
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
        }
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

        let outputDir = inputFiles.first?.deletingLastPathComponent()
            .appendingPathComponent("classification-\(UUID().uuidString.prefix(8))")
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("classification-\(UUID().uuidString.prefix(8))")

        let config = ClassificationConfig(
            inputFiles: inputFiles,
            isPairedEnd: inputFiles.count == 2,
            databaseName: db.name,
            databasePath: dbPath,
            confidence: confidence,
            minimumHitGroups: minimumHitGroups,
            threads: threads,
            memoryMapping: memoryMapping,
            quickMode: false,
            outputDirectory: outputDir
        )

        onRun?(config)
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
