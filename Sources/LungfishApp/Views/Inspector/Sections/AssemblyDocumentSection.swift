import AppKit
import SwiftUI

enum AssemblyDocumentSectionKind: Equatable {
    case header
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
        [.header, .sourceData, .assemblyContext, .sourceArtifacts]
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
                .font(LungfishInspectorStyle.sectionTitleFont)
            if let subtitle = assembly.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            }
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
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    private func sourceDataRow(_ row: AssemblyDocumentSourceRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch row {
            case .projectLink(let name, let targetURL):
                Button(name) {
                    viewModel.navigateToSourceData?(targetURL)
                }
                .buttonStyle(.link)
                .font(LungfishInspectorStyle.controlFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Show in project sidebar")
                pathCaption(targetURL.path)
            case .filesystemLink(let name, let fileURL):
                Button(name) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                .buttonStyle(.link)
                .font(LungfishInspectorStyle.controlFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Reveal in Finder")
                pathCaption(fileURL.path)
            case .missing(let name, let originalPath):
                Text(name)
                    .font(LungfishInspectorStyle.controlFont)
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
                                .font(LungfishInspectorStyle.controlFont)
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .trailing)
                            Text(row.1)
                                .font(LungfishInspectorStyle.controlFont)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
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
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    private func artifactRow(_ row: AssemblyDocumentArtifactRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let fileURL = row.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                Button(row.label) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                .buttonStyle(.link)
                .font(LungfishInspectorStyle.controlFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Reveal in Finder")
                pathCaption(fileURL.path)
            } else {
                Text(row.label)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let fileURL = row.fileURL {
                    pathCaption(fileURL.path)
                } else {
                    plainCaption("Missing")
                }
            }
        }
    }

    /// A recorded path, project-relative when it lies in this project, as
    /// the Provenance tab shows it; the full path is the tooltip and the
    /// accessibility value.
    private func pathCaption(_ path: String) -> some View {
        ProvenancePathCaption(path: path, projectURL: viewModel.enclosingProjectURL)
    }

    private func plainCaption(_ text: String) -> some View {
        Text(text)
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}
