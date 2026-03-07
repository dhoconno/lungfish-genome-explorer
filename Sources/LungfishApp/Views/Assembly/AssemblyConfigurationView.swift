// AssemblyConfigurationView.swift - SPAdes assembly configuration sheet UI
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import os.log
import LungfishWorkflow

/// Logger for assembly configuration view operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "AssemblyConfigurationView")

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

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    inputSummarySection
                    modeSection
                    resourceSection
                    advancedSection
                }
                .padding(20)
            }

            Divider()
            footerSection
        }
        .frame(width: 550, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.checkRuntimeAvailability()
        }
    }

    // MARK: - Header Section

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 28))
                .foregroundStyle(.tint)

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
        VStack(alignment: .leading, spacing: 8) {
            Label("Input Files", systemImage: "doc.on.doc")
                .font(.headline)

            Text(viewModel.inputSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            // List file names
            VStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.inputFileURLs, id: \.self) { url in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Mode Section

    @ViewBuilder
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Assembly Mode", systemImage: "gearshape.2")
                .font(.headline)

            Picker("Mode:", selection: $viewModel.spadesMode) {
                ForEach(SPAdesMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Toggle("Perform error correction", isOn: $viewModel.performErrorCorrection)
                .toggleStyle(.checkbox)
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
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("SPAdes recommends at least 8 GB")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
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
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Advanced Section

    @ViewBuilder
    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $viewModel.isAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 16) {
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Output Options")
                        .font(.subheadline)
                        .fontWeight(.medium)

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
