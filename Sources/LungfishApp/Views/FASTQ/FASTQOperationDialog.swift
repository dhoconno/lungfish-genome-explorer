import SwiftUI

enum FASTQOperationDialogRunPresentation {
    static func shouldRunAfterEmbeddedRequestCapture(
        selectedToolID: FASTQOperationToolID,
        hasPendingViralReconRequest: Bool
    ) -> Bool {
        selectedToolID == .viralRecon && hasPendingViralReconRequest
    }
}

struct FASTQOperationDialog: View {
    @Bindable var state: FASTQOperationDialogState
    let primaryActionTitle: String
    let onCancel: () -> Void
    let onRun: () -> Void

    init(
        state: FASTQOperationDialogState,
        primaryActionTitle: String = "Run",
        onCancel: @escaping () -> Void,
        onRun: @escaping () -> Void
    ) {
        self.state = state
        self.primaryActionTitle = primaryActionTitle
        self.onCancel = onCancel
        self.onRun = onRun
    }

    var body: some View {
        DatasetOperationsDialog(
            title: state.dialogTitle,
            subtitle: state.dialogSubtitle,
            datasetLabel: state.datasetLabel,
            tools: state.sidebarItems,
            selectedToolID: state.selectedToolID.rawValue,
            statusText: statusText,
            isRunEnabled: state.isRunEnabled,
            primaryActionTitle: primaryActionTitle,
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
            guard FASTQOperationDialogRunPresentation.shouldRunAfterEmbeddedRequestCapture(
                selectedToolID: state.selectedToolID,
                hasPendingViralReconRequest: request != nil
            ) else {
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
