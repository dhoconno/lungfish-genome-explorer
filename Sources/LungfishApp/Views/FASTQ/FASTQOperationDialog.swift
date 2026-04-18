import SwiftUI

struct FASTQOperationDialog: View {
    @Bindable var state: FASTQOperationDialogState
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        DatasetOperationsDialog(
            title: state.selectedCategory.title,
            subtitle: subtitle,
            datasetLabel: state.datasetLabel,
            tools: state.sidebarItems,
            selectedToolID: state.selectedToolID.rawValue,
            statusText: statusText,
            isRunEnabled: state.isRunEnabled,
            onSelectTool: selectTool(named:),
            onCancel: onCancel,
            onRun: onRun
        ) {
            placeholderDetail
        }
    }

    private var subtitle: String {
        "Configure \(state.selectedToolID.title) for the selected FASTQ data."
    }

    private var statusText: String {
        guard !state.selectedInputURLs.isEmpty else {
            return "Select at least one FASTQ dataset."
        }

        guard state.isRunEnabled else {
            return "Add the remaining required inputs before running."
        }

        if state.showsOutputStrategyPicker {
            return "Ready to configure output."
        } else {
            return "Batch output is fixed for this tool."
        }
    }

    @ViewBuilder
    private var placeholderDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.selectedToolID.title)
                .font(.title3.weight(.semibold))
            Text(state.selectedToolID.subtitle)
                .foregroundStyle(.secondary)
            Text("Detail pane placeholder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Required inputs: \(requiredInputSummary)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Output mode: \(state.outputMode.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var requiredInputSummary: String {
        state.requiredInputKinds
            .map { $0.rawValue }
            .joined(separator: ", ")
    }

    private func selectTool(named rawValue: String) {
        guard let toolID = FASTQOperationToolID(rawValue: rawValue) else {
            return
        }

        state.selectTool(toolID)
    }
}
