import SwiftUI
import LungfishCore

struct GenBankGenomesSearchPane: View {
    @ObservedObject var viewModel: DatabaseBrowserViewModel

    var body: some View {
        DatabaseBrowserPane(
            viewModel: viewModel,
            title: "GenBank & Genomes",
            summary: "Search NCBI nucleotide, genome, and virus records."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Mode", selection: $viewModel.ncbiSearchType) {
                    Text("Nucleotide").tag(NCBISearchType.nucleotide)
                    Text("Genome").tag(NCBISearchType.genome)
                    Text("Virus").tag(NCBISearchType.virus)
                }
                .accessibilityIdentifier("database-search-ncbi-mode-picker")
                .pickerStyle(.segmented)

                if viewModel.ncbiSearchType == .virus || viewModel.ncbiSearchType == .nucleotide {
                    Toggle("RefSeq Only", isOn: $viewModel.refseqOnly)
                        .toggleStyle(.checkbox)
                }
            }
        }
    }
}
