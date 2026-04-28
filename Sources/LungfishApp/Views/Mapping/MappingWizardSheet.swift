// MappingWizardSheet.swift - Shared SwiftUI wizard for read mapping tools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import UniformTypeIdentifiers
import LungfishIO
import LungfishWorkflow

struct MappingWizardSheet: View {
    let inputFiles: [URL]
    let projectURL: URL?
    let initialTool: MappingTool
    let embeddedInOperationsDialog: Bool
    let embeddedRunTrigger: Int

    @State private var referenceCandidates: [ReferenceCandidate] = []
    @State private var isLoadingReferences = false
    @State private var selectedReferenceID: String = ""
    @State private var browsedReferenceURL: URL?

    @State private var selectedModeID: String
    @State private var modeWasChangedByUser = false
    @State private var threads: Int
    @State private var includeSecondary = false
    @State private var includeSupplementary = true
    @State private var minMappingQuality = 0
    @State private var showAdvanced = false
    @State private var advancedOptionsText = ""

    @State private var detectedSequenceFormat: SequenceFormat?
    @State private var detectedReadClass: MappingReadClass?
    @State private var observedMaxReadLength: Int?
    @State private var mixedReadClasses = false
    @State private var hasUnclassifiedFASTQInputs = false
    @State private var mixedSequenceFormats = false
    @State private var isInspectingInputs = false

    var onRun: ((MappingRunRequest) -> Void)?
    var onCancel: (() -> Void)?
    var onRunnerAvailabilityChange: ((Bool) -> Void)?

    init(
        inputFiles: [URL],
        projectURL: URL?,
        initialTool: MappingTool,
        embeddedInOperationsDialog: Bool = false,
        embeddedRunTrigger: Int = 0,
        onRun: ((MappingRunRequest) -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onRunnerAvailabilityChange: ((Bool) -> Void)? = nil
    ) {
        self.inputFiles = inputFiles
        self.projectURL = projectURL
        self.initialTool = initialTool
        self.embeddedInOperationsDialog = embeddedInOperationsDialog
        self.embeddedRunTrigger = embeddedRunTrigger
        self.onRun = onRun
        self.onCancel = onCancel
        self.onRunnerAvailabilityChange = onRunnerAvailabilityChange
        _selectedModeID = State(initialValue: MappingMode.availableModes(for: initialTool).first?.id ?? MappingMode.defaultShortRead.id)
        _threads = State(initialValue: ProcessInfo.processInfo.processorCount)
    }

    private var inputDisplayName: String {
        inputFiles.first?.lungfishDisplayName ?? ""
    }

    private var isPairedEnd: Bool {
        inputFiles.count == 2
    }

    private var selectedReferenceCandidate: ReferenceCandidate? {
        referenceCandidates.first(where: { $0.id == selectedReferenceID })
    }

    private var resolvedReferenceURL: URL? {
        if selectedReferenceID == "__browsed__", let browsedReferenceURL {
            return browsedReferenceURL
        }
        return selectedReferenceCandidate?.fastaURL
    }

    private var sourceReferenceBundleURL: URL? {
        if selectedReferenceID == "__browsed__" {
            let sourceURL = ReferenceBundleSourceResolver.canonicalSourceBundleURL(
                for: browsedReferenceURL,
                projectURL: projectURL
            )
            return sourceURL?.pathExtension.lowercased() == "lungfishref" ? sourceURL : nil
        }
        return ReferenceBundleSourceResolver.canonicalSourceBundleURL(
            for: selectedReferenceCandidate?.sourceBundleURL,
            projectURL: projectURL
        )
    }

    private var selectedReferencePathDisplay: String? {
        if selectedReferenceID == "__browsed__", let browsedReferenceURL {
            return displayPath(for: browsedReferenceURL)
        }
        return selectedReferenceCandidate?.displayPath(relativeTo: projectURL)
    }

    private var selectedMode: MappingMode? {
        MappingMode(rawValue: selectedModeID)
    }

    static func advancedOptionsPlaceholder(for tool: MappingTool) -> String {
        switch tool {
        case .minimap2:
            return "--eqx -N 5"
        case .bwaMem2:
            return "-M -Y"
        case .bowtie2:
            return "--very-sensitive -N 1"
        case .bbmap:
            return "minid=0.97 local=t"
        }
    }

    private var selectedModeBinding: Binding<String> {
        Binding(
            get: { selectedModeID },
            set: { newValue in
                selectedModeID = newValue
                modeWasChangedByUser = true
            }
        )
    }

    private var compatibilityEvaluation: MappingCompatibilityEvaluation? {
        guard let detectedSequenceFormat, let selectedMode else { return nil }
        return MappingCompatibility.evaluate(
            tool: initialTool,
            mode: selectedMode,
            inputFormat: detectedSequenceFormat,
            readClass: detectedReadClass,
            observedMaxReadLength: observedMaxReadLength
        )
    }

    private var compatibilityPresentation: MappingCompatibilityPresentation {
        MappingCompatibilityPresentation.make(
            compatibility: compatibilityEvaluation,
            hasReference: resolvedReferenceURL != nil,
            hasInputs: !inputFiles.isEmpty,
            detectedSequenceFormat: detectedSequenceFormat,
            detectedReadClass: detectedReadClass,
            mixedReadClasses: mixedReadClasses,
            mixedSequenceFormats: mixedSequenceFormats,
            mixesDetectedAndUnclassifiedReadClasses: detectedReadClass != nil && hasUnclassifiedFASTQInputs
        )
    }

    private var canRun: Bool {
        compatibilityPresentation.isReady && advancedOptionsParseError == nil
    }

    private var modeOptions: [MappingMode] {
        MappingMode.availableModes(for: initialTool)
    }

    var body: some View {
        Group {
            if embeddedInOperationsDialog {
                embeddedBody
            } else {
                standaloneBody
            }
        }
        .frame(width: embeddedInOperationsDialog ? nil : 560, height: embeddedInOperationsDialog ? nil : 560)
        .task {
            await loadReferences()
            await inspectInputs()
            onRunnerAvailabilityChange?(canRun)
        }
        .onAppear {
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: canRun) { _, ready in
            onRunnerAvailabilityChange?(ready)
        }
        .onChange(of: detectedSequenceFormat) { _, _ in
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: detectedReadClass) { _, _ in
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: mixedReadClasses) { _, _ in
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: hasUnclassifiedFASTQInputs) { _, _ in
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: mixedSequenceFormats) { _, _ in
            onRunnerAvailabilityChange?(canRun)
        }
        .onChange(of: selectedReferenceID) { _, _ in
            onRunnerAvailabilityChange?(canRun)
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
            ScrollView { configurationContent }
            Divider()
            footerSection
        }
    }

    private var embeddedBody: some View {
        ScrollView { configurationContent }
    }

    private var configurationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            referenceSection
            Divider()
            modeSection
            Divider()
            compatibilitySection
            Divider()
            advancedSection
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.and.right.text.vertical")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Map Reads (\(initialTool.displayName))")
                    .font(.headline)
                Text("Map reads to a reference genome")
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

    private var referenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if isLoadingReferences {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning for references...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if referenceCandidates.isEmpty && browsedReferenceURL == nil {
                Text("No references found in project.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $selectedReferenceID) {
                    if let browsedReferenceURL {
                        Text(displayPath(for: browsedReferenceURL))
                            .tag("__browsed__")
                    }
                    ForEach(referenceCandidates) { candidate in
                        Text(candidate.pickerDisplayName(relativeTo: projectURL)).tag(candidate.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if let selectedReferencePathDisplay {
                    Text(selectedReferencePathDisplay)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Button("Browse...") {
                browseForReference()
            }
            .font(.system(size: 12))
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(initialTool == .minimap2 ? "Preset" : "Mode")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if modeOptions.count <= 3 {
                Picker("", selection: selectedModeBinding) {
                    ForEach(modeOptions, id: \.id) { mode in
                        Text(mode.displayName).tag(mode.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            } else {
                Picker("", selection: selectedModeBinding) {
                    ForEach(modeOptions, id: \.id) { mode in
                        Text(mode.displayName).tag(mode.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            if let selectedMode {
                Text(modeDescription(for: selectedMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var compatibilitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input Compatibility")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if isInspectingInputs {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Inspecting sequence inputs...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                if let detectedSequenceFormat {
                    Text("Detected format: \(detectedSequenceFormat == .fasta ? "FASTA" : "FASTQ")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let detectedReadClass {
                    Text("Detected reads: \(detectedReadClass.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let observedMaxReadLength {
                    Text("Observed max read length: \(observedMaxReadLength) bp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(compatibilityPresentation.message)
                    .font(.callout)
                    .foregroundStyle(compatibilityPresentation.color)
            }
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced Settings", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Threads:")
                        .font(.system(size: 12))
                        .frame(width: 150, alignment: .trailing)
                    Stepper("\(threads)", value: $threads, in: 1...ProcessInfo.processInfo.processorCount)
                        .font(.system(size: 12))
                }

                HStack {
                    Text("Secondary alignments:")
                        .font(.system(size: 12))
                        .frame(width: 150, alignment: .trailing)
                    Toggle("", isOn: $includeSecondary)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                }

                HStack {
                    Text("Supplementary:")
                        .font(.system(size: 12))
                        .frame(width: 150, alignment: .trailing)
                    Toggle("", isOn: $includeSupplementary)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                }

                HStack {
                    Text("Min mapping quality:")
                        .font(.system(size: 12))
                        .frame(width: 150, alignment: .trailing)
                    Stepper("\(minMappingQuality)", value: $minMappingQuality, in: 0...60)
                        .font(.system(size: 12))
                }

                Divider().padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Advanced Options")
                        .font(.system(size: 12))
                    TextField(Self.advancedOptionsPlaceholder(for: initialTool), text: $advancedOptionsText)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    if let advancedOptionsParseError {
                        Text(advancedOptionsParseError)
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    }
                }
            }
            .padding(.top, 8)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var footerSection: some View {
        HStack {
            Text(advancedOptionsParseError ?? compatibilityPresentation.message)
                .font(.caption)
                .foregroundStyle(advancedOptionsParseError == nil ? compatibilityPresentation.color : Color.orange)

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

    private func modeDescription(for mode: MappingMode) -> String {
        switch mode {
        case .defaultShortRead:
            return "Best for Illumina short-read DNA mapping."
        case .minimap2Asm5:
            return "Optimized for closely related haplotype or assembly alignment."
        case .minimap2Splice:
            return "Optimized for spliced CDS or cDNA alignment to genomic references."
        case .minimap2MapONT:
            return "Optimized for Oxford Nanopore reads."
        case .minimap2MapHiFi:
            return "Optimized for PacBio HiFi reads."
        case .minimap2MapPB:
            return "Optimized for PacBio CLR reads."
        case .bbmapStandard:
            return "Standard BBMap mode for short or moderate-length reads."
        case .bbmapPacBio:
            return "PacBio-tuned BBMap mode for long PacBio-class reads."
        }
    }

    private func loadReferences() async {
        guard let projectURL else { return }
        isLoadingReferences = true
        let candidates = await Task.detached {
            ReferenceSequenceScanner.scanAll(in: projectURL)
        }.value
        referenceCandidates = candidates
        isLoadingReferences = false

        if selectedReferenceID.isEmpty, let first = candidates.first {
            selectedReferenceID = first.id
        }
    }

    private func browseForReference() {
        let panel = NSOpenPanel()
        panel.title = "Select Reference FASTA"
        panel.allowedContentTypes = FASTAFileTypes.readableContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            browsedReferenceURL = url
            selectedReferenceID = "__browsed__"
        }
    }

    private func displayPath(for url: URL) -> String {
        let standardizedTarget = url.standardizedFileURL.path
        guard let projectURL else { return standardizedTarget }

        let projectPath = projectURL.standardizedFileURL.path
        let normalizedProjectPath = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        guard standardizedTarget.hasPrefix(normalizedProjectPath) else {
            return standardizedTarget
        }

        return String(standardizedTarget.dropFirst(normalizedProjectPath.count))
    }

    private func inspectInputs() async {
        isInspectingInputs = true
        let result = await Task.detached(priority: .userInitiated) {
            MappingInputInspection.inspect(urls: inputFiles)
        }.value
        detectedSequenceFormat = result.sequenceFormat
        detectedReadClass = result.readClass
        observedMaxReadLength = result.observedMaxReadLength
        mixedReadClasses = result.mixedReadClasses
        hasUnclassifiedFASTQInputs = result.hasUnclassifiedFASTQInputs
        mixedSequenceFormats = result.mixedSequenceFormats
        autoSelectPreferredModeIfNeeded(
            readClass: result.readClass,
            sequenceFormat: result.sequenceFormat,
            observedMaxReadLength: result.observedMaxReadLength
        )
        isInspectingInputs = false
    }

    private func autoSelectPreferredModeIfNeeded(
        readClass: MappingReadClass?,
        sequenceFormat: SequenceFormat?,
        observedMaxReadLength: Int?
    ) {
        guard !modeWasChangedByUser else { return }
        let inputFormat = sequenceFormat ?? (readClass == nil ? nil : .fastq)
        guard let inputFormat,
              let preferredMode = MappingMode.preferredMode(
                for: initialTool,
                readClass: readClass,
                inputFormat: inputFormat
              ),
              preferredMode.id != selectedModeID else {
            return
        }

        if let selectedMode {
            let evaluation = MappingCompatibility.evaluate(
                tool: initialTool,
                mode: selectedMode,
                inputFormat: inputFormat,
                readClass: readClass,
                observedMaxReadLength: observedMaxReadLength
            )
            guard evaluation.isBlocked else { return }
        }

        selectedModeID = preferredMode.id
    }

    private func performRun() {
        guard canRun, let referenceURL = resolvedReferenceURL, let selectedMode else { return }

        let baseDir = inputFiles.first?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        let runToken = String(UUID().uuidString.prefix(8))
        let outputDir = baseDir.appendingPathComponent("mapping-\(runToken)")

        let request = MappingRunRequest(
            tool: initialTool,
            modeID: selectedMode.id,
            inputFASTQURLs: inputFiles,
            referenceFASTAURL: referenceURL,
            sourceReferenceBundleURL: sourceReferenceBundleURL,
            projectURL: projectURL,
            outputDirectory: outputDir,
            sampleName: inputDisplayName,
            pairedEnd: isPairedEnd,
            threads: threads,
            includeSecondary: includeSecondary,
            includeSupplementary: includeSupplementary,
            minimumMappingQuality: minMappingQuality,
            advancedArguments: advancedArguments()
        )

        onRun?(request)
    }

    private func advancedArguments() -> [String] {
        (try? AdvancedCommandLineOptions.parse(advancedOptionsText)) ?? []
    }

    private var advancedOptionsParseError: String? {
        do {
            _ = try AdvancedCommandLineOptions.parse(advancedOptionsText)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
