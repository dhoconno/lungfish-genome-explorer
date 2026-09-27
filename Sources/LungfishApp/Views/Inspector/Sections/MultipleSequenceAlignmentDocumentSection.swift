import AppKit
import SwiftUI
import LungfishIO

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
    /// Pairwise identity table state; nil hides the section (read-only alignments, tests).
    var pairwiseIdentity: MSAPairwiseIdentityInspectorModel?

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

/// Sortable pairwise identity (or p-distance) table backed by `MSADistanceMatrix`, the same
/// service `lungfish-cli msa distance` uses. Copy hands over the CLI's TSV layout; Export runs
/// the CLI through the Operation Center so the file gets a provenance sidecar.
struct MSAPairwiseIdentitySection: View {
    @Bindable var model: MSAPairwiseIdentityInspectorModel
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup("Pairwise Identity", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                controls
                content
            }
            .padding(.top, 4)
            .task(id: isExpanded) {
                guard isExpanded, model.status == .idle else { return }
                await model.compute()
            }
            .onChange(of: model.model) { _, _ in
                guard isExpanded else { return }
                Task { await model.compute() }
            }
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
        .accessibilityIdentifier("msa-pairwise-identity-section")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Model", selection: $model.model) {
                ForEach(MSADistanceModel.allCases) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            .labelsHidden()
            .font(LungfishInspectorStyle.controlFont)
            .frame(maxWidth: 140)
            .accessibilityIdentifier("msa-pairwise-identity-model")

            Spacer(minLength: 0)

            Button("Copy TSV") { model.copyTSV() }
                .font(LungfishInspectorStyle.controlFont)
                .disabled(model.tsv == nil)
                .help("Copy the full matrix as tab-separated text, in the same layout lungfish-cli msa distance writes")
                .accessibilityIdentifier("msa-pairwise-identity-copy")

            Button("Export TSV…") { model.requestExport() }
                .font(LungfishInspectorStyle.controlFont)
                .disabled(model.onExportRequested == nil)
                .help("Write the matrix with a provenance sidecar using lungfish-cli msa distance")
                .accessibilityIdentifier("msa-pairwise-identity-export")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .idle, .computing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Computing pairwise \(model.model.displayName.lowercased())…")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            }
        case .tooManyRows(let count):
            Text("This alignment has \(count) sequences, more than the \(MSAPairwiseIdentityInspectorModel.maxRowsForInlineTable) shown inline. Use Export TSV… to compute the full matrix as an operation.")
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .ready:
            if model.pairs.isEmpty {
                Text("The alignment has fewer than two sequences, so there are no pairs to compare.")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            } else {
                Table(model.sortedPairs, sortOrder: $model.sortOrder) {
                    TableColumn("Sequence A", value: \.rowName) { pair in
                        Text(pair.rowName).font(LungfishInspectorStyle.controlFont)
                    }
                    TableColumn("Sequence B", value: \.columnName) { pair in
                        Text(pair.columnName).font(LungfishInspectorStyle.controlFont)
                    }
                    TableColumn(model.model.displayName, value: \.sortableValue) { pair in
                        Text(pair.formattedValue)
                            .font(LungfishInspectorStyle.controlFont)
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 80)
                    TableColumn("Sites", value: \.comparableSites) { pair in
                        Text("\(pair.comparableSites)")
                            .font(LungfishInspectorStyle.controlFont)
                            .monospacedDigit()
                    }
                    .width(min: 50, ideal: 60)
                }
                .frame(minHeight: 120, idealHeight: min(320, CGFloat(model.pairs.count + 1) * 24 + 8), maxHeight: 320)
                .accessibilityIdentifier("msa-pairwise-identity-table")
                Text("\(model.pairs.count) pairs, gaps skipped pairwise. Values match lungfish-cli msa distance --model \(model.model.rawValue).")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
