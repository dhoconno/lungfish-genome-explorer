import SwiftUI

struct FASTQOperationDialog: View {
    @Bindable var state: FASTQOperationDialogState
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        DatasetOperationsDialog(
            title: state.dialogTitle,
            subtitle: state.dialogSubtitle,
            datasetLabel: state.datasetLabel,
            tools: state.sidebarItems,
            selectedToolID: state.selectedToolID.rawValue,
            statusText: statusText,
            isRunEnabled: state.isRunEnabled,
            accessibilityNamespace: accessibilityNamespace(),
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
        .onChange(of: state.pendingViralReconRequest) { _, request in
            guard state.selectedToolID == .viralRecon, request != nil else {
                return
            }

            onRun()
        }
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

    private func accessibilityNamespace() -> String? {
        if state.isFASTAInputMode {
            return "fasta-operations"
        }

        switch state.selectedToolID.categoryID {
        case .assembly:
            return "fastq-operations-assembly"
        case .mapping:
            return "fastq-operations-mapping"
        default:
            return nil
        }
    }
}
