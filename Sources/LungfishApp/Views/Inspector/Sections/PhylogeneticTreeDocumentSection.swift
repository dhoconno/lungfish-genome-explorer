import AppKit
import SwiftUI

enum PhylogeneticTreeDocumentSectionKind: Equatable {
    case header
    case inference
    case treeSummary
    case warnings
    case sourceArtifacts
}

struct PhylogeneticTreeDocumentArtifactRow: Equatable {
    let label: String
    let fileURL: URL?
}

struct PhylogeneticTreeDocumentState: Equatable {
    let title: String
    let subtitle: String?
    let summary: String?
    let contextRows: [(String, String)]
    let warningRows: [String]
    let artifactRows: [PhylogeneticTreeDocumentArtifactRow]
    /// Shown as the Inference section only when the tree was inferred in LGE (V2).
    var inferenceRows: [(String, String)] = []
    var inferenceArtifactRows: [PhylogeneticTreeDocumentArtifactRow] = []

    var visibleSectionOrder: [PhylogeneticTreeDocumentSectionKind] {
        (inferenceRows.isEmpty ? [.header] : [.header, .inference]) + [.treeSummary, .warnings, .sourceArtifacts]
    }

    static func == (
        lhs: PhylogeneticTreeDocumentState,
        rhs: PhylogeneticTreeDocumentState
    ) -> Bool {
        lhs.title == rhs.title &&
            lhs.subtitle == rhs.subtitle &&
            lhs.summary == rhs.summary &&
            lhs.contextRows.elementsEqual(rhs.contextRows, by: { $0.0 == $1.0 && $0.1 == $1.1 }) &&
            lhs.warningRows == rhs.warningRows &&
            lhs.artifactRows == rhs.artifactRows &&
            lhs.inferenceRows.elementsEqual(rhs.inferenceRows, by: { $0.0 == $1.0 && $0.1 == $1.1 }) &&
            lhs.inferenceArtifactRows == rhs.inferenceArtifactRows
    }
}

struct PhylogeneticTreeDocumentSection: View {
    let state: PhylogeneticTreeDocumentState

    @State private var isSummaryExpanded = true
    @State private var isWarningsExpanded = true
    @State private var isArtifactsExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            if !state.inferenceRows.isEmpty {
                PhylogeneticTreeInferenceSection(rows: state.inferenceRows, artifactRows: state.inferenceArtifactRows)
                Divider()
            }

            summarySection

            Divider()

            warningsSection

            Divider()

            artifactSection
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.title)
                .font(LungfishInspectorStyle.sectionTitleFont)
                .lineLimit(2)
            if let subtitle = state.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            }
            if let summary = state.summary, !summary.isEmpty {
                Text(summary)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summarySection: some View {
        DisclosureGroup("Tree Summary", isExpanded: $isSummaryExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(state.contextRows.enumerated()), id: \.offset) { _, row in
                    contextRow(label: row.0, value: row.1)
                }
            }
            .padding(.top, 4)
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    private var warningsSection: some View {
        DisclosureGroup("Warnings", isExpanded: $isWarningsExpanded) {
            if state.warningRows.isEmpty {
                emptyMessage("No warnings were recorded for this tree.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.warningRows.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .font(LungfishInspectorStyle.controlFont)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    private var artifactSection: some View {
        DisclosureGroup("Source Artifacts", isExpanded: $isArtifactsExpanded) {
            if state.artifactRows.isEmpty {
                emptyMessage("No tree artifacts are available.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(state.artifactRows.enumerated()), id: \.offset) { _, row in
                        PhylogeneticTreeArtifactRowView(row: row)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    private func contextRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .trailing)
            Text(value)
                .font(LungfishInspectorStyle.controlFont)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}
