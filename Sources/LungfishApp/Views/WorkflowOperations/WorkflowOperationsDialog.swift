import AppKit
import SwiftUI

struct WorkflowOperationsDialog: View {
    @Bindable var state: WorkflowOperationDialogState
    let onRun: (WorkflowOperationLaunchRequest) -> Void

    var body: some View {
        DatasetOperationsDialog(
            title: "Workflow Operations",
            subtitle: "Run enabled specialized and user workflows.",
            datasetLabel: state.datasetLabel,
            tools: state.sidebarItems,
            selectedToolID: state.selectedToolID,
            statusText: state.readinessText,
            isRunEnabled: state.isRunEnabled,
            accessibilityNamespace: "workflow-operations",
            onSelectTool: state.selectTool(_:),
            onCancel: { NSApp.keyWindow?.close() },
            onRun: runSelectedWorkflow
        ) {
            WorkflowOperationsDetailPane(state: state)
        }
        .alert(
            "Workflow Operation Error",
            isPresented: $state.showingError,
            presenting: state.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func runSelectedWorkflow() {
        do {
            onRun(try state.makeLaunchRequest())
        } catch {
            state.errorMessage = error.localizedDescription
            state.showingError = true
        }
    }
}

private struct WorkflowOperationsDetailPane: View {
    @Bindable var state: WorkflowOperationDialogState
    @State private var showingReferencePanel = false
    @State private var showingOutputPanel = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(DatasetOperationSection.overview.title) {
                    Text(state.selectedToolSummary)
                        .foregroundStyle(.secondary)
                }

                section(DatasetOperationSection.inputs.title) {
                    referencePicker
                    readPicker
                }

                section(DatasetOperationSection.primarySettings.title) {
                    primarySettings
                }

                section(DatasetOperationSection.advancedSettings.title) {
                    advancedSettings
                }

                section(DatasetOperationSection.output.title) {
                    outputPicker
                }

                section(DatasetOperationSection.readiness.title) {
                    Text(state.readinessText)
                        .font(.callout)
                        .foregroundStyle(state.isRunEnabled ? Color.lungfishSecondaryText : Color.lungfishOrangeFallback)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var referencePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference")
                .font(.subheadline.weight(.medium))
            if !state.projectReferenceCandidates.isEmpty {
                Picker("Project Reference", selection: referenceBinding) {
                    Text("Choose reference").tag(URL?.none)
                    ForEach(state.projectReferenceCandidates, id: \.self) { url in
                        Text(WorkflowOperationDialogState.displayPath(for: url, relativeTo: state.projectURL))
                            .tag(URL?.some(url))
                    }
                }
                .pickerStyle(.menu)
            }
            HStack(spacing: 10) {
                Text(state.selectedReferenceDisplay)
                    .font(.caption)
                    .foregroundStyle(state.selectedReferenceURL == nil ? Color.lungfishOrangeFallback : Color.lungfishSecondaryText)
                    .lineLimit(2)
                Spacer()
                Button(state.selectedReferenceURL == nil ? "Choose…" : "Replace…") {
                    browseForReference()
                }
                if state.selectedReferenceURL != nil {
                    Button("Clear") {
                        state.setReference(nil)
                    }
                }
            }
        }
    }

    private var readPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FASTQ Bundles")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                Text(state.selectedReadsDisplay)
                    .font(.caption)
                    .foregroundStyle(state.selectedReadURLs.isEmpty ? Color.lungfishOrangeFallback : Color.lungfishSecondaryText)
                    .lineLimit(3)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var primarySettings: some View {
        switch state.selectedTool?.kind {
        case .ontGenotyping:
            VStack(alignment: .leading, spacing: 10) {
                labeledTextField("Report Name", text: $state.outputName)
                HStack(spacing: 12) {
                    labeledCompactTextField("Threads", value: $state.threads)
                    labeledCompactTextField("Min Support", value: $state.minSupport)
                }
            }
        case .workflowPackage(let package):
            VStack(alignment: .leading, spacing: 8) {
                labeledTextField("Output Name", text: $state.outputName)
                labeledCompactTextField("Cores", value: $state.threads)
                Text("\(package.manifest.runner.kind.rawValue.capitalized) package, version \(package.manifest.version).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .none:
            Text("No runnable workflow selected.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var advancedSettings: some View {
        switch state.selectedTool?.kind {
        case .ontGenotyping:
            DisclosureGroup("Advanced Options", isExpanded: $state.advancedOptionsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    labeledTextField("minimap2 arguments", text: $state.extraArgumentsText)
                    Text("Arguments are passed to minimap2 after the fixed short-read preset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        case .workflowPackage(let package):
            VStack(alignment: .leading, spacing: 6) {
                Text("Inputs: \(package.manifest.inputs.map(\.name).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Outputs: \(package.manifest.outputs.map(\.pathTemplate).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Runtime: \(package.manifest.runtime.kind.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .none:
            EmptyView()
        }
    }

    private var outputPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Directory")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                Text(state.outputDirectoryDisplay)
                    .font(.caption)
                    .foregroundStyle(state.outputDirectoryURL == nil ? Color.lungfishOrangeFallback : Color.lungfishSecondaryText)
                    .lineLimit(2)
                Spacer()
                Button(state.outputDirectoryURL == nil ? "Choose…" : "Replace…") {
                    browseForOutputDirectory()
                }
            }
        }
    }

    private var referenceBinding: Binding<URL?> {
        Binding(
            get: { state.selectedReferenceURL },
            set: { state.setReference($0) }
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledTextField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    private func labeledCompactTextField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 96)
                .labelsHidden()
        }
    }

    private func browseForReference() {
        let panel = NSOpenPanel()
        panel.title = "Choose Reference"
        panel.message = "Select a .lungfishref bundle or FASTA file."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            state.setReference(panel.url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func browseForOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            state.setOutputDirectory(panel.url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
