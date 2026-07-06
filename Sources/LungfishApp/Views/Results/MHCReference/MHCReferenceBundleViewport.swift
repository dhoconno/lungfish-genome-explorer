import Foundation
import LungfishIO
import LungfishKit
import SwiftUI

struct MHCReferenceBundleViewportModel: Equatable {
    struct DefinitionSummary: Equatable, Identifiable {
        let id: String
        let displayName: String
        let species: String
        let assayID: String
        let locusSummaries: [String]
        let diagnosticAlleleCount: Int
    }

    let bundleURL: URL
    let title: String
    let fastaText: String
    let referenceCount: Int
    let definitionSummaries: [DefinitionSummary]

    static func load(bundleURL: URL) throws -> MHCReferenceBundleViewportModel {
        let standardizedBundleURL = bundleURL.standardizedFileURL
        let manifest = try MHCAmpliconReferenceBundle.loadManifest(from: standardizedBundleURL)
        guard let fastaURL = MHCAmpliconReferenceBundle.referenceFASTAURL(in: standardizedBundleURL) else {
            throw ReferenceBundleValidationError(kind: .missingFile(manifest.referenceFastaPath))
        }
        let fastaText = try String(contentsOf: fastaURL, encoding: .utf8)
        let definitions = try MHCAmpliconReferenceBundle.haplotypeDefinitions(in: standardizedBundleURL)
        return MHCReferenceBundleViewportModel(
            bundleURL: standardizedBundleURL,
            title: manifest.name,
            fastaText: fastaText,
            referenceCount: manifest.metrics.referenceCount,
            definitionSummaries: definitions.map(Self.summary(for:))
        )
    }

    /// Async variant of ``load(bundleURL:)`` that reads the reference FASTA off
    /// the main actor via ``AsyncFileReader``. Parsing and manifest/definition
    /// loading are identical to the synchronous version; only the FASTA read
    /// moves off-main so a large reference does not block the UI during display.
    static func loadAsync(bundleURL: URL) async throws -> MHCReferenceBundleViewportModel {
        let standardizedBundleURL = bundleURL.standardizedFileURL
        let manifest = try MHCAmpliconReferenceBundle.loadManifest(from: standardizedBundleURL)
        guard let fastaURL = MHCAmpliconReferenceBundle.referenceFASTAURL(in: standardizedBundleURL) else {
            throw ReferenceBundleValidationError(kind: .missingFile(manifest.referenceFastaPath))
        }
        let fastaText = try await AsyncFileReader.readString(fastaURL, encoding: .utf8)
        let definitions = try MHCAmpliconReferenceBundle.haplotypeDefinitions(in: standardizedBundleURL)
        return MHCReferenceBundleViewportModel(
            bundleURL: standardizedBundleURL,
            title: manifest.name,
            fastaText: fastaText,
            referenceCount: manifest.metrics.referenceCount,
            definitionSummaries: definitions.map(Self.summary(for:))
        )
    }

    private static func summary(
        for definition: GenotypeHaplotypeDefinitionSet
    ) -> DefinitionSummary {
        let locusSummaries = definition.locusDefinitions.map { locus in
            let count = locus.haplotypes.count
            return "\(locus.locus): \(count) haplotype\(count == 1 ? "" : "s")"
        }
        let alleleCount = definition.locusDefinitions.reduce(0) { total, locus in
            total + locus.haplotypes.reduce(0) { $0 + $1.diagnosticAlleles.count }
        }
        return DefinitionSummary(
            id: definition.id,
            displayName: definition.displayName,
            species: "\(definition.speciesName) (\(definition.speciesCode))",
            assayID: definition.assayID,
            locusSummaries: locusSummaries,
            diagnosticAlleleCount: alleleCount
        )
    }
}

struct MHCReferenceBundleViewport: View {
    let model: MHCReferenceBundleViewportModel
    let onEditHaplotypes: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VSplitView {
                fastaPane
                    .frame(minHeight: 220)
                haplotypeSummary
                    .frame(minHeight: 220)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.headline)
                Text("\(model.referenceCount) FASTA record\(model.referenceCount == 1 ? "" : "s") / \(model.definitionSummaries.count) haplotype definition\(model.definitionSummaries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onEditHaplotypes) {
                Label("Edit Haplotypes", systemImage: "pencil")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var fastaPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference FASTA")
                .font(.subheadline.weight(.semibold))
            ScrollView([.vertical, .horizontal]) {
                Text(model.fastaText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .padding(16)
    }

    private var haplotypeSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Defined Haplotypes")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: onEditHaplotypes) {
                    Label("Edit", systemImage: "pencil")
                }
                .controlSize(.small)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.definitionSummaries) { summary in
                        definitionRow(summary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
    }

    private func definitionRow(_ summary: MHCReferenceBundleViewportModel.DefinitionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.displayName)
                        .font(.body.weight(.semibold))
                    Text(summary.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text("\(summary.diagnosticAlleleCount) alleles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Assay")
                        .foregroundStyle(.secondary)
                    Text(summary.assayID)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Species")
                        .foregroundStyle(.secondary)
                    Text(summary.species)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Loci")
                        .foregroundStyle(.secondary)
                    Text(summary.locusSummaries.joined(separator: ", "))
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
