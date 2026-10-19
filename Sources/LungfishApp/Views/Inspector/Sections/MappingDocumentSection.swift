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

/// One command of a mapping run, as a Run Settings step row shows and
/// copies it.
struct MappingDocumentStep: Equatable {
    /// The invocation's label, such as "minimap2" or "samtools sort".
    let label: String
    /// The whole shell-escaped command, `MappingCommandInvocation.commandLine`.
    let command: String
    /// The Mapper Version row's value for the mapper, the Samtools Version
    /// row's value for a samtools command, and nil for any other tool.
    let version: String?
    /// The Recorded row's text.
    let recorded: String
}

struct MappingDocumentState: Equatable {
    let title: String
    let subtitle: String?
    let summary: String?
    let sourceData: [MappingDocumentSourceRow]
    let contextRows: [(String, String)]
    /// The run's commands in invocation order, drawn after the context rows.
    var steps: [MappingDocumentStep] = []
    /// The project the steps' commands are shown relative to.
    var projectURL: URL? = nil
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
            lhs.steps == rhs.steps &&
            lhs.projectURL == rhs.projectURL &&
            lhs.artifactRows == rhs.artifactRows
    }
}

struct MappingDocumentSection: View {
    @Bindable var viewModel: DocumentSectionViewModel
    /// Where the step copy commands write. Tests pass a private pasteboard.
    var pasteboard: NSPasteboard = .general

    @State private var isSourceDataExpanded = true
    @State private var isContextExpanded = true
    @State private var isArtifactsExpanded = true
    @State private var isAlignmentTracksExpanded = true
    /// The Run Settings steps the user expanded, by row index. View state
    /// only, never saved, and cleared for each result, so every step of a
    /// newly shown result starts collapsed.
    @State private var expandedSteps: Set<Int> = []
    /// Each step's shown command by its recorded command, built off the main actor once per record (PF6 Q-U7).
    @State private var shownCommands: [String: String] = [:]

    var body: some View {
        Group {
            if let mapping = viewModel.mappingDocument {
                VStack(alignment: .leading, spacing: 16) {
                    header(mapping)

                    sourceDataSection(mapping.sourceData)

                    Divider()

                    mappingContextSection(mapping)

                    if !viewModel.alignmentTrackRows.isEmpty {
                        Divider()
                        AlignmentTrackInventorySection(viewModel: viewModel, isExpanded: $isAlignmentTracksExpanded)
                    }

                    Divider()

                    sourceArtifactsSection(mapping.artifactRows)
                }
            }
        }
        .onChange(of: viewModel.mappingDocument) {
            expandedSteps = []
        }
        .task(id: viewModel.mappingDocument?.shownCommandsID) {
            guard let mapping = viewModel.mappingDocument else { return }
            let built = await MappingDocumentStateBuilder.shownCommands(for: mapping)
            if !Task.isCancelled { shownCommands = built }
        }
    }

    @ViewBuilder
    private func header(_ mapping: MappingDocumentState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(mapping.title)
                .font(LungfishInspectorStyle.sectionTitleFont)
            if let subtitle = mapping.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            }
            if let summary = mapping.summary, !summary.isEmpty {
                Text(summary)
                    .font(LungfishInspectorStyle.controlFont)
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
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
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
                        .font(LungfishInspectorStyle.controlFont)
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
                        .font(LungfishInspectorStyle.controlFont)
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
                    .font(LungfishInspectorStyle.controlFont)
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

    private func mappingContextSection(_ mapping: MappingDocumentState) -> some View {
        DisclosureGroup("Run Settings", isExpanded: $isContextExpanded) {
            if mapping.contextRows.isEmpty && mapping.steps.isEmpty {
                emptyMessage("No mapping provenance details are available for this analysis.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(mapping.contextRows.enumerated()), id: \.offset) { _, row in
                        contextRow(label: row.0, value: row.1)
                    }
                    ForEach(Array(mapping.steps.enumerated()), id: \.offset) { index, step in
                        MappingDocumentStepRow(
                            step: step,
                            shownCommand: shownCommands[step.command] ?? step.command,
                            number: index + 1,
                            isExpanded: stepExpansion(index),
                            copyText: InspectorStepCopyText.mappingStep(step),
                            copy: copyToPasteboard,
                            allStepsText: { InspectorStepCopyText.mappingSteps(mapping.steps) }
                        )
                    }
                    if !mapping.steps.isEmpty {
                        InspectorCopyButton(
                            title: "Copy All Steps",
                            help: "Copy every step of this run",
                            accessibilityLabel: "Copy all steps",
                            identifier: "mapping-steps-copy-all"
                        ) {
                            copyToPasteboard(InspectorStepCopyText.mappingSteps(mapping.steps))
                        }
                        .padding(.leading, MappingDocumentStepRow.labelWidth + MappingDocumentStepRow.columnSpacing)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    /// Writes plain text in one `.string` flavour, as Copy Path does.
    private func copyToPasteboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func stepExpansion(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { expandedSteps.contains(index) },
            set: { isExpanded in
                if isExpanded {
                    expandedSteps.insert(index)
                } else {
                    expandedSteps.remove(index)
                }
            }
        )
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
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    @ViewBuilder
    private func artifactRow(_ row: MappingDocumentArtifactRow) -> some View {
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

    /// A selectable label and value. The value shows whole, since selecting
    /// truncated text draws the whole string over the rows below.
    private func contextRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: MappingDocumentStepRow.columnSpacing) {
            Text(label)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
                .frame(width: MappingDocumentStepRow.labelWidth, alignment: .trailing)
                .lineLimit(2)

            Text(value)
                .font(LungfishInspectorStyle.controlFont)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(value)
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}
