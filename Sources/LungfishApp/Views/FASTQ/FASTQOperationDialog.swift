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
            accessibilityNamespace: state.selectedToolID.categoryID == .assembly
                ? "fastq-operations-assembly"
                : nil,
            onSelectTool: selectTool(named:),
            onCancel: onCancel,
            onRun: handleRun
        ) {
            FASTQOperationToolPanes(state: state)
        }
        .onChange(of: state.pendingLaunchRequest) { _, request in
            guard state.selectedToolID.usesEmbeddedConfiguration, request != nil else {
                return
            }

            onRun()
        }
    }

    private var subtitle: String {
        "Configure \(state.selectedToolID.title) for the selected FASTQ data."
    }

    private var statusText: String {
        state.readinessText
    }

    private func handleRun() {
        state.prepareForRun()

        guard !state.selectedToolID.usesEmbeddedConfiguration else {
            return
        }

        onRun()
    }

    private func selectTool(named rawValue: String) {
        guard let toolID = FASTQOperationToolID(rawValue: rawValue) else {
            return
        }

        state.selectTool(toolID)
    }
}
