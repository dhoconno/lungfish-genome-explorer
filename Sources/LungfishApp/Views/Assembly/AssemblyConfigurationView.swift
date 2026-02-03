// AssemblyConfigurationView.swift - Assembly configuration sheet UI
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead (Role 02)
// Reference: Apple Human Interface Guidelines

import SwiftUI
import UniformTypeIdentifiers
import os.log

/// Logger for assembly configuration view operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "AssemblyConfigurationView")

// MARK: - AssemblyConfigurationView

/// Main SwiftUI view for configuring sequence assembly.
///
/// Provides a comprehensive interface for:
/// - Algorithm selection (SPAdes, MEGAHIT, auto)
/// - Input file management with drag-and-drop
/// - Output location selection
/// - Resource configuration (memory, threads)
/// - K-mer options for advanced users
/// - Real-time progress and log output during assembly
public struct AssemblyConfigurationView: View {
    @ObservedObject var viewModel: AssemblyConfigurationViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: AssemblyConfigurationViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Main content (scrollable)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if viewModel.assemblyState.isInProgress ||
                       viewModel.assemblyState == .completed(outputPath: "") ||
                       viewModel.assemblyState == .failed(error: "") {
                        progressSection
                    } else {
                        algorithmSection
                        inputFilesSection
                        outputSection
                        resourceSection
                        advancedSection
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer with buttons
            footerSection
        }
        .frame(width: 650, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header Section

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Sequence Assembly")
                    .font(.headline)
                Text("Configure de novo assembly using SPAdes or MEGAHIT")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Preset menu
            Menu {
                Button("Bacterial Isolate") {
                    viewModel.applyBacterialIsolatePreset()
                }
                Button("Metagenome") {
                    viewModel.applyMetagenomePreset()
                }
                Button("Viral") {
                    viewModel.applyViralPreset()
                }
            } label: {
                Label("Presets", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .disabled(viewModel.assemblyState.isInProgress)
        }
        .padding(16)
    }

    // MARK: - Algorithm Section

    @ViewBuilder
    private var algorithmSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Assembly Algorithm", systemImage: "cpu")
                .font(.headline)

            Picker("Algorithm", selection: $viewModel.algorithm) {
                ForEach(AssemblyAlgorithm.allCases) { algo in
                    HStack {
                        Image(systemName: algo.icon)
                        Text(algo.rawValue)
                    }
                    .tag(algo)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(viewModel.algorithm.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Input Files Section

    @ViewBuilder
    private var inputFilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Input Files", systemImage: "doc.on.doc")
                    .font(.headline)

                Spacer()

                Button {
                    openFilePicker()
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                if !viewModel.inputFiles.isEmpty {
                    Button {
                        viewModel.clearInputFiles()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            // File drop zone / list
            if viewModel.inputFiles.isEmpty {
                FileDropZone(onDrop: handleFileDrop)
            } else {
                inputFileList
            }

            // Paired-end toggle
            if !viewModel.inputFiles.isEmpty {
                Toggle("Paired-end reads", isOn: $viewModel.pairedEndMode)
                    .toggleStyle(.checkbox)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var inputFileList: some View {
        VStack(spacing: 1) {
            ForEach(viewModel.inputFiles) { file in
                HStack(spacing: 12) {
                    Image(systemName: file.pairedWith != nil ? "link" : "doc")
                        .foregroundStyle(file.pairedWith != nil ? .blue : .secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.filename)
                            .font(.callout)
                            .lineLimit(1)
                        Text(file.fileSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        viewModel.removeInputFile(file)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .frame(maxHeight: 150)
    }

    // MARK: - Output Section

    @ViewBuilder
    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Output", systemImage: "folder")
                .font(.headline)

            HStack {
                TextField("Project name", text: $viewModel.projectName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Spacer()

                Button {
                    openOutputDirectoryPicker()
                } label: {
                    Label("Choose Location", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(viewModel.fullOutputPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Resource Section

    @ViewBuilder
    private var resourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Resources", systemImage: "memorychip")
                .font(.headline)

            VStack(spacing: 16) {
                // Memory slider
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Memory")
                        Spacer()
                        Text("\(Int(viewModel.maxMemoryGB)) GB")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Text("1")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Slider(
                            value: $viewModel.maxMemoryGB,
                            in: 1...Double(viewModel.availableMemoryGB),
                            step: 1
                        )

                        Text("\(viewModel.availableMemoryGB)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if Int(viewModel.maxMemoryGB) < viewModel.algorithm.recommendedMemoryGB {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Recommended: \(viewModel.algorithm.recommendedMemoryGB) GB for \(viewModel.algorithm.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                // Thread slider
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Threads")
                        Spacer()
                        Text("\(Int(viewModel.maxThreads))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Text("1")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Slider(
                            value: $viewModel.maxThreads,
                            in: 1...Double(viewModel.availableCores),
                            step: 1
                        )

                        Text("\(viewModel.availableCores)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Advanced Section

    @ViewBuilder
    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $viewModel.isAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                // K-mer configuration
                VStack(alignment: .leading, spacing: 8) {
                    Text("K-mer Sizes")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Toggle("Auto-select k-mer sizes", isOn: $viewModel.kmerConfig.autoSelect)
                        .toggleStyle(.checkbox)

                    if !viewModel.kmerConfig.autoSelect {
                        HStack {
                            TextField("K-mer sizes (comma-separated)", text: $viewModel.customKmerString)
                                .textFieldStyle(.roundedBorder)

                            Button("Reset") {
                                viewModel.customKmerString = "21,33,55,77,99,127"
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text("Enter odd numbers between 11 and 127, separated by commas")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // SPAdes-specific options
                if viewModel.algorithm == .spades || viewModel.algorithm == .auto {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SPAdes Options")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Toggle("Perform error correction", isOn: $viewModel.performErrorCorrection)
                            .toggleStyle(.checkbox)

                        Toggle("Careful mode (mismatch correction)", isOn: $viewModel.carefulMode)
                            .toggleStyle(.checkbox)
                    }

                    Divider()
                }

                // Output options
                VStack(alignment: .leading, spacing: 8) {
                    Text("Output Options")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack {
                        Text("Minimum contig length:")
                        TextField("bp", value: $viewModel.minContigLength, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("bp")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            Label("Advanced Options", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Progress Section

    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Status header
            HStack(spacing: 12) {
                progressIcon
                    .font(.system(size: 24))

                VStack(alignment: .leading, spacing: 2) {
                    Text(progressTitle)
                        .font(.headline)
                    Text(viewModel.assemblyState.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.assemblyState.isInProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            // Progress bar
            if case .running(let progress, _) = viewModel.assemblyState {
                if let progress = progress {
                    ProgressView(value: progress, total: 1.0) {
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }

            // Log output
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Output Log")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Button {
                        copyLogToClipboard()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(viewModel.logOutput) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(entry.formattedTimestamp)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 70, alignment: .leading)

                                    Image(systemName: entry.level.icon)
                                        .font(.caption)
                                        .foregroundStyle(entry.level.color)
                                        .frame(width: 16)

                                    Text(entry.message)
                                        .font(.system(.callout, design: .monospaced))
                                        .foregroundStyle(entry.level.color)
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .frame(height: 200)
                    .onChange(of: viewModel.logOutput.count) { _, _ in
                        if let lastEntry = viewModel.logOutput.last {
                            withAnimation {
                                proxy.scrollTo(lastEntry.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var progressIcon: some View {
        Group {
            switch viewModel.assemblyState {
            case .idle, .validating, .preparing, .running:
                Image(systemName: "gearshape.2")
                    .foregroundStyle(.blue)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .cancelled:
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var progressTitle: String {
        switch viewModel.assemblyState {
        case .idle:
            return "Ready"
        case .validating:
            return "Validating"
        case .preparing:
            return "Preparing"
        case .running:
            return "Running Assembly"
        case .completed:
            return "Assembly Complete"
        case .failed:
            return "Assembly Failed"
        case .cancelled:
            return "Assembly Cancelled"
        }
    }

    // MARK: - Footer Section

    @ViewBuilder
    private var footerSection: some View {
        HStack(spacing: 12) {
            // Validation status
            if !viewModel.assemblyState.isInProgress {
                let validation = viewModel.validateConfiguration()
                if !validation.errors.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(validation.errors.first ?? "")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                } else if !validation.warnings.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(validation.warnings.first ?? "")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Action buttons
            if viewModel.assemblyState.isInProgress {
                Button("Cancel") {
                    viewModel.cancelAssembly()
                }
                .buttonStyle(.bordered)
            } else if case .completed = viewModel.assemblyState {
                Button("Open Output") {
                    openOutputFolder()
                }
                .buttonStyle(.bordered)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else if case .failed = viewModel.assemblyState {
                Button("Try Again") {
                    viewModel.assemblyState = .idle
                }
                .buttonStyle(.bordered)

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Cancel") {
                    viewModel.onCancel?()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Start Assembly") {
                    viewModel.startAssembly()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canStartAssembly)
            }
        }
        .padding(16)
    }

    // MARK: - Actions

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "fq")!,
            UTType(filenameExtension: "fastq")!,
            UTType(filenameExtension: "gz")!,
        ]
        panel.message = "Select FASTQ files for assembly"

        panel.begin { response in
            if response == .OK {
                viewModel.addInputFiles(panel.urls)
            }
        }
    }

    private func openOutputDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose output directory"

        if let currentDir = viewModel.outputDirectory {
            panel.directoryURL = currentDir
        }

        panel.begin { response in
            if response == .OK, let url = panel.url {
                viewModel.outputDirectory = url
            }
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let semaphore = DispatchSemaphore(value: 0)
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    if let urlData = data as? Data,
                       let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                        urls.append(url)
                    }
                    semaphore.signal()
                }
                semaphore.wait()
            }
        }

        if !urls.isEmpty {
            viewModel.addInputFiles(urls)
            return true
        }
        return false
    }

    private func copyLogToClipboard() {
        let logText = viewModel.logOutput.map { entry in
            "[\(entry.formattedTimestamp)] [\(entry.level.rawValue.uppercased())] \(entry.message)"
        }.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }

    private func openOutputFolder() {
        guard let outputDir = viewModel.outputDirectory else { return }
        let outputPath = outputDir.appendingPathComponent(viewModel.projectName)
        NSWorkspace.shared.open(outputPath)
    }
}

// MARK: - FileDropZone

/// A drop zone for dragging and dropping FASTQ files.
struct FileDropZone: View {
    let onDrop: ([NSItemProvider]) -> Bool
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 36))
                .foregroundStyle(isTargeted ? .blue : .secondary)

            Text("Drop FASTQ files here")
                .font(.headline)
                .foregroundStyle(isTargeted ? .primary : .secondary)

            Text("or click \"Add Files\" to browse")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .foregroundStyle(isTargeted ? .blue : Color(nsColor: .separatorColor))
        )
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTargeted ? Color.blue.opacity(0.05) : Color.clear)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            onDrop(providers)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct AssemblyConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        AssemblyConfigurationView(viewModel: AssemblyConfigurationViewModel())
    }
}
#endif
