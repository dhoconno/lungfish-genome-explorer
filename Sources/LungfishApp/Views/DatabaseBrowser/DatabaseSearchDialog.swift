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

    private var presentation: DatabaseSearchDialogPresentation {
        DatabaseSearchDialogPresentation(state: state)
    }

    var body: some View {
        DatasetOperationsDialog(
            title: presentation.title,
            subtitle: presentation.subtitle,
            datasetLabel: presentation.datasetLabel,
            tools: presentation.tools,
            selectedToolID: presentation.selectedToolID,
            statusText: presentation.statusText,
            isRunEnabled: presentation.isRunEnabled,
            primaryActionTitle: presentation.primaryActionTitle,
            accessibilityNamespace: presentation.accessibilityNamespace,
            onSelectTool: state.selectDestination(named:),
            onCancel: state.cancel,
            onRun: state.performPrimaryAction
        ) {
            detail()
        }
    }
}
