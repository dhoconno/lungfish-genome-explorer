import AppKit
import SwiftUI

enum MultipleSequenceAlignmentDocumentSectionKind: Equatable {
    case header
    case alignmentSummary
    case warnings
    case sourceArtifacts
}

struct MultipleSequenceAlignmentDocumentArtifactRow: Equatable {
    let label: String
    let fileURL: URL?
}

struct MultipleSequenceAlignmentDocumentState: Equatable {
    let title: String
    let subtitle: String?
    let summary: String?
    let contextRows: [(String, String)]
    let warningRows: [String]
    let artifactRows: [MultipleSequenceAlignmentDocumentArtifactRow]
    let consensusPreview: String

    var visibleSectionOrder: [MultipleSequenceAlignmentDocumentSectionKind] {
        [.header, .alignmentSummary, .warnings, .sourceArtifacts]
    }

    static func == (
        lhs: MultipleSequenceAlignmentDocumentState,
        rhs: MultipleSequenceAlignmentDocumentState
    ) -> Bool {
        lhs.title == rhs.title &&
            lhs.subtitle == rhs.subtitle &&
            lhs.summary == rhs.summary &&
            lhs.contextRows.elementsEqual(rhs.contextRows, by: { $0.0 == $1.0 && $0.1 == $1.1 }) &&
            lhs.warningRows == rhs.warningRows &&
            lhs.artifactRows == rhs.artifactRows &&
            lhs.consensusPreview == rhs.consensusPreview
    }
}

struct MultipleSequenceAlignmentDocumentSection: View {
    let state: MultipleSequenceAlignmentDocumentState

    @State private var isSummaryExpanded = true
    @State private var isWarningsExpanded = true
    @State private var isArtifactsExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

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
                .font(.headline)
                .lineLimit(2)
            if let subtitle = state.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let summary = state.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summarySection: some View {
        DisclosureGroup("Alignment Summary", isExpanded: $isSummaryExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(state.contextRows.enumerated()), id: \.offset) { _, row in
                    contextRow(label: row.0, value: row.1)
                }
                if !state.consensusPreview.isEmpty {
                    contextRow(label: "Consensus", value: state.consensusPreview)
                }
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private var warningsSection: some View {
        DisclosureGroup("Warnings", isExpanded: $isWarningsExpanded) {
            if state.warningRows.isEmpty {
                emptyMessage("No warnings were recorded for this alignment.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.warningRows.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(.caption.weight(.semibold))
    }

    private var artifactSection: some View {
        DisclosureGroup("Source Artifacts", isExpanded: $isArtifactsExpanded) {
            if state.artifactRows.isEmpty {
                emptyMessage("No alignment artifacts are available.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(state.artifactRows.enumerated()), id: \.offset) { _, row in
                        artifactRow(row)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(.caption.weight(.semibold))
    }

    private func contextRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func artifactRow(_ row: MultipleSequenceAlignmentDocumentArtifactRow) -> some View {
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
