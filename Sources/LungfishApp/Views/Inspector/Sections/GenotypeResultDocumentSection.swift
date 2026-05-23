import AppKit
import LungfishCore
import LungfishIO
import SwiftUI

struct GenotypeResultArtifactRow: Equatable {
    let label: String
    let fileURL: URL?
}

struct GenotypeResultDocumentState: Equatable {
    var title: String
    var subtitle: String?
    var bundleURL: URL?
    var sampleIds: [String]
    var sampleMetadataStore: SampleMetadataStore?
    var windowStateScope: WindowStateScope?
    var summaryRows: [(String, String)]
    var qcRows: [(String, String)]
    var artifactRows: [GenotypeResultArtifactRow]
    var summaryViewMode: GenotypeSummaryViewMode = .outline
    var smartCohorts: [GenotypeSmartCohortSection.DisplayedCohort] = []
    var auditEntries: [GenotypeAnnotationSidecar.AuditEntry] = []

    func replacing(sampleMetadataStore: SampleMetadataStore?) -> GenotypeResultDocumentState {
        var copy = self
        copy.sampleMetadataStore = sampleMetadataStore
        return copy
    }

    func replacing(summaryViewMode: GenotypeSummaryViewMode) -> GenotypeResultDocumentState {
        var copy = self
        copy.summaryViewMode = summaryViewMode
        return copy
    }

    static func == (
        lhs: GenotypeResultDocumentState,
        rhs: GenotypeResultDocumentState
    ) -> Bool {
        lhs.title == rhs.title &&
            lhs.subtitle == rhs.subtitle &&
            lhs.bundleURL == rhs.bundleURL &&
            lhs.sampleIds == rhs.sampleIds &&
            lhs.sampleMetadataStore?.matchedSampleIds == rhs.sampleMetadataStore?.matchedSampleIds &&
            lhs.sampleMetadataStore?.columnNames == rhs.sampleMetadataStore?.columnNames &&
            lhs.windowStateScope == rhs.windowStateScope &&
            lhs.summaryRows.elementsEqual(rhs.summaryRows, by: { $0.0 == $1.0 && $0.1 == $1.1 }) &&
            lhs.qcRows.elementsEqual(rhs.qcRows, by: { $0.0 == $1.0 && $0.1 == $1.1 }) &&
            lhs.artifactRows == rhs.artifactRows &&
            lhs.summaryViewMode == rhs.summaryViewMode &&
            lhs.smartCohorts == rhs.smartCohorts &&
            lhs.auditEntries == rhs.auditEntries
    }
}

struct GenotypeResultDocumentSection: View {
    let state: GenotypeResultDocumentState
    var onViewModeChange: ((GenotypeSummaryViewMode) -> Void)? = nil
    var onSmartCohortSelected: ((GenotypeCohortSmartFilter) -> Void)? = nil
    var onSmartCohortDeleted: ((GenotypeCohortSmartFilter) -> Void)? = nil
    var onSmartCohortAddRequested: (() -> Void)? = nil

    @State private var isSummaryExpanded = true
    @State private var isQCExpanded = true
    @State private var isArtifactsExpanded = true
    @State private var isSamplesExpanded = true
    @State private var isViewModeExpanded = true
    @State private var isSmartCohortsExpanded = true
    @State private var isAuditTimelineExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            viewModeSection
            Divider()
            smartCohortsSection
            Divider()
            summarySection
            Divider()
            samplesSection
            Divider()
            qcSection
            Divider()
            artifactsSection
            if !state.auditEntries.isEmpty {
                Divider()
                auditTimelineSection
            }
        }
    }

    private var auditTimelineSection: some View {
        DisclosureGroup("Audit Timeline", isExpanded: $isAuditTimelineExpanded) {
            GenotypeAuditTimelineSection(entries: state.auditEntries)
                .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private var smartCohortsSection: some View {
        DisclosureGroup("Smart Cohorts", isExpanded: $isSmartCohortsExpanded) {
            GenotypeSmartCohortSection(
                cohorts: state.smartCohorts,
                onSelect: { onSmartCohortSelected?($0) },
                onDelete: { onSmartCohortDeleted?($0) },
                onAdd: { onSmartCohortAddRequested?() }
            )
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private var viewModeSection: some View {
        DisclosureGroup("View Mode", isExpanded: $isViewModeExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(GenotypeSummaryViewMode.allCases, id: \.self) { mode in
                    Button(action: {
                        onViewModeChange?(mode)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: state.summaryViewMode == mode ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(state.summaryViewMode == mode ? Color.accentColor : .secondary)
                            Text(mode.displayName)
                                .font(.caption)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

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
        }
    }

    private var summarySection: some View {
        DisclosureGroup("Run Summary", isExpanded: $isSummaryExpanded) {
            rowStack(state.summaryRows)
                .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private var qcSection: some View {
        DisclosureGroup("QC Status", isExpanded: $isQCExpanded) {
            rowStack(state.qcRows)
                .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private var samplesSection: some View {
        DisclosureGroup("Samples & Metadata", isExpanded: $isSamplesExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text("Samples")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 118, alignment: .trailing)
                    Text("\(state.sampleIds.count)")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(state.sampleMetadataStore == nil ? "Import Metadata\u{2026}" : "Replace Metadata\u{2026}") {
                    NotificationCenter.default.post(
                        name: .metagenomicsMetadataImportRequested,
                        object: nil,
                        userInfo: windowScopedUserInfo()
                    )
                }
                .controlSize(.small)
                .disabled(state.sampleIds.isEmpty)

                if let store = state.sampleMetadataStore {
                    SampleMetadataSection(store: store)
                }
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private var artifactsSection: some View {
        DisclosureGroup("Artifacts", isExpanded: $isArtifactsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(state.artifactRows.enumerated()), id: \.offset) { _, row in
                    artifactRow(row)
                }
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private func rowStack(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top) {
                    Text(row.0)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 118, alignment: .trailing)
                    Text(row.1)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func artifactRow(_ row: GenotypeResultArtifactRow) -> some View {
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
                pathCaption(row.fileURL?.path ?? "Missing")
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

    private func windowScopedUserInfo() -> [AnyHashable: Any]? {
        guard let scope = state.windowStateScope else { return nil }
        return [NotificationUserInfoKey.windowStateScope: scope]
    }
}
