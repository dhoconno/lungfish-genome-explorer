import SwiftUI

enum MappingDocumentSectionKind: Equatable {
    case header
    case sourceData
    case mappingContext
    case sourceArtifacts
}

enum MappingDocumentSourceRow: Equatable {
    case projectLink(name: String, targetURL: URL)
    case filesystemLink(name: String, fileURL: URL)
    case missing(name: String, originalPath: String?)
}

struct MappingDocumentArtifactRow: Equatable {
    let label: String
    let fileURL: URL?
}

struct MappingDocumentState: Equatable {
    let title: String
    let subtitle: String?
    let summary: String?
    let sourceData: [MappingDocumentSourceRow]
    let contextRows: [(String, String)]
    let artifactRows: [MappingDocumentArtifactRow]

    var visibleSectionOrder: [MappingDocumentSectionKind] {
        [.header, .sourceData, .mappingContext, .sourceArtifacts]
    }

    static func == (lhs: MappingDocumentState, rhs: MappingDocumentState) -> Bool {
        lhs.title == rhs.title &&
            lhs.subtitle == rhs.subtitle &&
            lhs.summary == rhs.summary &&
            lhs.sourceData == rhs.sourceData &&
            lhs.contextRows.elementsEqual(rhs.contextRows, by: { $0.0 == $1.0 && $0.1 == $1.1 }) &&
            lhs.artifactRows == rhs.artifactRows
    }
}

struct MappingDocumentSection: View {
    @Bindable var viewModel: DocumentSectionViewModel

    @State private var isSourceDataExpanded = true
    @State private var isContextExpanded = true
    @State private var isArtifactsExpanded = true
    @State private var isAlignmentTracksExpanded = true

    var body: some View {
        if let mapping = viewModel.mappingDocument {
            VStack(alignment: .leading, spacing: 16) {
                header(mapping)

                sourceDataSection(mapping.sourceData)

                Divider()

                mappingContextSection(mapping.contextRows)

                if !viewModel.alignmentTrackRows.isEmpty {
                    Divider()
                    AlignmentTrackInventorySection(viewModel: viewModel, isExpanded: $isAlignmentTracksExpanded)
                }

                Divider()

                sourceArtifactsSection(mapping.artifactRows)
            }
        }
    }

    @ViewBuilder
    private func header(_ mapping: MappingDocumentState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(mapping.title)
                .font(.headline)
            if let subtitle = mapping.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let summary = mapping.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceDataSection(_ rows: [MappingDocumentSourceRow]) -> some View {
        DisclosureGroup("Run Inputs", isExpanded: $isSourceDataExpanded) {
            if rows.isEmpty {
                emptyMessage("No source FASTQ or reference inputs were recorded for this mapping analysis.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        sourceDataRow(row)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder
    private func sourceDataRow(_ row: MappingDocumentSourceRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch row {
            case .projectLink(let name, let targetURL):
                Button {
                    viewModel.navigateToSourceData?(targetURL)
                } label: {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(sourceDataButtonIdentifier(for: name))
                .accessibilityLabel(name)
                .help("Show in project sidebar")
                pathCaption(targetURL.path)

            case .filesystemLink(let name, let fileURL):
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(sourceDataButtonIdentifier(for: name))
                .accessibilityLabel(name)
                .help("Reveal in Finder")
                pathCaption(fileURL.path)

            case .missing(let name, let originalPath):
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let originalPath, !originalPath.isEmpty {
                    pathCaption(originalPath)
                }
            }
        }
    }

    private func sourceDataButtonIdentifier(for title: String) -> String {
        let slug = title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "mapping-source-data-\(slug)"
    }

    private func mappingContextSection(_ rows: [(String, String)]) -> some View {
        DisclosureGroup("Run Settings", isExpanded: $isContextExpanded) {
            if rows.isEmpty {
                emptyMessage("No mapping provenance details are available for this analysis.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        contextRow(label: row.0, value: row.1)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(.caption.weight(.semibold))
    }

    private func sourceArtifactsSection(_ rows: [MappingDocumentArtifactRow]) -> some View {
        DisclosureGroup("Output Files", isExpanded: $isArtifactsExpanded) {
            if rows.isEmpty {
                emptyMessage("No mapping artifacts are available.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        artifactRow(row)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder
    private func artifactRow(_ row: MappingDocumentArtifactRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let fileURL = row.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                Button(row.label) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                .buttonStyle(.link)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Reveal in Finder")
                pathCaption(fileURL.path)
            } else {
                Text(row.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let fileURL = row.fileURL {
                    pathCaption(fileURL.path)
                } else {
                    pathCaption("Missing")
                }
            }
        }
    }

    private func pathCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(text)
    }

    private func contextRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
                .lineLimit(2)

            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(value)
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}
