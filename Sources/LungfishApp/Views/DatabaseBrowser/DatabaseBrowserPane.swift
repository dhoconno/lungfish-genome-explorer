import AppKit
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
            accessoryCard
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
                .foregroundStyle(Color.lungfishSecondaryText)
        }
    }

    private var accessoryCard: some View {
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
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            primarySearchBar

            if !viewModel.autocompleteSuggestions.isEmpty {
                autocompleteSuggestions
            }

            if viewModel.searchScope != .all {
                searchScopeHelp
            }

            advancedSearchSection
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

    private var primarySearchBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Menu {
                ForEach(SearchScope.allCases) { scope in
                    Button(scope.rawValue) {
                        viewModel.searchScope = scope
                    }
                }
            } label: {
                Text(viewModel.searchScope.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.lungfishCanvasBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.lungfishStroke, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            AppKitTextField(
                text: $viewModel.searchText,
                placeholder: searchPlaceholder,
                onSubmit: {
                    viewModel.performSearch()
                }
            )
            .frame(minWidth: 260)

            if !viewModel.searchText.isEmpty {
                Button("Clear") {
                    viewModel.searchText = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.lungfishSecondaryText)
            }

            Button("Search") {
                viewModel.performSearch()
            }
            .buttonStyle(.borderedProminent)
            .tint(.lungfishCreamsicleFallback)
            .disabled(!viewModel.isSearchTextValid || viewModel.isSearching || viewModel.isDownloading)
        }
    }

    private var autocompleteSuggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(viewModel.autocompleteSuggestions, id: \.self) { suggestion in
                Button(suggestion) {
                    viewModel.searchText = suggestion
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if suggestion != viewModel.autocompleteSuggestions.last {
                    Divider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.lungfishCanvasBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.lungfishStroke, lineWidth: 1)
        )
    }

    private var searchScopeHelp: some View {
        HStack(spacing: 8) {
            Text(viewModel.searchScope.helpText)
                .font(.caption)
                .foregroundStyle(Color.lungfishSecondaryText)

            Spacer()

            Button("Search all fields instead") {
                viewModel.searchScope = .all
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.lungfishCreamsicleFallback)
        }
    }

    private var advancedSearchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Advanced Search Filters")
                    .font(.headline)

                if viewModel.hasActiveFilters {
                    Text("\(viewModel.activeFilterCount) active")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.lungfishCreamsicleFallback.opacity(0.18))
                        )
                }

                Spacer()

                if viewModel.hasActiveFilters {
                    Button("Clear") {
                        withAnimation {
                            viewModel.clearFilters()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
                }

                Button(viewModel.isAdvancedExpanded ? "Hide" : "Show") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.isAdvancedExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.lungfishCreamsicleFallback)
            }

            if viewModel.isAdvancedExpanded {
                currentFilterPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.lungfishCanvasBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.lungfishStroke, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var currentFilterPanel: some View {
        if viewModel.isPathoplexusSearch {
            pathoplexusFiltersGrid
        } else if viewModel.isSRASearch {
            sraFiltersGrid
        } else if viewModel.ncbiSearchType == .virus {
            virusFiltersGrid
        } else {
            advancedFiltersGrid
        }
    }

    private var virusFiltersGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                filterField("Host") {
                    TextField("e.g., Homo sapiens", text: $viewModel.virusHostFilter)
                        .textFieldStyle(.roundedBorder)
                }

                filterField("Geographic Location") {
                    TextField("e.g., USA, China", text: $viewModel.virusGeoLocationFilter)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 16) {
                filterField("Completeness") {
                    Picker("Completeness", selection: $viewModel.virusCompletenessFilter) {
                        ForEach(VirusCompletenessFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)
                }

                filterField("Released Since") {
                    TextField("YYYY-MM-DD", text: $viewModel.virusReleasedSinceFilter)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Toggle("Annotated Only", isOn: $viewModel.virusAnnotatedOnly)
                .toggleStyle(.checkbox)

            Text("Virus filters use the NCBI Datasets v2 API. Use RefSeq Only for curated reference sequences.")
                .font(.caption)
                .foregroundStyle(Color.lungfishSecondaryText)
        }
    }

    private var pathoplexusFiltersGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lungfish retrieves OPEN records only. Restricted sequences remain hidden.")
                .font(.caption)
                .foregroundStyle(Color.lungfishSecondaryText)

            HStack(spacing: 16) {
                filterField("Country") {
                    TextField("e.g., USA, Germany", text: $viewModel.pathoplexusCountryFilter)
                        .textFieldStyle(.roundedBorder)
                }

                filterField("Host") {
                    TextField("e.g., Homo sapiens", text: $viewModel.pathoplexusHostFilter)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 16) {
                filterField("Clade") {
                    TextField("e.g., IIb", text: $viewModel.pathoplexusCladeFilter)
                        .textFieldStyle(.roundedBorder)
                }

                filterField("Lineage") {
                    TextField("e.g., B.1", text: $viewModel.pathoplexusLineageFilter)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 16) {
                filterField("Nucleotide Mutations") {
                    TextField("e.g., C180T, A200G", text: $viewModel.pathoplexusNucMutationsFilter)
                        .textFieldStyle(.roundedBorder)
                }

                filterField("Amino Acid Mutations") {
                    TextField("e.g., GP:440G", text: $viewModel.pathoplexusAAMutationsFilter)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 16) {
                filterField("Collection Date") {
                    HStack(spacing: 8) {
                        TextField("From", text: $viewModel.pathoplexusDateFrom)
                            .textFieldStyle(.roundedBorder)
                        Text("to")
                            .foregroundStyle(Color.lungfishSecondaryText)
                        TextField("To", text: $viewModel.pathoplexusDateTo)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                filterField("Sequence Length") {
                    HStack(spacing: 8) {
                        TextField("Min", text: $viewModel.minLength)
                            .textFieldStyle(.roundedBorder)
                        Text("to")
                            .foregroundStyle(Color.lungfishSecondaryText)
                        TextField("Max", text: $viewModel.maxLength)
                            .textFieldStyle(.roundedBorder)
                        Text("bp")
                            .font(.caption)
                            .foregroundStyle(Color.lungfishSecondaryText)
                    }
                }
            }

            filterField("INSDC Source") {
                Picker("INSDC Source", selection: $viewModel.pathoplexusINSDCFilter) {
                    ForEach(PathoplexusINSDCFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }

            Text("Pathoplexus filters combine with AND logic across organism, provenance, and sequence attributes.")
                .font(.caption)
                .foregroundStyle(Color.lungfishSecondaryText)
        }
    }

    private var advancedFiltersGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                filterField("Organism") {
                    TextField("e.g., Ebolavirus", text: $viewModel.organismFilter)
                        .textFieldStyle(.roundedBorder)
                }

                filterField("Location") {
                    TextField("e.g., Africa", text: $viewModel.locationFilter)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 16) {
                filterField("Gene") {
                    TextField("e.g., S", text: $viewModel.geneFilter)
                        .textFieldStyle(.roundedBorder)
                }

                filterField("Author") {
                    TextField("e.g., Wu F", text: $viewModel.authorFilter)
                        .textFieldStyle(.roundedBorder)
                }

                filterField("Journal") {
                    TextField("e.g., Nature", text: $viewModel.journalFilter)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 16) {
                filterField("Molecule Type") {
                    Picker("Molecule Type", selection: $viewModel.moleculeType) {
                        ForEach(MoleculeTypeFilter.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                }

                filterField("Sequence Length") {
                    HStack(spacing: 8) {
                        TextField("Min", text: $viewModel.minLength)
                            .textFieldStyle(.roundedBorder)
                        Text("to")
                            .foregroundStyle(Color.lungfishSecondaryText)
                        TextField("Max", text: $viewModel.maxLength)
                            .textFieldStyle(.roundedBorder)
                        Text("bp")
                            .font(.caption)
                            .foregroundStyle(Color.lungfishSecondaryText)
                    }
                }
            }

            filterField("Publication Date") {
                HStack(spacing: 8) {
                    TextField("From", text: $viewModel.pubDateFrom)
                        .textFieldStyle(.roundedBorder)
                    Text("to")
                        .foregroundStyle(Color.lungfishSecondaryText)
                    TextField("To", text: $viewModel.pubDateTo)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Sequence Properties")
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)

                HStack(spacing: 12) {
                    ForEach(SequencePropertyFilter.allCases) { property in
                        Toggle(isOn: Binding(
                            get: { viewModel.propertyFilters.contains(property) },
                            set: { selected in
                                if selected {
                                    viewModel.propertyFilters.insert(property)
                                } else {
                                    viewModel.propertyFilters.remove(property)
                                }
                            }
                        )) {
                            Text(property.rawValue)
                                .font(.caption)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            Text("Advanced filters combine with AND logic across the selected search scope.")
                .font(.caption)
                .foregroundStyle(Color.lungfishSecondaryText)
        }
    }

    private var sraFiltersGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                filterField("Platform") {
                    Picker("Platform", selection: $viewModel.sraPlatformFilter) {
                        ForEach(SRAPlatformFilter.allCases) { platform in
                            Text(platform.rawValue).tag(platform)
                        }
                    }
                    .pickerStyle(.menu)
                }

                filterField("Strategy") {
                    Picker("Strategy", selection: $viewModel.sraStrategyFilter) {
                        ForEach(SRAStrategyFilter.allCases) { strategy in
                            Text(strategy.rawValue).tag(strategy)
                        }
                    }
                    .pickerStyle(.menu)
                }

                filterField("Layout") {
                    Picker("Layout", selection: $viewModel.sraLayoutFilter) {
                        ForEach(SRALayoutFilter.allCases) { layout in
                            Text(layout.rawValue).tag(layout)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            HStack(spacing: 16) {
                filterField("Min Size (Mbases)") {
                    TextField("e.g., 10", text: $viewModel.sraMinMbases)
                        .textFieldStyle(.roundedBorder)
                }

                filterField("Publication Date") {
                    HStack(spacing: 8) {
                        TextField("From", text: $viewModel.sraPubDateFrom)
                            .textFieldStyle(.roundedBorder)
                        Text("to")
                            .foregroundStyle(Color.lungfishSecondaryText)
                        TextField("To", text: $viewModel.sraPubDateTo)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                filterField("Max Results") {
                    Picker("Max Results", selection: $viewModel.sraResultLimit) {
                        Text("50").tag(50)
                        Text("100").tag(100)
                        Text("200").tag(200)
                        Text("500").tag(500)
                        Text("1000").tag(1000)
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Results")
                    .font(.headline)

                Spacer()

                if !viewModel.selectedRecords.isEmpty {
                    Text("\(viewModel.selectedRecords.count) selected")
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                } else if !viewModel.results.isEmpty {
                    Text("\(viewModel.results.count) results")
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }
            }

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
        viewModel.selectedRecord = viewModel.selectedRecords.first
    }

    private func filterField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.lungfishSecondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

@MainActor
struct AppKitTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.sendsActionOnEndEditing = false
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.textFieldAction(_:))
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AppKitTextField

        init(_ parent: AppKitTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        @objc func textFieldAction(_ sender: NSTextField) {
            parent.onSubmit?()
        }
    }
}
