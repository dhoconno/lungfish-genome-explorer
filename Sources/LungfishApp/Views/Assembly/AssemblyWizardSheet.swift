// AssemblyWizardSheet.swift - Shared managed assembly configuration UI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishWorkflow

struct AssemblyWizardSheet: View {
    private static let mixedDetectedAndUnclassifiedInputsMessage =
        "Selected FASTQ inputs mix detected and unclassified read classes. Select one read class per run."

    let inputFiles: [URL]
    let outputDirectory: URL?
    let initialTool: AssemblyTool
    let embeddedInOperationsDialog: Bool
    let embeddedRunTrigger: Int

    @State private var selectedTool: AssemblyTool
    @State private var selectedReadType: AssemblyReadType
    @State private var threads: Double = 4
    @State private var memoryGB: Double = 8
    @State private var minContigLength: Int = 500
    @State private var selectedProfileID: String
    @State private var projectName: String = ""
    @State private var extraArgumentsText: String = ""
    @State private var hasConfirmedManualReadType: Bool
    @State private var showAdvanced = false
    @State private var spadesCareful = false
    @State private var spadesSkipErrorCorrection = false
    @State private var flyeMetagenomeMode = false
    @State private var hifiasmPrimaryOnly = false
    @State private var packStatus: PluginPackStatus?

    var onRun: ((AssemblyRunRequest) -> Void)?
    var onCancel: (() -> Void)?
    var onRunnerAvailabilityChange: ((Bool) -> Void)?

    init(
        inputFiles: [URL],
        outputDirectory: URL?,
        initialTool: AssemblyTool = .spades,
        embeddedInOperationsDialog: Bool = false,
        embeddedRunTrigger: Int = 0,
        onRun: ((AssemblyRunRequest) -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onRunnerAvailabilityChange: ((Bool) -> Void)? = nil
    ) {
        self.inputFiles = inputFiles
        self.outputDirectory = outputDirectory
        self.initialTool = initialTool
        self.embeddedInOperationsDialog = embeddedInOperationsDialog
        self.embeddedRunTrigger = embeddedRunTrigger
        self.onRun = onRun
        self.onCancel = onCancel
        self.onRunnerAvailabilityChange = onRunnerAvailabilityChange

        let detectedReadType = Self.detectedReadType(from: inputFiles)
        _selectedTool = State(initialValue: initialTool)
        _selectedReadType = State(initialValue: detectedReadType ?? Self.defaultReadType(for: initialTool))
        _selectedProfileID = State(initialValue: Self.defaultProfileID(for: initialTool) ?? "")
        _hasConfirmedManualReadType = State(initialValue: detectedReadType != nil)
    }

    private var availableMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }

    private var availableCores: Int {
        ProcessInfo.processInfo.processorCount
    }

    private var inputDisplayName: String {
        guard let first = inputFiles.first else { return "No FASTQ selected" }
        if inputFiles.count == 1 {
            return first.lungfishDisplayName
        }
        return "\(inputFiles.count) FASTQ files"
    }

    private var pairedEndInfo: (forward: [URL], reverse: [URL], unpaired: [URL]) {
        detectPairedEndFiles(inputFiles)
    }

    private var detectedReadTypes: [AssemblyReadType] {
        inputFiles.compactMap(AssemblyReadType.detect(fromInputURL:))
    }

    private var compatibilityEvaluation: AssemblyCompatibilityEvaluation {
        AssemblyCompatibility.evaluate(detectedReadTypes: detectedReadTypes)
    }

    private var hasKnownAndUnknownMix: Bool {
        !detectedReadTypes.isEmpty && detectedReadTypes.count < inputFiles.count
    }

    private var readTypeIsLockedToDetection: Bool {
        compatibilityEvaluation.resolvedReadType != nil && !hasKnownAndUnknownMix && !compatibilityEvaluation.isBlocked
    }

    private var effectiveReadType: AssemblyReadType {
        compatibilityEvaluation.resolvedReadType ?? selectedReadType
    }

    private var requiresManualReadTypeConfirmation: Bool {
        compatibilityEvaluation.resolvedReadType == nil
            && compatibilityBlockingMessage == nil
    }

    private var selectedToolStatus: PackToolStatus? {
        packStatus?.toolStatuses.first { $0.requirement.id == selectedTool.rawValue }
    }

    private var packReady: Bool {
        selectedToolStatus?.environmentExists == true
    }

    private var toolReady: Bool {
        selectedToolStatus?.isReady == true
    }

    private var supportsMemoryLimit: Bool {
        AssemblyOptionCatalog.capabilityScopedControls.contains {
            $0.id == "memory-limit" && $0.applies(to: selectedTool)
        }
    }

    private var supportsMinContigLength: Bool {
        AssemblyOptionCatalog.capabilityScopedControls.contains {
            $0.id == "minimum-contig-length" && $0.applies(to: selectedTool)
        }
    }

    private var profileOptions: [AssemblyProfileOption] {
        switch selectedTool {
        case .spades:
            return [
                AssemblyProfileOption(id: "isolate", title: "Isolate", detail: "Conservative short-read isolate assembly."),
                AssemblyProfileOption(id: "meta", title: "Meta", detail: "Metagenome assembly for mixed short-read data."),
                AssemblyProfileOption(id: "plasmid", title: "Plasmid", detail: "Plasmid-focused short-read assembly."),
            ]
        case .megahit:
            return [
                AssemblyProfileOption(id: "", title: "Default", detail: "Balanced short-read assembly."),
                AssemblyProfileOption(id: "meta-sensitive", title: "Meta Sensitive", detail: "Higher-sensitivity metagenome preset."),
                AssemblyProfileOption(id: "meta-large", title: "Meta Large", detail: "Preset for larger metagenome assemblies."),
            ]
        case .skesa:
            return []
        case .flye:
            return [
                AssemblyProfileOption(id: "nano-hq", title: "Nano HQ", detail: "High-quality ONT reads."),
                AssemblyProfileOption(id: "nano-raw", title: "Nano Raw", detail: "Raw ONT reads."),
                AssemblyProfileOption(id: "nano-corr", title: "Nano Corrected", detail: "Corrected ONT reads."),
            ]
        case .hifiasm:
            return []
        }
    }

    private var compatibilityBlockingMessage: String? {
        if let message = compatibilityEvaluation.blockingMessage {
            return message
        }
        if hasKnownAndUnknownMix {
            return Self.mixedDetectedAndUnclassifiedInputsMessage
        }
        return nil
    }

    private var readTopologyMessage: String? {
        switch effectiveReadType {
        case .illuminaShortReads:
            return nil
        case .ontReads, .pacBioHiFi:
            return inputFiles.count == 1
                ? nil
                : "\(effectiveReadType.displayName) assembly expects a single FASTQ input in v1."
        }
    }

    private var compatibilityPresentation: AssemblyCompatibilityPresentation {
        AssemblyCompatibilityPresentation(
            tool: selectedTool,
            readType: effectiveReadType,
            packReady: packReady,
            toolReady: toolReady,
            blockingMessage: compatibilityBlockingMessage ?? readTopologyMessage
        )
    }

    private var canRun: Bool {
        guard !inputFiles.isEmpty else { return false }
        guard outputDirectory != nil else { return false }
        guard !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !requiresManualReadTypeConfirmation || hasConfirmedManualReadType else { return false }
        return compatibilityPresentation.state == .ready
    }

    private var validationMessage: String? {
        if inputFiles.isEmpty {
            return "Select at least one FASTQ input."
        }
        if outputDirectory == nil {
            return "No output directory is available for this assembly."
        }
        if projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Project name is required."
        }
        if requiresManualReadTypeConfirmation && !hasConfirmedManualReadType {
            return "Choose a read type before running this assembly."
        }
        if compatibilityPresentation.state != .ready {
            return compatibilityPresentation.message
        }
        return nil
    }

    private var sectionPadding: CGFloat {
        embeddedInOperationsDialog ? 24 : 20
    }

    var body: some View {
        Group {
            if embeddedInOperationsDialog {
                embeddedBody
            } else {
                standaloneBody
            }
        }
        .frame(
            width: embeddedInOperationsDialog ? nil : 620,
            height: embeddedInOperationsDialog ? nil : 640
        )
        .task {
            threads = min(Double(availableCores), 8)
            memoryGB = min(Double(availableMemoryGB) * 0.75, 32)
            if let first = inputFiles.first {
                let stem = first.deletingPathExtension().lastPathComponent
                let cleaned = stem
                    .replacingOccurrences(of: "_R1", with: "")
                    .replacingOccurrences(of: "_R2", with: "")
                    .replacingOccurrences(of: "_1", with: "")
                    .replacingOccurrences(of: "_2", with: "")
                    .replacingOccurrences(of: ".lungfishfastq", with: "")
                projectName = cleaned + "_assembly"
            } else {
                projectName = "assembly"
            }

            packStatus = await PluginPackStatusService.shared.status(forPackID: "assembly")
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
        .onChange(of: selectedTool) { _, newValue in
            resetToolSpecificOptions()
            let nextProfileID = Self.defaultProfileID(for: newValue) ?? ""
            if !profileOptions.map(\.id).contains(selectedProfileID) {
                selectedProfileID = nextProfileID
            } else if profileOptions.isEmpty {
                selectedProfileID = nextProfileID
            }
            if requiresManualReadTypeConfirmation && !hasConfirmedManualReadType {
                selectedReadType = Self.defaultReadType(for: newValue)
            }
        }
        .onChange(of: selectedReadType) { _, _ in
            if !readTypeIsLockedToDetection {
                hasConfirmedManualReadType = true
            }
        }
    }

    private var standaloneBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            ScrollView {
                configurationContent
            }
            .accessibilityIdentifier("assembly-configuration-scrollview")
            Divider()
            footerSection
        }
    }

    private var embeddedBody: some View {
        ScrollView {
            configurationContent
        }
        .accessibilityIdentifier("assembly-configuration-scrollview")
    }

    private var configurationContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            inputSection
            Divider()
            primarySettingsSection
            Divider()
            advancedSettingsSection
            Divider()
            outputSection
            Divider()
            readinessSection
        }
        .padding(.horizontal, sectionPadding)
        .padding(.vertical, 16)
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Genome Assembly")
                    .font(.headline)
                Text("Managed assembly tools for FASTQ reads")
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
            }
            Spacer()
            Text(inputDisplayName)
                .font(.caption)
                .foregroundStyle(Color.lungfishSecondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, sectionPadding)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var footerSection: some View {
        HStack(spacing: 12) {
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishOrangeFallback)
                    .lineLimit(2)
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
        .padding(.horizontal, sectionPadding)
        .padding(.vertical, 12)
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Inputs")
            labeledRow("Dataset") {
                Text(inputDisplayName)
                    .font(.body)
            }
            labeledRow("Read Layout") {
                Text(readLayoutSummary)
                    .foregroundStyle(Color.lungfishSecondaryText)
            }
            labeledRow("Detected") {
                Text(detectedReadTypeSummary)
                    .foregroundStyle(Color.lungfishSecondaryText)
            }
        }
    }

    private var primarySettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Primary Settings")

            labeledRow("Assembler") {
                Picker("Assembler", selection: $selectedTool) {
                    ForEach(AssemblyTool.allCases, id: \.self) { tool in
                        Text(tool.displayName).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("assembly-assembler-picker")
            }
            optionSummary("assembler")

            labeledRow("Read Type") {
                if readTypeIsLockedToDetection {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(effectiveReadType.displayName)
                        Text("Locked from FASTQ header detection.")
                            .font(.caption)
                            .foregroundStyle(Color.lungfishSecondaryText)
                    }
                } else {
                    Picker("Read Type", selection: $selectedReadType) {
                        ForEach(AssemblyReadType.allCases, id: \.self) { readType in
                            Text(readType.displayName).tag(readType)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            optionSummary("read-type")

            if !profileOptions.isEmpty {
                labeledRow("Profile") {
                    Picker("Profile", selection: $selectedProfileID) {
                        ForEach(profileOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("assembly-profile-picker")
                }
                Text(profileOptions.first(where: { $0.id == selectedProfileID })?.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
                optionSummary("profile")
            }

            labeledRow("Threads") {
                HStack(spacing: 12) {
                    Slider(value: $threads, in: 1...Double(max(1, availableCores)), step: 1)
                    Text("\(Int(threads))")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 36, alignment: .trailing)
                }
            }
            optionSummary("threads")

            if supportsMemoryLimit {
                labeledRow("Memory Limit") {
                    HStack(spacing: 12) {
                        Slider(value: $memoryGB, in: 1...Double(max(1, availableMemoryGB)), step: 1)
                            .accessibilityIdentifier("assembly-memory-slider")
                        Text("\(Int(memoryGB)) GB")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 72, alignment: .trailing)
                    }
                }
                optionSummary("memory-limit")
            }

            if supportsMinContigLength {
                labeledRow("Min Contig") {
                    Stepper(value: $minContigLength, in: 0...1_000_000, step: 100) {
                        Text("\(minContigLength) bp")
                            .font(.system(.body, design: .monospaced))
                    }
                    .accessibilityIdentifier("assembly-min-contig-stepper")
                }
                .accessibilityIdentifier("assembly-min-contig-row")
                optionSummary("minimum-contig-length")
            }
        }
    }

    private var advancedSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Advanced Settings")

            DisclosureGroup("Curated advanced options", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedTool {
                    case .spades:
                        Toggle("Careful mode", isOn: $spadesCareful)
                            .accessibilityIdentifier("assembly-spades-careful-toggle")
                        Toggle("Skip error correction", isOn: $spadesSkipErrorCorrection)
                    case .flye:
                        Toggle("Metagenome mode", isOn: $flyeMetagenomeMode)
                            .accessibilityIdentifier("assembly-flye-metagenome-toggle")
                    case .hifiasm:
                        Toggle("Primary contigs only", isOn: $hifiasmPrimaryOnly)
                            .accessibilityIdentifier("assembly-hifiasm-primary-only-toggle")
                    case .megahit, .skesa:
                        EmptyView()
                    }

                    ForEach(AssemblyOptionCatalog.sections(for: selectedTool).advanced, id: \.id) { option in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .font(.subheadline.weight(.medium))
                            Text(option.summary)
                                .font(.caption)
                                .foregroundStyle(Color.lungfishSecondaryText)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Additional arguments")
                            .font(.subheadline.weight(.medium))
                        TextField("Enter tool-specific flags", text: $extraArgumentsText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Text("Use this only for flags not covered by the shared controls.")
                            .font(.caption)
                            .foregroundStyle(Color.lungfishSecondaryText)
                    }
                }
                .padding(.top, 8)
            }
            .accessibilityIdentifier("assembly-advanced-disclosure")
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Output")

            labeledRow("Project Name") {
                TextField("assembly", text: $projectName)
                    .textFieldStyle(.roundedBorder)
            }
            optionSummary("project-name")

            labeledRow("Output Folder") {
                Text(outputDirectory?.path ?? "No output directory")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(outputDirectory == nil ? Color.lungfishOrangeFallback : Color.lungfishSecondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            optionSummary("output-location")
        }
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Readiness")

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(compatibilityPresentation.fillStyle.fillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.lungfishStroke, lineWidth: 1)
                )
                .overlay(
                    VStack(alignment: .leading, spacing: 8) {
                        Text(compatibilityPresentation.message)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.primary)
                            .accessibilityIdentifier("assembly-readiness-message")

                        if let toolStatus = selectedToolStatus {
                            Text("Managed tool status: \(toolStatus.statusText)")
                                .font(.caption)
                                .foregroundStyle(Color.lungfishSecondaryText)
                            if let failure = toolStatus.smokeTestFailure {
                                Text(failure)
                                    .font(.caption)
                                    .foregroundStyle(Color.lungfishOrangeFallback)
                            }
                        } else {
                            Text("Managed tool status: checking Genome Assembly pack.")
                                .font(.caption)
                                .foregroundStyle(Color.lungfishSecondaryText)
                        }

                        if let failure = packStatus?.failureMessage {
                            Text(failure)
                                .font(.caption)
                                .foregroundStyle(Color.lungfishOrangeFallback)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                )
                .frame(maxWidth: .infinity)

            if let validationMessage, compatibilityPresentation.state == .ready {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishOrangeFallback)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.lungfishSecondaryText)
    }

    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            content()
        }
    }

    private func optionSummary(_ optionID: String) -> some View {
        let summary = optionSummaryText(for: optionID)
        return Group {
            if let summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
            }
        }
    }

    private func optionSummaryText(for optionID: String) -> String? {
        AssemblyOptionCatalog.sections(for: selectedTool)
            .shared
            .first(where: { $0.id == optionID })?.summary
        ?? AssemblyOptionCatalog.sections(for: selectedTool)
            .capabilityScoped
            .first(where: { $0.id == optionID })?.summary
    }

    private var detectedReadTypeSummary: String {
        if let blockingMessage = compatibilityBlockingMessage {
            return blockingMessage
        }
        if let detected = compatibilityEvaluation.resolvedReadType {
            return detected.displayName
        }
        return "No single read class detected. Choose one manually."
    }

    private var readLayoutSummary: String {
        if effectiveReadType != .illuminaShortReads {
            return "Single-input long-read assembly"
        }
        if pairedEndInfo.forward.count == 1,
           pairedEndInfo.reverse.count == 1,
           pairedEndInfo.unpaired.isEmpty {
            return "Paired-end Illumina reads"
        }
        return "Single-end or pre-grouped Illumina reads"
    }

    private func performRun() {
        guard canRun, let request = buildRequest() else { return }
        onRun?(request)
    }

    private func buildRequest() -> AssemblyRunRequest? {
        guard let outputDirectory else { return nil }

        let projectName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairedEnd =
            effectiveReadType == .illuminaShortReads
            && !pairedEndInfo.forward.isEmpty
            && pairedEndInfo.forward.count == pairedEndInfo.reverse.count
            && pairedEndInfo.unpaired.isEmpty

        return AssemblyRunRequest(
            tool: selectedTool,
            readType: effectiveReadType,
            inputURLs: inputFiles,
            projectName: projectName,
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: Int(threads),
            memoryGB: supportsMemoryLimit ? Int(memoryGB) : nil,
            minContigLength: supportsMinContigLength ? minContigLength : nil,
            selectedProfileID: selectedProfileID.isEmpty ? nil : selectedProfileID,
            extraArguments: curatedAdvancedArguments + parsedExtraArguments
        )
    }

    private var curatedAdvancedArguments: [String] {
        var arguments: [String] = []
        switch selectedTool {
        case .spades:
            if spadesCareful {
                arguments.append("--careful")
            }
            if spadesSkipErrorCorrection {
                arguments.append("--only-assembler")
            }
        case .flye:
            if flyeMetagenomeMode {
                arguments.append("--meta")
            }
        case .hifiasm:
            if hifiasmPrimaryOnly {
                arguments.append("--primary")
            }
        case .megahit, .skesa:
            break
        }
        return arguments
    }

    private var parsedExtraArguments: [String] {
        extraArgumentsText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

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

    private static func detectedReadType(from inputFiles: [URL]) -> AssemblyReadType? {
        AssemblyCompatibility.evaluate(
            detectedReadTypes: inputFiles.compactMap(AssemblyReadType.detect(fromInputURL:))
        ).resolvedReadType
    }

    private static func defaultProfileID(for tool: AssemblyTool) -> String? {
        switch tool {
        case .spades:
            return "isolate"
        case .megahit:
            return ""
        case .skesa:
            return nil
        case .flye:
            return "nano-hq"
        case .hifiasm:
            return nil
        }
    }

    private static func defaultReadType(for tool: AssemblyTool) -> AssemblyReadType {
        switch tool {
        case .spades, .megahit, .skesa:
            return .illuminaShortReads
        case .flye:
            return .ontReads
        case .hifiasm:
            return .pacBioHiFi
        }
    }

    private func resetToolSpecificOptions() {
        spadesCareful = false
        spadesSkipErrorCorrection = false
        flyeMetagenomeMode = false
        hifiasmPrimaryOnly = false
        extraArgumentsText = ""
    }
}

private struct AssemblyProfileOption: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}
