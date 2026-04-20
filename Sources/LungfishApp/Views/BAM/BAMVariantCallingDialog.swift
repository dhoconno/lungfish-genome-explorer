import SwiftUI
import Observation

struct BAMVariantCallingDialog: View {
    @Bindable var state: BAMVariantCallingDialogState
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        DatasetOperationsDialog(
            title: "CALL VARIANTS",
            subtitle: "Configure a viral variant caller for the selected alignment track.",
            datasetLabel: state.datasetLabel,
            tools: state.sidebarItems,
            selectedToolID: state.selectedCaller.rawValue,
            statusText: state.readinessText,
            isRunEnabled: state.isRunEnabled,
            onSelectTool: state.selectCaller(named:),
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
