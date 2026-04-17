// TaxTriageWizardSheet.swift - SwiftUI wizard for configuring a TaxTriage run
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO
import LungfishWorkflow

// MARK: - TaxTriageWizardSheet

/// A SwiftUI sheet for configuring and launching a TaxTriage run.
///
/// The wizard supports multi-sample input, platform selection, Kraken2 database
/// path, assembly control, and advanced parameter tuning. Prerequisite checks
/// for Nextflow and Docker/container runtime are shown at the top.
///
/// ## Multi-Sample Support
///
/// Users can add multiple samples, each with its own R1/R2 FASTQ files.
/// Paired-end detection is automatic based on whether two files are provided.
///
/// ## Presentation
///
/// Hosted in an `NSPanel` via `NSHostingController` and presented with
/// `beginSheetModal` (per macOS 26 rules -- never `runModal()`).
struct TaxTriageWizardSheet: View {

    /// Initial input FASTQ files (pre-populated from the invoking context).
    let initialFiles: [URL]

    /// Whether the wizard is embedded inside the shared classifier runner shell.
    let embeddedInUnifiedRunner: Bool

    /// Incremented by the shared shell to request a run.
    let embeddedRunTrigger: Int

    // MARK: - State

    @State private var samples: [WizardSample] = []
    @State private var platform: TaxTriageConfig.Platform = .illumina
    @State private var skipAssembly: Bool = true
    @State private var skipKrona: Bool = false
    @State private var showAdvanced: Bool = false

    // Database
    @State private var installedDatabases: [MetagenomicsDatabaseInfo] = []
    @State private var selectedDatabaseName: String = ""

    // Advanced settings
    @State private var k2Confidence: Double = 0.2
    @State private var topHitsCount: Int = 10
    @State private var maxMemoryGB: Int = 16
    @State private var maxCpus: Int = ProcessInfo.processInfo.activeProcessorCount

    // Prerequisite state
    @State private var nextflowAvailable: Bool? = nil
    @State private var containerAvailable: Bool? = nil
    @State private var containerName: String = "Checking..."

    // MARK: - Callbacks

    /// Called when the user clicks Run.
    var onRun: ((TaxTriageConfig) -> Void)?

    /// Called when the user clicks Cancel.
    var onCancel: (() -> Void)?

    /// Notifies the shared shell whether the current configuration can run.
    var onRunnerAvailabilityChange: ((Bool) -> Void)?

    // MARK: - Initialization

    init(
        initialFiles: [URL] = [],
        embeddedInUnifiedRunner: Bool = false,
        embeddedRunTrigger: Int = 0,
        onRun: ((TaxTriageConfig) -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onRunnerAvailabilityChange: ((Bool) -> Void)? = nil
    ) {
        self.initialFiles = initialFiles
        self.embeddedInUnifiedRunner = embeddedInUnifiedRunner
        self.embeddedRunTrigger = embeddedRunTrigger
        self.onRun = onRun
        self.onCancel = onCancel
        self.onRunnerAvailabilityChange = onRunnerAvailabilityChange
    }

    // MARK: - Computed Properties

    /// Display name for the input dataset, stripping bundle extensions.
    private var inputDisplayName: String {
        initialFiles.first?.lungfishDisplayName ?? ""
    }

    /// Whether all prerequisites are met and the Run button should be enabled.
    private var canRun: Bool {
        !samples.isEmpty
        && nextflowAvailable == true
        && containerAvailable == true
        && !selectedDatabaseName.isEmpty
        && samples.allSatisfy { !$0.sampleId.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if !embeddedInUnifiedRunner {
                standaloneBody
            } else {
                embeddedBody
            }
        }
        .background(Color.lungfishCanvasBackground)
        .tint(.lungfishCreamsicleFallback)
        .onAppear {
            populateFromInitialFiles()
            checkPrerequisites()
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: canRun) { _, newValue in
            onRunnerAvailabilityChange?(newValue)
        }
        .onChange(of: embeddedRunTrigger) { _, _ in
            guard embeddedInUnifiedRunner else { return }
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
                    Text("TaxTriage")
                        .font(.headline)
                    Text("End-to-end pathogen detection for metagenomic samples")
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }
                Spacer()
                if initialFiles.count == 1 {
                    Text(inputDisplayName)
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if !samples.isEmpty {
                    Text("\(samples.count) sample\(samples.count == 1 ? "" : "s")")
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
        .frame(width: 520, height: 520)
    }

    private var configurationContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Classify and score organisms with alignment-based confidence. Requires Nextflow and Docker.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Prerequisite checks
            prerequisiteSection

            Divider()

            // Sample list
            sampleSection

            Divider()

            // Database + Platform side by side
            HStack(alignment: .top, spacing: 20) {
                databaseSection
                platformSection
            }

            Divider()

            // Assembly toggle
            assemblySection

            Divider()

            // Advanced settings
            advancedSettings
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Validation Message

    @ViewBuilder
    private var validationMessage: some View {
        if samples.isEmpty {
            Text("Add at least one sample")
                .font(.caption)
                .foregroundStyle(Color.lungfishOrangeFallback)
        } else if nextflowAvailable == false {
            Text("Nextflow is not installed")
                .font(.caption)
                .foregroundStyle(Color.lungfishOrangeFallback)
        } else if containerAvailable == false {
            Text("No container runtime available")
                .font(.caption)
                .foregroundStyle(Color.lungfishOrangeFallback)
        } else if nextflowAvailable == nil || containerAvailable == nil {
            Text("Checking prerequisites...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Prerequisites

    private var prerequisiteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prerequisites")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                prerequisiteIndicator(
                    label: "Nextflow",
                    available: nextflowAvailable
                )
                prerequisiteIndicator(
                    label: containerName,
                    available: containerAvailable
                )
            }
        }
    }

    private func prerequisiteIndicator(label: String, available: Bool?) -> some View {
        HStack(spacing: 4) {
            if let available {
                Circle()
                    .fill(available ? Color.lungfishSageFallback : Color.lungfishCreamsicleFallback)
                    .frame(width: 8, height: 8)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.lungfishCreamsicleFallback)
            }
            Text(label)
                .font(.system(size: 12))
        }
    }

    // MARK: - Samples

    private var sampleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Samples")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(samples.indices, id: \.self) { index in
                sampleRow(index: index)
            }

            Button {
                addSample()
            } label: { Text("Add Sample").font(.system(size: 12)) }
            .buttonStyle(.plain)
            .foregroundStyle(Color.lungfishCreamsicleFallback)
        }
    }

    private func sampleRow(index: Int) -> some View {
        HStack {
            TextField("Sample ID", text: $samples[index].sampleId)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 120)

            VStack(alignment: .leading, spacing: 2) {
                Text(samples[index].fastq1?.lastPathComponent ?? "No R1 file")
                    .font(.system(size: 10))
                    .foregroundStyle(samples[index].fastq1 != nil ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let r2 = samples[index].fastq2 {
                    Text(r2.lastPathComponent)
                        .font(.system(size: 10))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: $samples[index].sampleRole) {
                ForEach(SampleRole.allCases, id: \.self) { role in
                    Text(role.displayLabel).tag(role)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 130)
            .help("Sample role: test sample, negative control, positive control, etc.")

            Button {
                removeSample(at: index)
            } label: { Text("Remove") }
            .foregroundStyle(Color.lungfishSecondaryText)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func addSample() {
        samples.append(WizardSample(
            sampleId: "Sample_\(samples.count + 1)",
            fastq1: nil,
            fastq2: nil
        ))
    }

    private func removeSample(at index: Int) {
        guard samples.indices.contains(index) else { return }
        samples.remove(at: index)
    }

    // MARK: - Database

    private var databaseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Kraken2 Database")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if installedDatabases.isEmpty {
                HStack(spacing: 6) {
                    Text("No Kraken2 databases installed")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.lungfishCreamsicleFallback)
                }
            } else {
                Picker("", selection: $selectedDatabaseName) {
                    ForEach(installedDatabases, id: \.name) { db in
                        Text(db.name).tag(db.name)
                    }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: - Platform

    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sequencing Platform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Picker("", selection: $platform) {
                Text("Illumina").tag(TaxTriageConfig.Platform.illumina)
                Text("Oxford Nanopore").tag(TaxTriageConfig.Platform.oxford)
                Text("PacBio").tag(TaxTriageConfig.Platform.pacbio)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Assembly

    private var assemblySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Skip assembly (faster)", isOn: $skipAssembly)
                .font(.system(size: 12))

            Text(skipAssembly
                 ? "Classification and confidence scoring only. Significantly faster."
                 : "Full pipeline including de novo assembly. Slower but provides genome assemblies.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Advanced Settings

    private var advancedSettings: some View {
        DisclosureGroup("Advanced Settings", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                // K2 Confidence threshold
                HStack {
                    Text("K2 Confidence:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Slider(value: $k2Confidence, in: 0...1, step: 0.05)
                        .frame(maxWidth: 200)
                    Text(String(format: "%.2f", k2Confidence))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 40)
                }

                // Top hits count
                HStack {
                    Text("Top hits:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Stepper("\(topHitsCount)", value: $topHitsCount, in: 1...100)
                        .font(.system(size: 12))
                }

                // Max memory
                HStack {
                    Text("Max memory:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Stepper("\(maxMemoryGB) GB", value: $maxMemoryGB, in: 2...256, step: 2)
                        .font(.system(size: 12))
                }

                // Max CPUs
                HStack {
                    Text("Max CPUs:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Stepper(
                        "\(maxCpus)",
                        value: $maxCpus,
                        in: 1...ProcessInfo.processInfo.processorCount
                    )
                    .font(.system(size: 12))
                }

                // Skip Krona
                Toggle("Skip Krona visualization", isOn: $skipKrona)
                    .font(.system(size: 12))
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

    /// Checks Nextflow and container runtime availability.
    private func checkPrerequisites() {
        Task { @MainActor in
            let runner = NextflowRunner()
            let nfAvailable = await runner.isAvailable()
            nextflowAvailable = nfAvailable

            if let containerRT = await NewContainerRuntimeFactory.createRuntime() {
                containerAvailable = true
                let name = await containerRT.displayName
                containerName = "\(name): Available"
            } else {
                containerAvailable = false
                containerName = "Container: Not found"
            }

            // Load installed Kraken2 databases
            let registry = MetagenomicsDatabaseRegistry.shared
            let allDbs = (try? await registry.availableDatabases()) ?? []
            let kraken2Dbs = allDbs.filter { $0.tool == "kraken2" && $0.isDownloaded }
            installedDatabases = kraken2Dbs
            if selectedDatabaseName.isEmpty, let first = kraken2Dbs.first {
                selectedDatabaseName = first.name
            }
        }
    }

    /// Populates the sample list from the initial files.
    private func populateFromInitialFiles() {
        guard !initialFiles.isEmpty else { return }

        // Group files into pairs by stripping R1/R2 suffixes
        let fileGroups: [(url: URL, baseName: String)] = initialFiles.map { url in
            var base = url.deletingPathExtension().lastPathComponent
            // Strip .gz if present
            if url.pathExtension.lowercased() == "gz" {
                let withoutGz = url.deletingPathExtension()
                base = withoutGz.deletingPathExtension().lastPathComponent
            }
            for suffix in ["_R1", "_R2", "_1", "_2", "_R1_001", "_R2_001"] {
                if base.hasSuffix(suffix) {
                    base = String(base.dropLast(suffix.count))
                    break
                }
            }
            return (url, base)
        }

        // Group by base name
        let grouped = Dictionary(grouping: fileGroups, by: { $0.baseName })

        for (baseName, group) in grouped.sorted(by: { $0.key < $1.key }) {
            let urls = group.map(\.url)
            let r1 = urls.first
            let r2 = urls.count > 1 ? urls[1] : nil
            var sample = WizardSample(
                sampleId: baseName,
                fastq1: r1,
                fastq2: r2
            )

            // Auto-load metadata from FASTQ bundle if available
            if let r1 {
                let bundleURL = r1.deletingLastPathComponent()
                if bundleURL.pathExtension == "lungfishfastq",
                   let csvMeta = FASTQBundleCSVMetadata.load(from: bundleURL) {
                    let meta = FASTQSampleMetadata(from: csvMeta, fallbackName: baseName)
                    sample.sampleRole = meta.sampleRole
                    sample.metadataLabel = meta.sampleName != baseName ? meta.sampleName : nil
                    sample.isNegativeControl = meta.sampleRole == .negativeControl || meta.sampleRole == .extractionBlank
                }
            }

            samples.append(sample)
        }
    }

    /// Builds a TaxTriageConfig from the current settings and calls onRun.
    private func performRun() {
        let taxSamples = samples.compactMap { wizardSample -> TaxTriageSample? in
            guard let r1 = wizardSample.fastq1 else { return nil }
            var sampleMeta = FASTQSampleMetadata(sampleName: wizardSample.sampleId)
            sampleMeta.sampleRole = wizardSample.sampleRole
            return TaxTriageSample(
                sampleId: wizardSample.sampleId.trimmingCharacters(in: .whitespaces),
                fastq1: r1,
                fastq2: wizardSample.fastq2,
                platform: platform,
                isNegativeControl: wizardSample.effectiveIsNegativeControl,
                metadata: sampleMeta
            )
        }

        guard !taxSamples.isEmpty else { return }

        // Collect the distinct parent directories (bundle URLs) for all input files.
        // For multi-bundle runs, use the common ancestor as the output directory
        // so results are not buried inside a single bundle.
        let parentDirs = Set(initialFiles.map { $0.deletingLastPathComponent().standardizedFileURL })
        let sourceBundleURLs: [URL]? = parentDirs.count > 1 ? Array(parentDirs).sorted(by: { $0.path < $1.path }) : nil

        let outputDir: URL
        if parentDirs.count > 1 {
            // Multi-bundle: place output in the common ancestor directory
            outputDir = Self.commonAncestorDirectory(of: Array(parentDirs))
                .appendingPathComponent("taxtriage-\(UUID().uuidString.prefix(8))")
        } else {
            outputDir = initialFiles.first?.deletingLastPathComponent()
                .appendingPathComponent("taxtriage-\(UUID().uuidString.prefix(8))")
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("taxtriage-\(UUID().uuidString.prefix(8))")
        }

        // Find the selected database path
        let dbPath = installedDatabases.first(where: { $0.name == selectedDatabaseName })?.path

        let config = TaxTriageConfig(
            samples: taxSamples,
            platform: platform,
            outputDirectory: outputDir,
            kraken2DatabasePath: dbPath,
            topHitsCount: topHitsCount,
            k2Confidence: k2Confidence,
            skipAssembly: skipAssembly,
            skipKrona: skipKrona,
            maxMemory: "\(maxMemoryGB).GB",
            maxCpus: maxCpus,
            sourceBundleURLs: sourceBundleURLs
        )

        onRun?(config)
    }

    /// Computes the deepest common ancestor directory of the given URLs.
    static func commonAncestorDirectory(of urls: [URL]) -> URL {
        guard let first = urls.first else {
            return FileManager.default.temporaryDirectory
        }
        guard urls.count > 1 else {
            return first
        }

        var commonComponents = first.standardizedFileURL.pathComponents
        for url in urls.dropFirst() {
            let components = url.standardizedFileURL.pathComponents
            let minLength = min(commonComponents.count, components.count)
            var matchEnd = 0
            for i in 0..<minLength {
                if commonComponents[i] == components[i] {
                    matchEnd = i + 1
                } else {
                    break
                }
            }
            commonComponents = Array(commonComponents.prefix(matchEnd))
        }

        // Rebuild URL from common path components
        if commonComponents.isEmpty {
            return URL(fileURLWithPath: "/")
        }
        let path = commonComponents.joined(separator: "/")
            .replacingOccurrences(of: "//", with: "/")
        return URL(fileURLWithPath: path)
    }
}


// MARK: - WizardSample

/// A mutable sample entry in the TaxTriage wizard.
///
/// This is the UI-layer model. It is converted to ``TaxTriageSample`` when
/// building the ``TaxTriageConfig``.
private struct WizardSample: Identifiable {
    let id = UUID()
    var sampleId: String
    var fastq1: URL?
    var fastq2: URL?
    var isNegativeControl: Bool = false

    /// Structured sample role, loaded from bundle metadata when available.
    var sampleRole: SampleRole = .testSample

    /// Display label from metadata (if different from sampleId).
    var metadataLabel: String?

    /// Whether isNegativeControl should be derived from sampleRole.
    var effectiveIsNegativeControl: Bool {
        sampleRole == .negativeControl || sampleRole == .extractionBlank || isNegativeControl
    }
}
