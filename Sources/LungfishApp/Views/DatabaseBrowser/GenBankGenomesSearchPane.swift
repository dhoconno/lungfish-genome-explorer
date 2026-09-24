import SwiftUI
import LungfishCore

struct GenBankGenomesPanePresentation: Equatable {
    let modePickerAccessibilityID = "database-search-ncbi-mode-picker"
    let modeTitles = ["Nucleotide", "Genome", "Virus"]
    let filterTitles = ["RefSeq Only", "Include GFF3 Annotations"]
    let includeGFF3AnnotationsAccessibilityID = "database-search-include-gff3-annotations"
}

struct GenBankGenomesSearchPane: View {
    @ObservedObject var viewModel: DatabaseBrowserViewModel
    private let presentation = GenBankGenomesPanePresentation()

    var body: some View {
        DatabaseBrowserPane(
            viewModel: viewModel,
            title: "GenBank & Genomes",
            summary: "Search NCBI nucleotide, genome, and virus records."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.ncbiSearchType == .nucleotide {
                    HStack(spacing: 12) {
                        Button("Import Accessions") {
                            viewModel.importAccessionList()
                        }
                        .disabled(viewModel.isSearching || viewModel.isDownloading)
                        .accessibilityIdentifier("database-search-genbank-import-accessions")
                        Text("Use CSV, TSV, or plain text nucleotide accession lists. Versions are preserved; search filters do not apply to imported lists.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Mode", selection: $viewModel.ncbiSearchType) {
                    Text(presentation.modeTitles[0]).tag(NCBISearchType.nucleotide)
                    Text(presentation.modeTitles[1]).tag(NCBISearchType.genome)
                    Text(presentation.modeTitles[2]).tag(NCBISearchType.virus)
                }
                .accessibilityIdentifier(presentation.modePickerAccessibilityID)
                .pickerStyle(.segmented)

                if viewModel.ncbiSearchType == .virus || viewModel.ncbiSearchType == .nucleotide {
                    Toggle(presentation.filterTitles[0], isOn: $viewModel.refseqOnly)
                        .toggleStyle(.checkbox)
                }

                if viewModel.ncbiSearchType == .virus || viewModel.ncbiSearchType == .nucleotide {
                    Toggle(presentation.filterTitles[1], isOn: $viewModel.includeGFF3Annotations)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier(presentation.includeGFF3AnnotationsAccessibilityID)
                }
            }
        }
    }
}
