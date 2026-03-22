// AssemblyConfigurationView.swift - SPAdes assembly configuration sheet UI
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import os.log
import LungfishCore
import LungfishWorkflow

/// Logger for assembly configuration view operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "AssemblyConfigurationView")

// MARK: - AssemblyConfigurationView

/// SwiftUI view for configuring a SPAdes assembly run.
///
/// Input files and output directory are pre-set by the caller.
/// The user configures SPAdes mode, resources, and advanced options.
public struct AssemblyConfigurationView: View {
    @ObservedObject var viewModel: AssemblyConfigurationViewModel

    public init(viewModel: AssemblyConfigurationViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            Form {
                inputSummarySection
                modeSection
                resourceSection
                advancedSection
            }
            .formStyle(.grouped)

            Divider()
            footerSection
        }
        .frame(width: 550, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.checkRuntimeAvailability()
        }
    }

    // MARK: - Header Section

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Assemble with SPAdes")
                    .font(.headline)
                Text("De novo genome assembly")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            runtimeStatusIndicator

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

    // MARK: - Runtime Status Indicator

    @ViewBuilder
    private var runtimeStatusIndicator: some View {
        HStack(spacing: 4) {
            switch viewModel.runtimeStatus {
            case .checking:
                ProgressView()
                    .controlSize(.mini)
                Text("Checking...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .available:
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Runtime Available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable:
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Runtime Unavailable")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.trailing, 8)
    }

    // MARK: - Input Summary Section

    @ViewBuilder
    private var inputSummarySection: some View {
        Section("Input Files") {
            Text(viewModel.inputSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.inputFileURLs, id: \.self) { url in
                    Text(url.lastPathComponent)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Mode Section

    @ViewBuilder
    private var modeSection: some View {
        Section("Assembly Mode") {
            Picker("Mode:", selection: $viewModel.spadesMode) {
                ForEach(SPAdesMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Toggle("Perform error correction", isOn: $viewModel.performErrorCorrection)
                .toggleStyle(.checkbox)

            Toggle("Careful mode (mismatch correction)", isOn: $viewModel.careful)
                .toggleStyle(.checkbox)
                .disabled(viewModel.spadesMode == .isolate)
                .help("Reduces mismatches and short indels. Incompatible with --isolate mode.")

            if viewModel.careful && viewModel.spadesMode == .isolate {
                Text("--careful is incompatible with --isolate mode")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Resource Section

    @ViewBuilder
    private var resourceSection: some View {
        Section("Resources") {
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

                if viewModel.maxMemoryGB < 8 {
                    Text("SPAdes recommends at least 8 GB")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

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

    // MARK: - Advanced Section

    @ViewBuilder
    private var advancedSection: some View {
        Section("Advanced Options", isExpanded: $viewModel.isAdvancedExpanded) {
            // K-mer sizes
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

            // Coverage cutoff
            Picker("Coverage cutoff:", selection: $viewModel.covCutoff) {
                Text("Default").tag("")
                Text("Auto").tag("auto")
                Text("Off").tag("off")
            }
            .pickerStyle(.menu)
            .help("--cov-cutoff: coverage cutoff value for repeat resolution")

            // PHRED offset
            Picker("PHRED offset:", selection: $viewModel.phredOffset) {
                Text("Auto-detect").tag(0)
                Text("33 (Sanger/Illumina 1.8+)").tag(33)
                Text("64 (Illumina 1.3-1.7)").tag(64)
            }
            .pickerStyle(.menu)

            // Output options
            HStack {
                Text("Project name:")
                TextField("Name", text: $viewModel.projectName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }

            HStack {
                Text("Minimum contig length:")
                TextField("bp", value: $viewModel.minContigLength, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("bp")
                    .foregroundStyle(.secondary)
            }

            // Custom CLI args
            VStack(alignment: .leading, spacing: 4) {
                Text("Additional arguments:")
                TextField("e.g. --tmp-dir /fast/tmp", text: $viewModel.customArgsString)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Text("Extra flags passed verbatim to spades.py")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer Section

    @ViewBuilder
    private var footerSection: some View {
        HStack(spacing: 12) {
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

            Spacer()

            Button("Cancel") {
                viewModel.onCancel?()
                viewModel.onDismiss?()
            }
            .keyboardShortcut(.cancelAction)

            Button("Start Assembly") {
                viewModel.startAssembly()
                viewModel.onDismiss?()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canStartAssembly)
        }
        .padding(16)
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
