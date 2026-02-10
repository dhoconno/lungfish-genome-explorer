// DocumentSection.swift - Bundle metadata display for Inspector Document tab
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

// MARK: - DocumentSectionViewModel

/// View model for the document section of the inspector.
///
/// Displays bundle-level metadata including source information, genome summary,
/// extended metadata groups, and chromosome details when a chromosome is selected.
@Observable
@MainActor
public final class DocumentSectionViewModel {

    /// The currently loaded bundle manifest, if any.
    var manifest: BundleManifest?

    /// The bundle URL for display.
    var bundleURL: URL?

    /// Currently selected chromosome info (for chromosome-level metadata).
    var selectedChromosome: ChromosomeInfo?

    /// Updates the view model with a new bundle manifest.
    ///
    /// - Parameters:
    ///   - manifest: The bundle manifest to display, or nil to clear
    ///   - bundleURL: The URL of the loaded bundle
    func update(manifest: BundleManifest?, bundleURL: URL?) {
        self.manifest = manifest
        self.bundleURL = bundleURL
        self.selectedChromosome = nil
    }

    /// Updates the selected chromosome for detail display.
    ///
    /// - Parameter chromosome: The chromosome to display details for, or nil to clear
    func selectChromosome(_ chromosome: ChromosomeInfo?) {
        self.selectedChromosome = chromosome
    }
}

// MARK: - DocumentSection

/// SwiftUI view displaying bundle-level metadata in the Inspector Document tab.
///
/// Shows source information, genome summary, extended metadata groups from the
/// manifest, and chromosome details when a chromosome is selected. Each section
/// uses a collapsible `DisclosureGroup` for a compact, Keynote-style layout.
public struct DocumentSection: View {
    var viewModel: DocumentSectionViewModel

    @State private var isSourceExpanded = true
    @State private var isGenomeExpanded = true
    @State private var isChromosomeExpanded = true
    @State private var expandedMetadataGroups: Set<String> = []
    @State private var trackedManifestName: String?

    public init(viewModel: DocumentSectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if let manifest = viewModel.manifest {
            bundleContent(manifest)
                .onChange(of: manifest.name) { _, newName in
                    expandAllSections(manifest: manifest)
                    trackedManifestName = newName
                }
                .onAppear {
                    if trackedManifestName != manifest.name {
                        expandAllSections(manifest: manifest)
                        trackedManifestName = manifest.name
                    }
                }
        } else {
            noDocumentView
        }
    }

    private func expandAllSections(manifest: BundleManifest) {
        isSourceExpanded = true
        isGenomeExpanded = true
        isChromosomeExpanded = true
        if let groups = manifest.metadata {
            expandedMetadataGroups = Set(groups.map(\.name))
        }
    }

    // MARK: - Bundle Content

    @ViewBuilder
    private func bundleContent(_ manifest: BundleManifest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Bundle header
            bundleHeader(manifest)

            Divider()

            // Source info
            sourceSection(manifest.source)

            Divider()

            // Genome summary
            genomeSection(manifest.genome, annotations: manifest.annotations, variants: manifest.variants)

            // Extended metadata groups
            if let groups = manifest.metadata, !groups.isEmpty {
                ForEach(groups) { group in
                    Divider()
                    metadataGroupSection(group)
                }
            }

            // Chromosome detail
            if let chromosome = viewModel.selectedChromosome {
                Divider()
                chromosomeSection(chromosome)
            }
        }
    }

    // MARK: - Bundle Header

    @ViewBuilder
    private func bundleHeader(_ manifest: BundleManifest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(manifest.name)
                .font(.headline)
                .lineLimit(2)

            if !manifest.source.organism.isEmpty {
                Text(manifest.source.organism)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .italic()
            }

            if let commonName = manifest.source.commonName, !commonName.isEmpty {
                Text(commonName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let desc = manifest.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Source Section

    @ViewBuilder
    private func sourceSection(_ source: SourceInfo) -> some View {
        DisclosureGroup(isExpanded: $isSourceExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                metadataRow(label: "Organism", value: source.organism)

                if let commonName = source.commonName {
                    metadataRow(label: "Common Name", value: commonName)
                }

                metadataRow(label: "Assembly", value: source.assembly)

                if let accession = source.assemblyAccession {
                    metadataRow(label: "Accession", value: accession)
                }

                if let database = source.database {
                    metadataRow(label: "Database", value: database)
                }

                if let taxonomyId = source.taxonomyId {
                    metadataRow(label: "Taxonomy ID", value: "\(taxonomyId)")
                }

                if let downloadDate = source.downloadDate {
                    metadataRow(label: "Downloaded", value: formatDate(downloadDate))
                }

                if let notes = source.notes, !notes.isEmpty {
                    metadataRow(label: "Notes", value: notes)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Source")
                .font(.headline)
        }
    }

    // MARK: - Genome Section

    @ViewBuilder
    private func genomeSection(_ genome: GenomeInfo, annotations: [AnnotationTrackInfo], variants: [VariantTrackInfo]) -> some View {
        DisclosureGroup(isExpanded: $isGenomeExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                metadataRow(label: "Total Length", value: formatBases(genome.totalLength))
                metadataRow(label: "Chromosomes", value: "\(genome.chromosomes.count)")

                if !annotations.isEmpty {
                    let totalFeatures = annotations.compactMap(\.featureCount).reduce(0, +)
                    let featureSuffix = totalFeatures > 0 ? " (\(formatCount(totalFeatures)) features)" : ""
                    metadataRow(label: "Annotations", value: "\(annotations.count) track\(annotations.count == 1 ? "" : "s")\(featureSuffix)")
                } else {
                    metadataRow(label: "Annotations", value: "None")
                }

                if !variants.isEmpty {
                    let totalVariants = variants.compactMap(\.variantCount).reduce(0, +)
                    let variantSuffix = totalVariants > 0 ? " (\(formatCount(totalVariants)) variants)" : ""
                    metadataRow(label: "Variants", value: "\(variants.count) track\(variants.count == 1 ? "" : "s")\(variantSuffix)")
                } else {
                    metadataRow(label: "Variants", value: "None")
                }

                if let md5 = genome.md5Checksum {
                    metadataRow(label: "MD5", value: md5)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Genome")
                .font(.headline)
        }
    }

    // MARK: - Metadata Group Section

    @ViewBuilder
    private func metadataGroupSection(_ group: MetadataGroup) -> some View {
        DisclosureGroup(isExpanded: metadataGroupBinding(for: group.name)) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.items) { item in
                    metadataRow(label: item.label, value: item.value)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(group.name)
                .font(.headline)
        }
    }

    private func metadataGroupBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { expandedMetadataGroups.contains(name) },
            set: { newValue in
                if newValue {
                    expandedMetadataGroups.insert(name)
                } else {
                    expandedMetadataGroups.remove(name)
                }
            }
        )
    }

    // MARK: - Chromosome Section

    @ViewBuilder
    private func chromosomeSection(_ chromosome: ChromosomeInfo) -> some View {
        DisclosureGroup(isExpanded: $isChromosomeExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                metadataRow(label: "Name", value: chromosome.name)
                metadataRow(label: "Length", value: formatBases(chromosome.length))

                if let desc = chromosome.fastaDescription, !desc.isEmpty {
                    metadataRow(label: "Description", value: desc)
                }

                if chromosome.isPrimary {
                    metadataRow(label: "Status", value: "Primary assembly")
                }

                if chromosome.isMitochondrial {
                    metadataRow(label: "Type", value: "Mitochondrial")
                }

                if !chromosome.aliases.isEmpty {
                    metadataRow(label: "Aliases", value: chromosome.aliases.joined(separator: ", "))
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Chromosome")
                .font(.headline)
        }
    }

    // MARK: - No Document View

    @ViewBuilder
    private var noDocumentView: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No Bundle Loaded")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open a reference bundle to view its metadata")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Metadata Row

    @ViewBuilder
    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)

            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Formatting Helpers

    /// Formats a base-pair count with appropriate unit suffix.
    private func formatBases(_ bases: Int64) -> String {
        if bases >= 1_000_000_000 {
            let gb = Double(bases) / 1_000_000_000.0
            return String(format: "%.2f Gb", gb)
        } else if bases >= 1_000_000 {
            let mb = Double(bases) / 1_000_000.0
            return String(format: "%.1f Mb", mb)
        } else if bases >= 1_000 {
            let kb = Double(bases) / 1_000.0
            return String(format: "%.1f Kb", kb)
        } else {
            return "\(bases) bp"
        }
    }

    /// Formats a count with comma separators.
    private func formatCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    /// Formats a date for display.
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#if DEBUG
struct DocumentSection_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: 16) {
                // With manifest
                DocumentSection(viewModel: {
                    let vm = DocumentSectionViewModel()
                    vm.update(
                        manifest: BundleManifest(
                            name: "Macaca mulatta T2T-MMU8v2.0",
                            identifier: "org.lungfish.macaque",
                            description: "Rhesus macaque telomere-to-telomere assembly",
                            source: SourceInfo(
                                organism: "Macaca mulatta",
                                commonName: "Rhesus macaque",
                                taxonomyId: 9544,
                                assembly: "T2T-MMU8v2.0",
                                assemblyAccession: "GCF_049350105.2",
                                database: "NCBI",
                                downloadDate: Date()
                            ),
                            genome: GenomeInfo(
                                path: "genome/sequence.fa.gz",
                                indexPath: "genome/sequence.fa.gz.fai",
                                totalLength: 2_936_875_000,
                                chromosomes: [
                                    ChromosomeInfo(
                                        name: "NC_041754.1",
                                        length: 227_556_264,
                                        offset: 0,
                                        lineBases: 80,
                                        lineWidth: 81,
                                        isPrimary: true,
                                        fastaDescription: "Macaca mulatta chromosome 1"
                                    )
                                ]
                            ),
                            annotations: [
                                AnnotationTrackInfo(
                                    id: "genes",
                                    name: "NCBI Genes",
                                    path: "annotations/genes.bb",
                                    featureCount: 159_000
                                )
                            ],
                            metadata: [
                                MetadataGroup(
                                    name: "Assembly",
                                    items: [
                                        MetadataItem(label: "Assembly Level", value: "Chromosome"),
                                        MetadataItem(label: "Coverage", value: "30x"),
                                        MetadataItem(label: "Contig N50", value: "56,413,054 bp")
                                    ]
                                )
                            ]
                        ),
                        bundleURL: URL(fileURLWithPath: "/tmp/test.lungfishref")
                    )
                    return vm
                }())

                Divider()

                // Without manifest
                DocumentSection(viewModel: DocumentSectionViewModel())
            }
            .padding()
        }
        .frame(width: 280, height: 800)
    }
}
#endif
