import SwiftUI
import LungfishCore

struct DatabaseBrowserPane<Accessory: View>: View {
    @ObservedObject var viewModel: DatabaseBrowserViewModel
    let title: String
    let summary: String
    @ViewBuilder let accessoryControls: () -> Accessory

    init(
        viewModel: DatabaseBrowserViewModel,
        title: String,
        summary: String,
        @ViewBuilder accessoryControls: @escaping () -> Accessory
    ) {
        self.viewModel = viewModel
        self.title = title
        self.summary = summary
        self.accessoryControls = accessoryControls
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            accessoryControls()
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.lungfishCardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.lungfishStroke, lineWidth: 1)
                )
            searchControls
            resultsSection
        }
        .padding(16)
        .background(Color.lungfishCanvasBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AppKitTextField(
                    text: $viewModel.searchText,
                    placeholder: searchPlaceholder,
                    onSubmit: {
                        viewModel.performSearch()
                    }
                )
                .frame(minWidth: 260)

                Button("Search") {
                    viewModel.performSearch()
                }
                .buttonStyle(.borderedProminent)
                .tint(.lungfishCreamsicleFallback)
                .disabled(!viewModel.isSearchTextValid || viewModel.isSearching || viewModel.isDownloading)
            }

            if viewModel.searchScope != .all {
                Text(viewModel.searchScope.helpText)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.lungfishCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.lungfishStroke, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Results")
                .font(.headline)

            if viewModel.isSearching || viewModel.isDownloading {
                ProgressView()
                Text(viewModel.statusMessage ?? "Working…")
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
            } else if viewModel.filteredResults.isEmpty {
                Text(emptyStateText)
                    .font(.callout)
                    .foregroundStyle(Color.lungfishSecondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(viewModel.filteredResults) { record in
                    DatabaseSearchResultRow(
                        record: record,
                        isSelected: viewModel.selectedRecords.contains(record),
                        onToggle: {
                            toggleSelection(for: record)
                        }
                    )
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.lungfishCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.lungfishStroke, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var searchPlaceholder: String {
        if viewModel.isPathoplexusSearch {
            return "Browse records or search by accession"
        }
        switch viewModel.searchScope {
        case .all:
            return "Search by accession, organism, or title"
        case .accession:
            return "Search by accession"
        case .organism:
            return "Search by organism"
        case .title:
            return "Search by title"
        case .bioProject:
            return "Search by BioProject"
        case .author:
            return "Search by author"
        }
    }

    private var emptyStateText: String {
        if viewModel.isPathoplexusSearch {
            if let organism = viewModel.pathoplexusOrganism {
                return "Browsing open \(organism.displayName) records. Enter a search term to narrow results further."
            }
            return "Choose an organism or enter a search term to browse Pathoplexus records."
        }
        if viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a search term to find records."
        }
        return "No results matched the current search."
    }

    private func toggleSelection(for record: SearchResultRecord) {
        if viewModel.selectedRecords.contains(record) {
            viewModel.selectedRecords.remove(record)
        } else {
            viewModel.selectedRecords.insert(record)
        }
    }
}

struct DatabaseSearchResultRow: View {
    let record: SearchResultRecord
    var isSelected: Bool
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.lungfishCreamsicleFallback : Color.lungfishSecondaryText)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(record.accession)
                            .font(.headline.monospaced())
                        if let sourceDatabase = record.sourceDatabase, !sourceDatabase.isEmpty {
                            Text(sourceDatabase)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.lungfishSecondaryText)
                        }
                        Spacer()
                        if let length = record.length {
                            Text("\(length) bp")
                                .font(.caption)
                                .foregroundStyle(Color.lungfishSecondaryText)
                        }
                    }

                    Text(record.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let organism = record.organism, !organism.isEmpty {
                        Text(organism)
                            .font(.caption)
                            .foregroundStyle(Color.lungfishSecondaryText)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
