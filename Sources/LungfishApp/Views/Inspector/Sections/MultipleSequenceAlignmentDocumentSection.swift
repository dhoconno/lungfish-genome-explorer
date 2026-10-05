import AppKit
import SwiftUI
import LungfishIO
import LungfishKit

struct MultipleSequenceAlignmentDocumentSection: View {
    let state: MultipleSequenceAlignmentDocumentState
    /// Pairwise identity table state; nil hides the section (read-only alignments, tests).
    var pairwiseIdentity: MSAPairwiseIdentityInspectorModel?
    /// Discriminating-sites state; nil hides the section (read-only alignments, tests).
    var discriminatingSites: MSADiscriminatingSitesInspectorModel?

    @State private var isSummaryExpanded = true
    @State private var isWarningsExpanded = true
    @State private var isArtifactsExpanded = true
    @State private var isPairwiseIdentityExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            summarySection

            if let pairwiseIdentity {
                Divider()

                MSAPairwiseIdentitySection(model: pairwiseIdentity, isExpanded: $isPairwiseIdentityExpanded)
            }

            if let discriminatingSites {
                Divider()

                MSADiscriminatingSitesSection(model: discriminatingSites)
            }

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
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    private var warningsSection: some View {
        DisclosureGroup("Warnings", isExpanded: $isWarningsExpanded) {
            if state.warningRows.isEmpty {
                emptyMessage("No warnings were recorded for this alignment.")
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

    @ViewBuilder
    private func artifactRow(_ row: MultipleSequenceAlignmentDocumentArtifactRow) -> some View {
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
                    pathCaption("Missing")
                }
            }
        }
    }

    private func pathCaption(_ text: String) -> some View {
        Text(text)
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}
