// AssemblyWizardSheet.swift - SwiftUI wizard for configuring a SPAdes assembly run
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishWorkflow

// MARK: - AssemblyWizardSheet

/// A SwiftUI sheet for configuring and launching a SPAdes de novo assembly.
///
/// Follows the same layout pattern as ``ClassificationWizardSheet``:
/// header, divider, scrollable content sections, divider, footer with
/// validation + Cancel/Run buttons.
///
/// ## Presentation
///
/// Presented via ``AssemblySheetPresenter`` as an `NSPanel` sheet attached
/// to the main window. All UI state lives in `@State` properties; the
/// caller only receives a completed ``SPAdesAssemblyConfig`` through the
/// `onRun` callback.
///
/// ## Layout
///
/// ```
/// +------------------------------------------------------+
/// | [wrench]  SPAdes Assembly          dataset-name       |
/// |           De novo genome assembly                     |
/// +------------------------------------------------------+
/// | Mode: [ Isolate | Meta | Plasmid | RNA | Bio ]       |
/// +------------------------------------------------------+
/// | Resources                                            |
/// |   Memory: [---|---8---------] 8 GB                   |
/// |   Threads: [---|---4--------] 4                      |
/// +------------------------------------------------------+
/// | Options                                              |
/// |   [x] Error correction                               |
/// |   [ ] Careful mode                                   |
/// +------------------------------------------------------+
/// | > Advanced Settings                                  |
/// +------------------------------------------------------+
/// |  [runtime status]        [Cancel]  [Run]             |
/// +------------------------------------------------------+
/// ```
struct AssemblyWizardSheet: View {

    /// The input FASTQ file URLs to assemble.
    let inputFiles: [URL]

    /// Output directory for the assembly (e.g. project's Assemblies/).
    let outputDirectory: URL?

    /// Whether the wizard is embedded inside the shared operations dialog shell.
    let embeddedInOperationsDialog: Bool

    /// Incremented by the shared shell to request a run.
    let embeddedRunTrigger: Int

    // MARK: - State

    @State private var selectedMode: SPAdesMode = .isolate
    @State private var maxMemoryGB: Double = 8
    @State private var maxThreads: Double = 4
    @State private var performErrorCorrection: Bool = true
    @State private var careful: Bool = false

    // Advanced settings
    @State private var showAdvanced: Bool = false
    @State private var autoKmer: Bool = true
    @State private var customKmerString: String = "21,33,55,77,99,127"
    @State private var covCutoff: String = ""
    @State private var phredOffset: Int = 0
    @State private var projectName: String = ""
    @State private var minContigLength: Int = 500
    @State private var customArgsString: String = ""

    // Runtime check
    @State private var runtimeAvailable: Bool? = nil  // nil = checking

    // MARK: - Callbacks

    /// Called when the user clicks Run with the assembled configuration.
    var onRun: ((SPAdesAssemblyConfig) -> Void)?

    /// Called when the user clicks Cancel.
    var onCancel: (() -> Void)?

    /// Notifies the shared shell whether the current configuration can run.
    var onRunnerAvailabilityChange: ((Bool) -> Void)?

    // MARK: - Initialization

    init(
        inputFiles: [URL],
        outputDirectory: URL?,
        embeddedInOperationsDialog: Bool = false,
        embeddedRunTrigger: Int = 0,
        onRun: ((SPAdesAssemblyConfig) -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onRunnerAvailabilityChange: ((Bool) -> Void)? = nil
    ) {
        self.inputFiles = inputFiles
        self.outputDirectory = outputDirectory
        self.embeddedInOperationsDialog = embeddedInOperationsDialog
        self.embeddedRunTrigger = embeddedRunTrigger
        self.onRun = onRun
        self.onCancel = onCancel
        self.onRunnerAvailabilityChange = onRunnerAvailabilityChange
    }

    // MARK: - Computed Properties

    /// Available system memory in GB.
    private var availableMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }

    /// Available CPU cores.
    private var availableCores: Int {
        ProcessInfo.processInfo.processorCount
    }

    /// Display name for the input dataset, stripping bundle extensions.
    private var inputDisplayName: String {
        inputFiles.first?.lungfishDisplayName ?? ""
    }

    /// Auto-detected paired-end file grouping.
    private var pairedEndInfo: (forward: [URL], reverse: [URL], unpaired: [URL]) {
        detectPairedEndFiles(inputFiles)
    }

    /// Whether the Run button should be enabled.
    private var canRun: Bool {
        guard !inputFiles.isEmpty else { return false }
        guard outputDirectory != nil else { return false }
        guard runtimeAvailable == true else { return false }
        guard projectName.isEmpty == false else { return false }
        // --careful is incompatible with --isolate
        if careful && selectedMode == .isolate { return false }
        // Validate custom k-mers if not auto
        if !autoKmer {
            let kmers = parseKmerString(customKmerString)
            if kmers.isEmpty { return false }
            if !kmers.allSatisfy({ $0 % 2 == 1 && $0 >= 11 && $0 <= 127 }) { return false }
        }
        return true
    }

    /// First validation error or warning for footer display.
    private var validationMessage: (text: String, isError: Bool)? {
        if inputFiles.isEmpty {
            return ("No input files selected", true)
        }
        if outputDirectory == nil {
            return ("No output directory", true)
        }
        if runtimeAvailable == false {
            return ("Container runtime unavailable", true)
        }
        if projectName.isEmpty {
            return ("Project name is required", true)
        }
        if careful && selectedMode == .isolate {
            return ("--careful is incompatible with --isolate mode", true)
        }
        if !autoKmer {
            let kmers = parseKmerString(customKmerString)
            if kmers.isEmpty {
                return ("Invalid k-mer configuration", true)
            }
            if let bad = kmers.first(where: { $0 % 2 == 0 }) {
                return ("K-mer sizes must be odd (found \(bad))", true)
            }
            if let bad = kmers.first(where: { $0 < 11 || $0 > 127 }) {
                return ("K-mer sizes must be 11-127 (found \(bad))", true)
            }
        }
        if maxMemoryGB < 8 {
            return ("SPAdes recommends at least 8 GB", false)
        }
        return nil
    }

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
            // Set defaults based on system resources
            maxMemoryGB = min(Double(availableMemoryGB) * 0.75, 32)
            maxThreads = min(Double(availableCores), 8)

            // Auto-generate project name from first input file
            if let first = inputFiles.first {
                let stem = first.deletingPathExtension().lastPathComponent
                let cleaned = stem
                    .replacingOccurrences(of: "_R1", with: "")
                    .replacingOccurrences(of: "_R2", with: "")
                    .replacingOccurrences(of: "_1", with: "")
                    .replacingOccurrences(of: "_2", with: "")
                    .replacingOccurrences(of: ".lungfishfastq", with: "")
                projectName = cleaned + "_assembly"
            }

            // Check container runtime availability
            let available = await NewContainerRuntimeFactory.createRuntime() != nil
            runtimeAvailable = available
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
            modeSection
            Divider()
            resourceSection
            Divider()
            optionsSection
            Divider()
            advancedSection
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("SPAdes Assembly")
                    .font(.headline)
                Text("De novo genome assembly")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if inputFiles.count == 1 {
                Text(inputDisplayName)
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
    }

    // MARK: - Mode Section

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assembly Mode")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Picker("", selection: $selectedMode) {
                Text("Isolate").tag(SPAdesMode.isolate)
                Text("Meta").tag(SPAdesMode.meta)
                Text("Plasmid").tag(SPAdesMode.plasmid)
                Text("RNA").tag(SPAdesMode.rna)
                Text("Bio").tag(SPAdesMode.biosyntheticSPAdes)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(selectedMode.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Resource Section

    private var resourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resources")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            // Memory slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Memory")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(Int(maxMemoryGB)) GB")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text("1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $maxMemoryGB,
                        in: 1...Double(availableMemoryGB),
                        step: 1
                    )
                    Text("\(availableMemoryGB)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if maxMemoryGB < 8 {
                    Text("SPAdes recommends at least 8 GB")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Threads slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Threads")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(Int(maxThreads))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text("1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $maxThreads,
                        in: 1...Double(availableCores),
                        step: 1
                    )
                    Text("\(availableCores)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Options Section

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Options")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Toggle("Perform error correction", isOn: $performErrorCorrection)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            HStack(spacing: 4) {
                Toggle("Careful mode (mismatch correction)", isOn: $careful)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .disabled(selectedMode == .isolate)
            }

            if careful && selectedMode == .isolate {
                Text("--careful is incompatible with --isolate mode")
                    .font(.caption)
                    .foregroundStyle(Color.lungfishOrangeFallback)
            }
        }
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        DisclosureGroup("Advanced Settings", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                // K-mer sizes
                HStack {
                    Text("K-mer sizes:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Toggle("Auto", isOn: $autoKmer)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }

                if !autoKmer {
                    HStack {
                        Text("")
                            .frame(width: 120)
                        TextField("21,33,55,77,99,127", text: $customKmerString)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Button("Reset") {
                            customKmerString = "21,33,55,77,99,127"
                        }
                        .controlSize(.small)
                    }

                    HStack {
                        Text("")
                            .frame(width: 120)
                        Text("Odd numbers between 11 and 127, comma-separated")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Coverage cutoff
                HStack {
                    Text("Coverage cutoff:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Picker("", selection: $covCutoff) {
                        Text("Default").tag("")
                        Text("Auto").tag("auto")
                        Text("Off").tag("off")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }

                // PHRED offset
                HStack {
                    Text("PHRED offset:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Picker("", selection: $phredOffset) {
                        Text("Auto-detect").tag(0)
                        Text("33 (Sanger/Illumina 1.8+)").tag(33)
                        Text("64 (Illumina 1.3-1.7)").tag(64)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }

                // Project name
                HStack {
                    Text("Project name:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    TextField("assembly_output", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                // Minimum contig length
                HStack {
                    Text("Min contig length:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    TextField("bp", value: $minContigLength, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 80)
                    Text("bp")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                // Custom CLI args
                HStack(alignment: .top) {
                    Text("Extra arguments:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("e.g. --tmp-dir /fast/tmp", text: $customArgsString)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Text("Passed verbatim to spades.py")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 8)
        }
        .font(.system(size: 12, weight: .medium))
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            // Runtime status indicator
            runtimeStatusView

            if let msg = validationMessage {
                HStack(spacing: 4) {
                    Image(systemName: msg.isError
                          ? "exclamationmark.circle.fill"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(msg.isError ? .red : .orange)
                        .font(.system(size: 11))
                    Text(msg.text)
                        .font(.caption)
                        .foregroundStyle(msg.isError ? .red : .orange)
                        .lineLimit(1)
                }
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

    // MARK: - Runtime Status

    private var runtimeStatusView: some View {
        HStack(spacing: 4) {
            switch runtimeAvailable {
            case nil:
                ProgressView()
                    .controlSize(.mini)
                Text("Checking...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case true:
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Runtime OK")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case false:
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("No Runtime")
                    .font(.caption)
                    .foregroundStyle(Color.lungfishOrangeFallback)
            }
        }
    }

    // MARK: - Actions

    /// Builds a ``SPAdesAssemblyConfig`` from the current state and calls `onRun`.
    private func performRun() {
        guard let outDir = outputDirectory else { return }

        let paired = pairedEndInfo
        let kmerSizes: [Int]? = autoKmer ? nil : parseKmerString(customKmerString)
        let parsedCustomArgs = customArgsString.isEmpty
            ? []
            : customArgsString.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        let config = SPAdesAssemblyConfig(
            mode: selectedMode,
            forwardReads: paired.forward,
            reverseReads: paired.reverse,
            unpairedReads: paired.unpaired,
            kmerSizes: kmerSizes,
            memoryGB: Int(maxMemoryGB),
            threads: Int(maxThreads),
            minContigLength: minContigLength,
            skipErrorCorrection: !performErrorCorrection,
            careful: careful,
            covCutoff: covCutoff.isEmpty ? nil : covCutoff,
            phredOffset: phredOffset == 0 ? nil : phredOffset,
            customArgs: parsedCustomArgs,
            outputDirectory: outDir,
            projectName: projectName
        )

        onRun?(config)
    }

    // MARK: - Helpers

    /// Parses a comma-separated k-mer string into sorted integers.
    private func parseKmerString(_ string: String) -> [Int] {
        string
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .sorted()
    }

    /// Auto-detects paired-end files from the input URLs based on naming conventions.
    private func detectPairedEndFiles(_ urls: [URL]) -> (forward: [URL], reverse: [URL], unpaired: [URL]) {
        let patterns: [(String, String)] = [
            ("_R1", "_R2"),
            ("_1.", "_2."),
            ("_r1", "_r2"),
            ("_forward", "_reverse"),
        ]

        var forward: [URL] = []
        var reverse: [URL] = []
        var matched = Set<URL>()

        for url in urls {
            guard !matched.contains(url) else { continue }
            let name = url.lastPathComponent

            for (p1, p2) in patterns {
                if name.contains(p1) {
                    let pairName = name.replacingOccurrences(of: p1, with: p2)
                    if let pair = urls.first(where: { $0.lastPathComponent == pairName }) {
                        forward.append(url)
                        reverse.append(pair)
                        matched.insert(url)
                        matched.insert(pair)
                        break
                    }
                } else if name.contains(p2) {
                    let pairName = name.replacingOccurrences(of: p2, with: p1)
                    if let pair = urls.first(where: { $0.lastPathComponent == pairName }) {
                        forward.append(pair)
                        reverse.append(url)
                        matched.insert(url)
                        matched.insert(pair)
                        break
                    }
                }
            }
        }

        let unpaired = urls.filter { !matched.contains($0) }
        return (forward, reverse, unpaired)
    }
}
