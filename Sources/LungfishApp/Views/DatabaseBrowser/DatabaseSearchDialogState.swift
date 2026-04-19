import Foundation
import Observation
import LungfishCore

enum DatabaseSearchDestination: String, CaseIterable, Identifiable, Sendable {
    case genBankGenomes
    case sraRuns
    case pathoplexus

    var id: String { rawValue }

    init(databaseSource: DatabaseSource) {
        switch databaseSource {
        case .ncbi:
            self = .genBankGenomes
        case .ena:
            self = .sraRuns
        case .pathoplexus:
            self = .pathoplexus
        default:
            self = .genBankGenomes
        }
    }

    var title: String {
        switch self {
        case .genBankGenomes:
            return "GenBank & Genomes"
        case .sraRuns:
            return "SRA Runs"
        case .pathoplexus:
            return "Pathoplexus"
        }
    }

    var subtitle: String {
        switch self {
        case .genBankGenomes:
            return "Nucleotide, assembly, and virus records from NCBI"
        case .sraRuns:
            return "Sequencing runs and FASTQ availability"
        case .pathoplexus:
            return "Open pathogen records and surveillance metadata"
        }
    }
}

@MainActor
@Observable
final class DatabaseSearchDialogState {
    var selectedDestination: DatabaseSearchDestination

    let genBankGenomesViewModel = DatabaseBrowserViewModel(source: .ncbi)
    let sraRunsViewModel = DatabaseBrowserViewModel(source: .ena)
    let pathoplexusViewModel = DatabaseBrowserViewModel(source: .pathoplexus)

    init(initialDestination: DatabaseSearchDestination = .genBankGenomes) {
        self.selectedDestination = initialDestination
    }

    convenience init(selectedDestination: DatabaseSearchDestination = .genBankGenomes) {
        self.init(initialDestination: selectedDestination)
    }

    var dialogTitle: String {
        selectedDestination.title
    }

    var dialogSubtitle: String {
        selectedDestination.subtitle
    }

    var contextLabel: String {
        activeViewModel.source.displayName
    }

    var sidebarItems: [DatasetOperationToolSidebarItem] {
        DatabaseSearchDestination.allCases.map {
            DatasetOperationToolSidebarItem(
                id: $0.id,
                title: $0.title,
                subtitle: $0.subtitle,
                availability: .available
            )
        }
    }

    var selectedToolID: String {
        selectedDestination.id
    }

    var activeViewModel: DatabaseBrowserViewModel {
        switch selectedDestination {
        case .genBankGenomes:
            return genBankGenomesViewModel
        case .sraRuns:
            return sraRunsViewModel
        case .pathoplexus:
            return pathoplexusViewModel
        }
    }

    var primaryActionTitle: String {
        activeViewModel.selectedRecords.isEmpty ? "Search" : "Download Selected"
    }

    var isPrimaryActionEnabled: Bool {
        if activeViewModel.selectedRecords.isEmpty {
            return activeViewModel.isSearchTextValid && !activeViewModel.isSearching
        }
        return !activeViewModel.isDownloading
    }

    var statusText: String {
        if let errorMessage = activeViewModel.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if activeViewModel.isDownloading {
            return "Downloading..."
        }
        let selectionCount = activeViewModel.selectedRecords.count
        if selectionCount > 0 {
            return selectionCount == 1 ? "1 selected" : "\(selectionCount) selected"
        }
        if let statusMessage = activeViewModel.statusMessage {
            return statusMessage
        }
        return "Ready"
    }

    func selectDestination(_ destination: DatabaseSearchDestination) {
        selectedDestination = destination
    }

    func selectDestination(named name: String) {
        let normalizedName = Self.normalizedLookupKey(name)
        guard let destination = DatabaseSearchDestination.allCases.first(where: {
            Self.normalizedLookupKey($0.id) == normalizedName
            || Self.normalizedLookupKey($0.title) == normalizedName
            || Self.normalizedLookupKey($0.subtitle) == normalizedName
        }) else {
            return
        }
        selectedDestination = destination
    }

    func cancel() {
        activeViewModel.onCancel?()
    }

    func performPrimaryAction() {
        if activeViewModel.selectedRecords.isEmpty {
            activeViewModel.performSearch()
        } else {
            activeViewModel.performBatchDownload()
        }
    }

    func applyCallbacks(
        onCancel: @escaping () -> Void,
        onDownloadStarted: @escaping () -> Void
    ) {
        for viewModel in [genBankGenomesViewModel, sraRunsViewModel, pathoplexusViewModel] {
            viewModel.onCancel = onCancel
            viewModel.onDownloadStarted = onDownloadStarted
        }
    }

    private static func normalizedLookupKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: " ", with: "")
    }
}
