import AppKit
import SwiftUI
import LungfishWorkflow

@MainActor
final class NFCoreWorkflowDialogController: NSWindowController {
    init(
        projectURL: URL?,
        executionService: NFCoreWorkflowExecutionService = NFCoreWorkflowExecutionService()
    ) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "nf-core Workflows"
        panel.backgroundColor = .lungfishCanvasBackground
        panel.setAccessibilityIdentifier(NFCoreWorkflowAccessibilityID.window)
        panel.isReleasedWhenClosed = false

        super.init(window: panel)

        let view = NFCoreWorkflowDialogView(
            projectURL: projectURL,
            executionService: executionService,
            onCancel: { [weak panel] in panel?.close() },
            onStarted: { [weak panel] in panel?.close() }
        )
        panel.contentViewController = NSHostingController(rootView: view)
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct NFCoreWorkflowDialogView: View {
    @State private var model: NFCoreWorkflowDialogModel
    @State private var refreshToken = 0
    @State private var statusOverride: String?

    let executionService: NFCoreWorkflowExecutionService
    let onCancel: () -> Void
    let onStarted: () -> Void

    init(
        projectURL: URL?,
        executionService: NFCoreWorkflowExecutionService,
        onCancel: @escaping () -> Void,
        onStarted: @escaping () -> Void
    ) {
        _model = State(initialValue: NFCoreWorkflowDialogModel(projectURL: projectURL))
        self.executionService = executionService
        self.onCancel = onCancel
        self.onStarted = onStarted
    }

    var body: some View {
        let _ = refreshToken
        DatasetOperationsDialog(
            title: "nf-core Workflows",
            subtitle: "Guided biology workflows for project files",
            datasetLabel: datasetLabel,
            tools: sidebarItems,
            selectedToolID: model.selectedWorkflow?.name ?? "",
            statusText: statusText,
            isRunEnabled: canRun,
            primaryActionTitle: model.selectedWorkflowDetail.runButtonTitle,
            accessibilityNamespace: "nf-core",
            onSelectTool: selectWorkflow(_:),
            onCancel: onCancel,
            onRun: runWorkflow
        ) {
            detailPane
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    private var sidebarItems: [DatasetOperationToolSidebarItem] {
        model.availableWorkflows.map { workflow in
            DatasetOperationToolSidebarItem(
                id: workflow.name,
                title: workflow.displayName,
                subtitle: workflow.description,
                availability: .available
            )
        }
    }

    private var datasetLabel: String {
        guard let projectURL = model.projectURL else { return "No project selected" }
        return projectURL.lastPathComponent
    }

    private var statusText: String {
        if let statusOverride {
            return statusOverride
        }
        if model.inputCandidates.isEmpty {
            return "No supported project inputs found for \(model.selectedWorkflow?.displayName ?? "this workflow")."
        }
        let selectedCount = model.inputCandidates.filter { model.isInputSelected($0.url) }.count
        if selectedCount == 0 {
            return "\(model.inputCandidates.count) supported input(s) available. Select at least one to run."
        }
        return "\(selectedCount) of \(model.inputCandidates.count) supported input(s) selected."
    }

    private var canRun: Bool {
        model.inputCandidates.contains { model.isInputSelected($0.url) }
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                workflowSummarySection
                Divider()
                inputsSection
                Divider()
                outputSection
                Divider()
                readinessSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var workflowSummarySection: some View {
        section("Overview") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.selectedWorkflowDetail.title)
                    .font(.headline)
                    .accessibilityIdentifier(NFCoreWorkflowAccessibilityID.detailTitle)
                Text(model.selectedWorkflowDetail.overview)
                    .foregroundStyle(Color.lungfishSecondaryText)
                Text(model.selectedWorkflowDetail.whenToUse)
                    .foregroundStyle(Color.lungfishSecondaryText)
                    .accessibilityIdentifier(
                        model.selectedWorkflow?.name == "fetchngs"
                        ? NFCoreWorkflowAccessibilityID.fetchngsUsageText
                        : NFCoreWorkflowAccessibilityID.usageText
                    )
                if !model.selectedWorkflowDetail.notFor.isEmpty {
                    Text(model.selectedWorkflowDetail.notFor)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }
                if !model.selectedWorkflowDetail.exampleUseCase.isEmpty {
                    Text(model.selectedWorkflowDetail.exampleUseCase)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }
            }
        }
    }

    private var inputsSection: some View {
        section("Inputs") {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.selectedWorkflowDetail.requiredInputs)
                    .foregroundStyle(Color.lungfishSecondaryText)
                    .accessibilityIdentifier(NFCoreWorkflowAccessibilityID.requiredInputsText)

                HStack(spacing: 8) {
                    Button("Select All") {
                        model.selectAllInputs()
                        clearStatusAndRefresh()
                    }
                    .accessibilityIdentifier(NFCoreWorkflowAccessibilityID.selectAllButton)

                    Button("Clear") {
                        model.clearInputSelection()
                        clearStatusAndRefresh()
                    }
                    .accessibilityIdentifier(NFCoreWorkflowAccessibilityID.clearButton)
                }

                if model.inputCandidates.isEmpty {
                    Text("No matching project files were found.")
                        .foregroundStyle(Color.lungfishOrangeFallback)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.inputCandidates) { candidate in
                            Toggle(isOn: inputBinding(for: candidate.url)) {
                                Text(candidate.relativePath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("nf-core-input-row-\(candidate.relativePath)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(NFCoreWorkflowAccessibilityID.inputTable)
                }
            }
        }
    }

    private var outputSection: some View {
        section("You will get") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.selectedWorkflowDetail.expectedOutputs)
                    .foregroundStyle(Color.lungfishSecondaryText)
                    .accessibilityIdentifier(NFCoreWorkflowAccessibilityID.expectedOutputsText)
            }
        }
    }

    private var readinessSection: some View {
        section("Readiness") {
            Text(statusText)
                .font(.callout)
                .foregroundStyle(canRun ? Color.lungfishSecondaryText : Color.lungfishOrangeFallback)
                .accessibilityIdentifier(NFCoreWorkflowAccessibilityID.statusLabel)
        }
    }

    private func inputBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { model.isInputSelected(url) },
            set: {
                model.setInputSelected(url, selected: $0)
                clearStatusAndRefresh()
            }
        )
    }

    private func selectWorkflow(_ workflowID: String) {
        model.selectWorkflow(named: workflowID)
        clearStatusAndRefresh()
    }

    private func clearStatusAndRefresh() {
        statusOverride = nil
        refreshToken += 1
    }

    private func runWorkflow() {
        do {
            let request = try model.makeRequest()
            guard let bundleRoot = model.bundleRootURL else { return }
            statusOverride = "Starting \(request.workflow.fullName)..."
            refreshToken += 1
            Task { [executionService] in
                do {
                    _ = try await executionService.run(request, bundleRoot: bundleRoot)
                    AppUITestConfiguration.current.appendEvent("nfcore.workflow.completed \(request.workflow.fullName)")
                } catch {
                    AppUITestConfiguration.current.appendEvent("nfcore.workflow.failed \(request.workflow.fullName) error=\(error.localizedDescription)")
                }
            }
            onStarted()
        } catch NFCoreWorkflowDialogModel.ValidationError.missingInputs {
            statusOverride = "Select at least one project input."
            refreshToken += 1
        } catch {
            statusOverride = error.localizedDescription
            refreshToken += 1
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
