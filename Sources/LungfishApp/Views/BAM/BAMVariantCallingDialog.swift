import SwiftUI
import Observation

struct BAMVariantCallingDialog: View {
    @Bindable var state: BAMVariantCallingDialogState
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        DatasetOperationsDialog(
            title: "CALL VARIANTS",
            subtitle: "Configure a variant caller for the selected alignment track.",
            datasetLabel: state.datasetLabel,
            tools: state.sidebarItems,
            selectedToolID: state.selectedToolID,
            statusText: state.readinessText,
            isRunEnabled: state.isRunEnabled,
            onSelectTool: state.selectTool(named:),
            onCancel: onCancel,
            onRun: handleRun
        ) {
            BAMVariantCallingToolPanes(state: state)
        }
    }

    private func handleRun() {
        state.prepareForRun()
        onRun()
    }
}
