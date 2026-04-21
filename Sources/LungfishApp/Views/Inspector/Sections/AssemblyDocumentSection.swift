import AppKit
import SwiftUI

enum AssemblyDocumentSectionKind: Equatable {
    case header
    case layout
    case sourceData
    case assemblyContext
    case sourceArtifacts
}

enum AssemblyDocumentSourceRow: Equatable {
    case projectLink(name: String, targetURL: URL)
    case filesystemLink(name: String, fileURL: URL)
    case missing(name: String, originalPath: String?)
}

struct AssemblyDocumentArtifactRow: Equatable {
    let label: String
    let fileURL: URL?
}

struct AssemblyDocumentState: Equatable {
    let title: String
    let subtitle: String?
    let sourceData: [AssemblyDocumentSourceRow]
    let contextRows: [(String, String)]
    let artifactRows: [AssemblyDocumentArtifactRow]

    var visibleSectionOrder: [AssemblyDocumentSectionKind] {
        [.header, .layout, .sourceData, .assemblyContext, .sourceArtifacts]
    }

    static func == (lhs: AssemblyDocumentState, rhs: AssemblyDocumentState) -> Bool {
        lhs.title == rhs.title &&
            lhs.subtitle == rhs.subtitle &&
            lhs.sourceData == rhs.sourceData &&
            lhs.contextRows.elementsEqual(rhs.contextRows, by: { $0.0 == $1.0 && $0.1 == $1.1 }) &&
            lhs.artifactRows == rhs.artifactRows
    }
}

struct AssemblyDocumentSection: View {
    @Bindable var viewModel: DocumentSectionViewModel

    @State private var isSourceDataExpanded = true
    @State private var isContextExpanded = true
    @State private var isArtifactsExpanded = true

    var body: some View {
        if let assembly = viewModel.assemblyDocument {
            VStack(alignment: .leading, spacing: 16) {
                header(assembly)

                Divider()

                panelLayoutSection

                Divider()

                sourceDataSection(assembly.sourceData)

                Divider()

                assemblyContextSection(assembly.contextRows)

                Divider()

                sourceArtifactsSection(assembly.artifactRows)
            }
        }
    }

    @ViewBuilder
    private func header(_ assembly: AssemblyDocumentState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(assembly.title)
                .font(.headline)
            if let subtitle = assembly.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var panelLayoutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Panel Layout")
                .font(.caption.weight(.semibold))

            Picker("Layout", selection: Binding(
                get: { viewModel.assemblyPanelLayout },
                set: { newValue in
                    viewModel.assemblyPanelLayout = newValue
                    newValue.persist()
                }
            )) {
                Label("Detail | List", systemImage: "sidebar.left")
                    .tag(AssemblyPanelLayout.detailLeading)
                Label("List | Detail", systemImage: "sidebar.right")
                    .tag(AssemblyPanelLayout.listLeading)
                Label("List Over Detail", systemImage: "rectangle.split.1x2")
                    .tag(AssemblyPanelLayout.stacked)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private func sourceDataSection(_ rows: [AssemblyDocumentSourceRow]) -> some View {
        DisclosureGroup("Source Data", isExpanded: $isSourceDataExpanded) {
            if rows.isEmpty {
                emptyMessage("No source inputs were recorded for this assembly.")
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

    private func sourceDataRow(_ row: AssemblyDocumentSourceRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch row {
            case .projectLink(let name, let targetURL):
                Button(name) {
                    viewModel.navigateToSourceData?(targetURL)
                }
                .buttonStyle(.link)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Show in project sidebar")
                pathCaption(targetURL.path)
            case .filesystemLink(let name, let fileURL):
                Button(name) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                .buttonStyle(.link)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func assemblyContextSection(_ rows: [(String, String)]) -> some View {
        DisclosureGroup("Assembly Context", isExpanded: $isContextExpanded) {
            if rows.isEmpty {
                emptyMessage("No provenance details were recorded for this assembly.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top) {
                            Text(row.0)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .trailing)
                            Text(row.1)
                                .font(.caption)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(.caption.weight(.semibold))
    }

    private func sourceArtifactsSection(_ rows: [AssemblyDocumentArtifactRow]) -> some View {
        DisclosureGroup("Source Artifacts", isExpanded: $isArtifactsExpanded) {
            if rows.isEmpty {
                emptyMessage("No assembly artifacts are available.")
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

    private func artifactRow(_ row: AssemblyDocumentArtifactRow) -> some View {
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
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}
