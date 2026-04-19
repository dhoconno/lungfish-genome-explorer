import Observation
import SwiftUI
import LungfishCore

struct DatabaseSearchDialog: View {
    @Bindable var state: DatabaseSearchDialogState

    var body: some View {
        shell
    }

    @ViewBuilder
    private var shell: some View {
        switch state.selectedDestination {
        case .genBankGenomes:
            DatabaseSearchDialogShell(state: state, viewModel: state.genBankGenomesViewModel) {
                GenBankGenomesSearchPane(viewModel: state.genBankGenomesViewModel)
            }
        case .sraRuns:
            DatabaseSearchDialogShell(state: state, viewModel: state.sraRunsViewModel) {
                SRARunsSearchPane(viewModel: state.sraRunsViewModel)
            }
        case .pathoplexus:
            DatabaseSearchDialogShell(state: state, viewModel: state.pathoplexusViewModel) {
                PathoplexusSearchPane(viewModel: state.pathoplexusViewModel)
            }
        }
    }
}

private struct DatabaseSearchDialogShell<Detail: View>: View {
    @Bindable var state: DatabaseSearchDialogState
    @ObservedObject var viewModel: DatabaseBrowserViewModel
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        DatasetOperationsDialog(
            title: state.dialogTitle,
            subtitle: state.dialogSubtitle,
            datasetLabel: state.contextLabel,
            tools: state.sidebarItems,
            selectedToolID: state.selectedToolID,
            statusText: statusText,
            isRunEnabled: isPrimaryActionEnabled,
            primaryActionTitle: primaryActionTitle,
            onSelectTool: state.selectDestination(named:),
            onCancel: state.cancel,
            onRun: state.performPrimaryAction
        ) {
            detail()
        }
    }

    private var primaryActionTitle: String {
        viewModel.selectedRecords.isEmpty ? "Search" : "Download Selected"
    }

    private var isPrimaryActionEnabled: Bool {
        guard !viewModel.isShowingPathoplexusConsent else {
            return false
        }

        if viewModel.selectedRecords.isEmpty {
            return viewModel.isSearchTextValid && !viewModel.isSearching && !viewModel.isDownloading
        }

        return !viewModel.isDownloading && !viewModel.isSearching
    }

    private var statusText: String {
        if viewModel.isShowingPathoplexusConsent {
            return "Review the Pathoplexus access notice to continue."
        }
        if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if viewModel.isDownloading {
            return "Downloading..."
        }
        let selectionCount = viewModel.selectedRecords.count
        if selectionCount > 0 {
            return selectionCount == 1 ? "1 selected" : "\(selectionCount) selected"
        }
        if let statusMessage = viewModel.statusMessage {
            return statusMessage
        }
        return "Ready"
    }
}
