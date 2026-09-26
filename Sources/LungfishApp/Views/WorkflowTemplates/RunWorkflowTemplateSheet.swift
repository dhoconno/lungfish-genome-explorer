// RunWorkflowTemplateSheet.swift - SwiftUI sheet that runs a workflow template on new FASTQ files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishKit
import LungfishWorkflow
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// State for ``RunWorkflowTemplateSheet``: the chosen template, inputs,
/// per-run values and the readiness check.
///
/// Readiness comes from ``AnalysisTemplateRunner`` preflight through the
/// service, so the sheet disables Run for exactly the reasons the CLI
/// refuses.
@MainActor
@Observable
final class RunWorkflowTemplateSheetModel {
    let entries: [AnalysisTemplateLibrary.Entry]
    let projectURL: URL

    var selectedEntryID: String? {
        didSet { if selectedEntryID != oldValue { inputs = []; sampleName = ""; scheduleCheck() } }
    }
    var inputs: [URL] = [] {
        didSet { if inputs != oldValue { scheduleCheck() } }
    }
    var sampleName: String = ""
    var threads: Int
    var allowDrift = false {
        didSet { if allowDrift != oldValue { scheduleCheck() } }
    }
    private(set) var report: AnalysisTemplatePreflightReport?
    private(set) var isChecking = false

    private let preflight: (AnalysisTemplateRunRequest) async -> AnalysisTemplatePreflightReport
    private var checkTask: Task<Void, Never>?

    init(
        entries: [AnalysisTemplateLibrary.Entry],
        projectURL: URL,
        preselectedEntryID: String? = nil,
        threads: Int = ProcessInfo.processInfo.activeProcessorCount,
        preflight: @escaping (AnalysisTemplateRunRequest) async -> AnalysisTemplatePreflightReport
    ) {
        self.entries = entries
        self.projectURL = projectURL
        self.threads = threads
        self.preflight = preflight
        let readable = entries.filter { $0.template != nil }
        self.selectedEntryID = preselectedEntryID ?? readable.first?.id
        scheduleCheck()
    }

    var selectedEntry: AnalysisTemplateLibrary.Entry? {
        entries.first { $0.id == selectedEntryID }
    }

    var selectedTemplate: AnalysisTemplate? {
        selectedEntry?.template
    }

    /// The bundle name the run will create.
    var resolvedSampleName: String {
        AnalysisTemplateRenderer.resolvedSampleName(inputs: inputs, sampleName: sampleName)
    }

    /// Problems the user must fix in this sheet before the run can start.
    var localIssues: [String] {
        guard let template = selectedTemplate else {
            return [selectedEntry?.loadError ?? "Choose a template."]
        }
        if inputs.isEmpty {
            return ["Choose \(template.input.summary.lowercased())."]
        }
        if inputs.count != template.input.fileCount {
            return ["This template expects \(template.input.fileCount) FASTQ file\(template.input.fileCount == 1 ? "" : "s") per run. \(inputs.count) chosen."]
        }
        return []
    }

    /// Everything that blocks Run, local checks first.
    var blockingIssues: [String] {
        localIssues + (report?.blockingIssues ?? [])
    }

    var warnings: [String] {
        report?.warnings ?? []
    }

    var canRun: Bool {
        selectedTemplate != nil && localIssues.isEmpty && report?.isRunnable == true && !isChecking
    }

    /// The footer status: the first blocking issue, or the ready line.
    var statusText: String? {
        if isChecking { return "Checking recipe and database…" }
        if let issue = blockingIssues.first { return issue }
        return nil
    }

    var runRequest: AnalysisTemplateRunRequest? {
        guard let entry = selectedEntry, let template = entry.template else { return nil }
        return AnalysisTemplateRunRequest(
            template: template,
            templateURL: entry.url,
            inputs: inputs,
            projectURL: projectURL,
            sampleName: sampleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : sampleName,
            threads: threads,
            allowDrift: allowDrift
        )
    }

    /// The Kraken2 output name the run will create, for the Output section.
    var expectedOutputs: [String] {
        guard let template = selectedTemplate else { return [] }
        var lines = ["Imports/\(resolvedSampleName).lungfishfastq"]
        if template.kraken2Step != nil {
            lines.append("Analyses/kraken2-<timestamp>")
        }
        return lines
    }

    private func scheduleCheck() {
        checkTask?.cancel()
        guard let request = runRequest else {
            report = nil
            return
        }
        isChecking = true
        let preflight = self.preflight
        checkTask = Task { [weak self] in
            let result = await preflight(request)
            guard !Task.isCancelled, let self else { return }
            self.report = result
            self.isChecking = false
        }
    }
}

// MARK: - Sheet

/// Runs a saved workflow template on new FASTQ files: the same steps with
/// the same settings. Results can differ if a tool or database version
/// differs from when the template was created.
struct RunWorkflowTemplateSheet: View {
    @Bindable var model: RunWorkflowTemplateSheetModel
    var onRun: ((AnalysisTemplateRunRequest) -> Void)?
    var onCancel: (() -> Void)?

    @State private var choosingFiles = false

    private static let fastqContentTypes: [UTType] = [
        UTType(filenameExtension: "gz") ?? .data,
        UTType(filenameExtension: "fastq") ?? .data,
        UTType(filenameExtension: "fq") ?? .data,
    ]

    var body: some View {
        ImportSheet(
            title: "Run Workflow Template",
            subtitle: "Repeat saved steps on new files.",
            accessoryText: "Project: \(model.projectURL.deletingPathExtension().lastPathComponent)",
            size: ImportSheetSize(width: 600, height: 620),
            statusText: model.statusText,
            statusColor: model.isChecking ? .secondary : .orange,
            isPrimaryEnabled: model.canRun,
            onCancel: { onCancel?() },
            onPrimary: {
                if let request = model.runRequest {
                    onRun?(request)
                }
            },
            icon: {
                Image(systemName: "play.square.stack")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
            },
            content: {
                VStack(alignment: .leading, spacing: 14) {
                    templateSection
                    if let template = model.selectedTemplate {
                        Divider()
                        inputSection(template)
                        Divider()
                        WorkflowTemplateStepList(template: template)
                        Divider()
                        resourceSection(template)
                        Divider()
                        outputSection
                        Divider()
                        readinessSection
                    } else if let loadError = model.selectedEntry?.loadError {
                        WorkflowTemplateWarningList(title: "This template cannot run", warnings: [loadError], color: .orange)
                    }
                }
            }
        )
        .fileImporter(
            isPresented: $choosingFiles,
            allowedContentTypes: Self.fastqContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.inputs = urls.map(\.standardizedFileURL).sorted { $0.path < $1.path }
            }
        }
        .accessibilityIdentifier(WorkflowTemplateAccessibilityID.runSheet)
    }

    // MARK: Sections

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Template")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if model.entries.isEmpty {
                Text("No templates yet. Select a finished Kraken2 result in the project sidebar, then choose Save as Workflow Template… from its shortcut menu.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(WorkflowTemplateAccessibilityID.runEmptyLibrary)
            } else {
                Picker("Template", selection: $model.selectedEntryID) {
                    ForEach(model.entries) { entry in
                        Text(entry.template == nil ? "\(entry.name) (cannot be read)" : entry.name)
                            .tag(Optional(entry.id))
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier(WorkflowTemplateAccessibilityID.runTemplatePicker)
            }
            if let template = model.selectedTemplate {
                Text("Created \(template.createdAt.formatted(date: .abbreviated, time: .shortened)) in \(template.origin.appVersion) from \(template.origin.sourceAnalysisRelativePath).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Results can differ if a tool or database version differs from when the template was created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func inputSection(_ template: AnalysisTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inputs")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(template.input.summary)
                    .font(.system(size: 12))
                Spacer()
                Button("Choose Files\u{2026}") { choosingFiles = true }
                    .font(.system(size: 12))
                    .accessibilityIdentifier(WorkflowTemplateAccessibilityID.runChooseFiles)
            }
            ForEach(model.inputs, id: \.path) { url in
                Text(url.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Text("Sample name")
                    .font(.system(size: 12))
                TextField(model.resolvedSampleName, text: $model.sampleName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(WorkflowTemplateAccessibilityID.runSampleNameField)
            }
        }
    }

    private func resourceSection(_ template: AnalysisTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fixed resources")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if let kraken2 = template.kraken2Step {
                HStack(spacing: 6) {
                    Image(systemName: resourceSymbol)
                        .foregroundStyle(resourceColor)
                        .font(.system(size: 12))
                    Text("Kraken2 database: \(kraken2.database.summary)")
                        .font(.system(size: 12))
                    Text(resourceStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(WorkflowTemplateAccessibilityID.runDatabaseStatus)
            }
            if let recipe = template.importStep?.recipe {
                Text("Import recipe: \(recipe.name) (saved copy checked against the installed recipe)")
                    .font(.system(size: 12))
            }
        }
    }

    private var resourceStatus: String {
        if model.isChecking { return "Checking…" }
        guard let report = model.report else { return "" }
        if report.blockingIssues.contains(where: { $0.contains("database") }) { return "Not ready" }
        if report.warnings.contains(where: { $0.contains("database") }) { return "Installed, differs from the template" }
        return "Installed"
    }

    private var resourceSymbol: String {
        if model.isChecking || model.report == nil { return "circle.dashed" }
        return model.report?.blockingIssues.contains(where: { $0.contains("database") }) == true
            ? "xmark.circle.fill"
            : "checkmark.circle.fill"
    }

    private var resourceColor: Color {
        if model.isChecking || model.report == nil { return .secondary }
        return model.report?.blockingIssues.contains(where: { $0.contains("database") }) == true ? .orange : .green
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Results go to the usual folders in this project:")
                .font(.system(size: 12))
            ForEach(model.expectedOutputs, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
            }
            HStack(spacing: 8) {
                Stepper("Threads: \(model.threads)", value: $model.threads, in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount))
                    .font(.system(size: 12))
                    .accessibilityIdentifier(WorkflowTemplateAccessibilityID.runThreadsStepper)
                Text("Set for this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Readiness")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if model.isChecking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking recipe and database…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if model.blockingIssues.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Ready to run 1 sample.")
                        .font(.system(size: 12))
                }
                .accessibilityIdentifier(WorkflowTemplateAccessibilityID.runReadyLabel)
            } else {
                WorkflowTemplateWarningList(title: "Not ready", warnings: model.blockingIssues, color: .orange)
                    .accessibilityIdentifier(WorkflowTemplateAccessibilityID.runBlockingIssues)
            }
            if !model.warnings.isEmpty {
                WorkflowTemplateWarningList(title: "Differences recorded with the run", warnings: model.warnings)
            }
            Toggle("Run even if the installed recipe or database differs from the template, and record the difference", isOn: $model.allowDrift)
                .font(.system(size: 12))
                .accessibilityIdentifier(WorkflowTemplateAccessibilityID.runAllowDriftToggle)
        }
    }
}
