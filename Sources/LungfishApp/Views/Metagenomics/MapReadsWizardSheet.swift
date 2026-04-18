// MapReadsWizardSheet.swift - SwiftUI wizard for minimap2 read mapping
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import UniformTypeIdentifiers
import LungfishWorkflow
import LungfishIO

// MARK: - MapReadsWizardSheet

/// A SwiftUI sheet for configuring and launching a minimap2 read mapping run.
///
/// The wizard guides the user through selecting a reference genome and
/// alignment preset. Advanced scoring parameters are available in a
/// collapsed disclosure group.
///
/// ## Reference Selection
///
/// References are discovered asynchronously via ``ReferenceSequenceScanner``,
/// which scans the project for `.lungfishref` bundles, genome bundles, and
/// standalone FASTA files. The user can also browse for a FASTA file manually.
///
/// ## Preset Selection
///
/// The three most common presets (Short Reads, ONT, HiFi) are shown as a
/// segmented control. All presets are available in the advanced section.
///
/// ## Layout
///
/// ```
/// +----------------------------------------------------+
/// | [arrow.left.and.right] Map Reads (minimap2)  sample|
/// | Align reads to a reference genome                  |
/// +----------------------------------------------------+
/// | Reference:                                         |
/// |   [Dropdown of discovered references      v]       |
/// |   [Browse...]                                      |
/// +----------------------------------------------------+
/// | Platform:                                          |
/// |   [ Short Reads | ONT | HiFi ]                     |
/// |   Best for paired-end Illumina reads (100-300 bp)  |
/// +----------------------------------------------------+
/// | > Advanced Settings                                |
/// |   All presets dropdown                              |
/// |   Threads: [ 8 ]                                   |
/// |   Secondary alignments: [ ]                        |
/// |   Supplementary alignments: [x]                    |
/// |   Min MAPQ: [ 0 ]                                  |
/// |   Match score: [  ]                                |
/// |   Mismatch penalty: [  ]                           |
/// |   Seed length: [  ]                                |
/// +----------------------------------------------------+
/// |                        [Cancel]  [Run]             |
/// +----------------------------------------------------+
/// ```
struct MapReadsWizardSheet: View {

    /// The input FASTQ files to align.
    let inputFiles: [URL]

    /// The project URL for reference discovery. Nil if no project is open.
    let projectURL: URL?

    /// Whether the wizard is embedded inside the shared operations dialog shell.
    let embeddedInOperationsDialog: Bool

    /// Incremented by the shared shell to request a run.
    let embeddedRunTrigger: Int

    // MARK: - State

    /// Discovered reference candidates from the project.
    @State private var referenceCandidates: [ReferenceCandidate] = []

    /// Whether reference scanning is in progress.
    @State private var isLoadingReferences = false

    /// The selected reference candidate ID.
    @State private var selectedReferenceID: String = ""

    /// URL from the file browser (when user browses for a FASTA not in the project).
    @State private var browsedReferenceURL: URL?

    /// The selected alignment preset.
    @State private var preset: Minimap2Preset = .shortRead

    /// Number of threads.
    @State private var threads: Int = ProcessInfo.processInfo.processorCount

    /// Whether to show the advanced settings section.
    @State private var showAdvanced: Bool = false

    // Advanced settings
    @State private var includeSecondary: Bool = false
    @State private var includeSupplementary: Bool = true
    @State private var minMappingQuality: Int = 0
    @State private var matchScore: String = ""
    @State private var mismatchPenalty: String = ""
    @State private var seedLength: String = ""

    // MARK: - Callbacks

    /// Called when the user clicks Run with a fully configured ``Minimap2Config``.
    var onRun: ((Minimap2Config) -> Void)?

    /// Called when the user clicks Cancel.
    var onCancel: (() -> Void)?

    /// Notifies the shared shell whether the current configuration can run.
    var onRunnerAvailabilityChange: ((Bool) -> Void)?

    // MARK: - Initialization

    init(
        inputFiles: [URL],
        projectURL: URL?,
        embeddedInOperationsDialog: Bool = false,
        embeddedRunTrigger: Int = 0,
        onRun: ((Minimap2Config) -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onRunnerAvailabilityChange: ((Bool) -> Void)? = nil
    ) {
        self.inputFiles = inputFiles
        self.projectURL = projectURL
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

    /// Whether the input appears to be paired-end (2 files or a FASTQ bundle).
    private var isPairedEnd: Bool {
        inputFiles.count == 2
    }

    /// The resolved reference FASTA URL, from either the candidate picker or the file browser.
    private var resolvedReferenceURL: URL? {
        if selectedReferenceID == "__browsed__", let browsed = browsedReferenceURL {
            return browsed
        }
        return referenceCandidates.first { $0.id == selectedReferenceID }?.fastaURL
    }

    /// Whether the Run button should be enabled.
    private var canRun: Bool {
        resolvedReferenceURL != nil && !inputFiles.isEmpty
    }

    /// The common presets shown in the segmented control.
    private static let commonPresets: [Minimap2Preset] = [.shortRead, .mapONT, .mapHiFi]

    // MARK: - Body

    var body: some View {
        Group {
            if embeddedInOperationsDialog {
                embeddedBody
            } else {
                standaloneBody
            }
        }
        .frame(
            width: embeddedInOperationsDialog ? nil : 520,
            height: embeddedInOperationsDialog ? nil : 520
        )
        .task {
            await loadReferences()
        }
        .onAppear {
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: canRun) { _, newValue in
            onRunnerAvailabilityChange?(newValue)
        }
        .onChange(of: embeddedRunTrigger) { _, _ in
            guard embeddedInOperationsDialog else { return }
            performRun()
        }
    }

    private var standaloneBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection

            Divider()

            ScrollView {
                configurationContent
            }

            Divider()

            footerSection
        }
    }

    private var embeddedBody: some View {
        ScrollView {
            configurationContent
        }
    }

    private var configurationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            referenceSection
            Divider()
            presetSection
            Divider()
            advancedSection
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.and.right.text.vertical")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Map Reads (minimap2)")
                    .font(.headline)
                Text("Align reads to a reference genome")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(inputDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Reference Section

    private var referenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if isLoadingReferences {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning for references...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if referenceCandidates.isEmpty && browsedReferenceURL == nil {
                HStack {
                    Text("No references found in project.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("", selection: $selectedReferenceID) {
                    if let browsedURL = browsedReferenceURL {
                        Text(browsedURL.lastPathComponent)
                            .tag("__browsed__")
                    }
                    ForEach(referenceCandidates) { candidate in
                        Text(candidate.displayName)
                            .tag(candidate.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Button("Browse\u{2026}") {
                browseForReference()
            }
            .font(.system(size: 12))
        }
    }

    // MARK: - Preset Section

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Platform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Picker("", selection: $preset) {
                ForEach(Self.commonPresets, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(preset.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        DisclosureGroup("Advanced Settings", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                // Full preset picker (all presets)
                HStack {
                    Text("Preset:")
                        .font(.system(size: 12))
                        .frame(width: 140, alignment: .trailing)
                    Picker("", selection: $preset) {
                        ForEach(Minimap2Preset.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 250)
                }

                // Threads
                HStack {
                    Text("Threads:")
                        .font(.system(size: 12))
                        .frame(width: 140, alignment: .trailing)
                    Stepper(
                        "\(threads)",
                        value: $threads,
                        in: 1...ProcessInfo.processInfo.processorCount
                    )
                    .font(.system(size: 12))
                }

                // Secondary alignments
                HStack {
                    Text("Secondary alignments:")
                        .font(.system(size: 12))
                        .frame(width: 140, alignment: .trailing)
                    Toggle("", isOn: $includeSecondary)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    Text("Include multi-mapping secondaries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Supplementary alignments
                HStack {
                    Text("Supplementary:")
                        .font(.system(size: 12))
                        .frame(width: 140, alignment: .trailing)
                    Toggle("", isOn: $includeSupplementary)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    Text("Include chimeric/split alignments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Min MAPQ
                HStack {
                    Text("Min mapping quality:")
                        .font(.system(size: 12))
                        .frame(width: 140, alignment: .trailing)
                    Stepper("\(minMappingQuality)", value: $minMappingQuality, in: 0...60)
                        .font(.system(size: 12))
                }

                Divider()
                    .padding(.vertical, 4)

                Text("Scoring Overrides (leave blank for preset defaults)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                // Match score
                HStack {
                    Text("Match score (-A):")
                        .font(.system(size: 12))
                        .frame(width: 140, alignment: .trailing)
                    TextField("", text: $matchScore)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                }

                // Mismatch penalty
                HStack {
                    Text("Mismatch penalty (-B):")
                        .font(.system(size: 12))
                        .frame(width: 140, alignment: .trailing)
                    TextField("", text: $mismatchPenalty)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                }

                // Seed length
                HStack {
                    Text("Seed length (-k):")
                        .font(.system(size: 12))
                        .frame(width: 140, alignment: .trailing)
                    TextField("", text: $seedLength)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.top, 8)
        }
        .font(.system(size: 12, weight: .medium))
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            if !canRun && resolvedReferenceURL == nil {
                Text("Select a reference genome")
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

    /// Loads reference candidates from the project via ``ReferenceSequenceScanner``.
    private func loadReferences() async {
        guard let projectURL else { return }
        isLoadingReferences = true

        let candidates = await Task.detached {
            ReferenceSequenceScanner.scanAll(in: projectURL)
        }.value

        referenceCandidates = candidates
        isLoadingReferences = false

        // Auto-select the first candidate
        if selectedReferenceID.isEmpty, let first = candidates.first {
            selectedReferenceID = first.id
        }
    }

    /// Opens a file browser for selecting a reference FASTA.
    private func browseForReference() {
        let panel = NSOpenPanel()
        panel.title = "Select Reference FASTA"
        panel.allowedContentTypes = FASTAFileTypes.readableContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        // Use beginSheetModal per macOS 26 rules (NEVER runModal)
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            browsedReferenceURL = url
            selectedReferenceID = "__browsed__"
        }
    }

    /// Builds a ``Minimap2Config`` from the current settings and calls ``onRun``.
    private func performRun() {
        guard let referenceURL = resolvedReferenceURL else { return }

        // Determine output directory: next to the first input file
        let baseDir = inputFiles.first?.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory
        let runToken = String(UUID().uuidString.prefix(8))
        let outputDir = baseDir.appendingPathComponent("mapping-\(runToken)")

        let config = Minimap2Config(
            inputFiles: inputFiles,
            referenceURL: referenceURL,
            preset: preset,
            threads: threads,
            includeSecondary: includeSecondary,
            includeSupplementary: includeSupplementary,
            minMappingQuality: minMappingQuality,
            isPairedEnd: isPairedEnd,
            outputDirectory: outputDir,
            sampleName: inputDisplayName,
            matchScore: Int(matchScore),
            mismatchPenalty: Int(mismatchPenalty),
            seedLength: Int(seedLength)
        )

        onRun?(config)
    }
}
