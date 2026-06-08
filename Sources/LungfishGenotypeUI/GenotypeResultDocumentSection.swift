import AppKit
import LungfishCore
import LungfishIO
import SwiftUI
import LungfishKit

public struct GenotypeResultArtifactRow: Equatable {
    public let label: String
    public let fileURL: URL?

    public init(label: String, fileURL: URL?) {
        self.label = label
        self.fileURL = fileURL
    }
}

public struct GenotypeResultCurrentWorkbookUpdateState: Equatable {
    public var manualChangeCount: Int
    public var statusText: String
    public var isEnabled: Bool

    public init(manualChangeCount: Int, statusText: String, isEnabled: Bool) {
        self.manualChangeCount = manualChangeCount
        self.statusText = statusText
        self.isEnabled = isEnabled
    }
}

public struct GenotypeResultDocumentState: Equatable {
    public var title: String
    public var subtitle: String?
    public var bundleURL: URL?
    public var sampleIds: [String]
    public var sampleMetadataStore: SampleMetadataStore?
    public var windowStateScope: WindowStateScope?
    public var summaryRows: [(String, String)]
    public var qcRows: [(String, String)]
    public var artifactRows: [GenotypeResultArtifactRow]
    public var summaryViewMode: GenotypeSummaryViewMode = .outline
    public var showsAncillaryLoci: Bool = false
    public var smartCohorts: [GenotypeSmartCohortSection.DisplayedCohort] = []
    public var auditEntries: [GenotypeAnnotationSidecar.AuditEntry] = []
    public var haplotypeDefinitionRows: [(String, String)] = []
    public var haplotypeDefinitionsFolderURL: URL?
    public var currentWorkbookUpdate: GenotypeResultCurrentWorkbookUpdateState?

    public init(
        title: String,
        subtitle: String? = nil,
        bundleURL: URL? = nil,
        sampleIds: [String],
        sampleMetadataStore: SampleMetadataStore? = nil,
        windowStateScope: WindowStateScope? = nil,
        summaryRows: [(String, String)],
        qcRows: [(String, String)],
        artifactRows: [GenotypeResultArtifactRow],
        summaryViewMode: GenotypeSummaryViewMode = .outline,
        showsAncillaryLoci: Bool = false,
        smartCohorts: [GenotypeSmartCohortSection.DisplayedCohort] = [],
        auditEntries: [GenotypeAnnotationSidecar.AuditEntry] = [],
        haplotypeDefinitionRows: [(String, String)] = [],
        haplotypeDefinitionsFolderURL: URL? = nil,
        currentWorkbookUpdate: GenotypeResultCurrentWorkbookUpdateState? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.bundleURL = bundleURL
        self.sampleIds = sampleIds
        self.sampleMetadataStore = sampleMetadataStore
        self.windowStateScope = windowStateScope
        self.summaryRows = summaryRows
        self.qcRows = qcRows
        self.artifactRows = artifactRows
        self.summaryViewMode = summaryViewMode
        self.showsAncillaryLoci = showsAncillaryLoci
        self.smartCohorts = smartCohorts
        self.auditEntries = auditEntries
        self.haplotypeDefinitionRows = haplotypeDefinitionRows
        self.haplotypeDefinitionsFolderURL = haplotypeDefinitionsFolderURL
        self.currentWorkbookUpdate = currentWorkbookUpdate
    }

    public func replacing(sampleMetadataStore: SampleMetadataStore?) -> GenotypeResultDocumentState {
        var copy = self
        copy.sampleMetadataStore = sampleMetadataStore
        return copy
    }

    public func replacing(summaryViewMode: GenotypeSummaryViewMode) -> GenotypeResultDocumentState {
        var copy = self
        copy.summaryViewMode = summaryViewMode
        return copy
    }

    public func replacing(showsAncillaryLoci: Bool) -> GenotypeResultDocumentState {
        var copy = self
        copy.showsAncillaryLoci = showsAncillaryLoci
        return copy
    }

    public func replacing(auditEntries: [GenotypeAnnotationSidecar.AuditEntry]) -> GenotypeResultDocumentState {
        var copy = self
        copy.auditEntries = auditEntries
        return copy
    }

    public func replacing(
        currentWorkbookUpdate: GenotypeResultCurrentWorkbookUpdateState?
    ) -> GenotypeResultDocumentState {
        var copy = self
        copy.currentWorkbookUpdate = currentWorkbookUpdate
        return copy
    }

    public static func == (
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
            lhs.showsAncillaryLoci == rhs.showsAncillaryLoci &&
            lhs.smartCohorts == rhs.smartCohorts &&
            lhs.auditEntries == rhs.auditEntries &&
            lhs.haplotypeDefinitionRows.elementsEqual(rhs.haplotypeDefinitionRows, by: { $0.0 == $1.0 && $0.1 == $1.1 }) &&
            lhs.haplotypeDefinitionsFolderURL == rhs.haplotypeDefinitionsFolderURL &&
            lhs.currentWorkbookUpdate == rhs.currentWorkbookUpdate
    }
}

public struct GenotypeResultDocumentSection: View {
    let state: GenotypeResultDocumentState
    var onViewModeChange: ((GenotypeSummaryViewMode) -> Void)? = nil
    var onShowsAncillaryLociChange: ((Bool) -> Void)? = nil
    var onSmartCohortSelected: ((GenotypeCohortSmartFilter) -> Void)? = nil
    var onSmartCohortDeleted: ((GenotypeCohortSmartFilter) -> Void)? = nil
    var onSmartCohortAddRequested: (() -> Void)? = nil
    var onCurrentWorkbookUpdateRequested: (() -> Void)? = nil

    @State private var isSummaryExpanded = true
    @State private var isQCExpanded = true
    @State private var isArtifactsExpanded = true
    @State private var isSamplesExpanded = true
    @State private var isViewModeExpanded = true
    @State private var isCurrentWorkbookExpanded = true
    @State private var isAuditTimelineExpanded = false

    public init(
        state: GenotypeResultDocumentState,
        onViewModeChange: ((GenotypeSummaryViewMode) -> Void)? = nil,
        onShowsAncillaryLociChange: ((Bool) -> Void)? = nil,
        onSmartCohortSelected: ((GenotypeCohortSmartFilter) -> Void)? = nil,
        onSmartCohortDeleted: ((GenotypeCohortSmartFilter) -> Void)? = nil,
        onSmartCohortAddRequested: (() -> Void)? = nil,
        onCurrentWorkbookUpdateRequested: (() -> Void)? = nil
    ) {
        self.state = state
        self.onViewModeChange = onViewModeChange
        self.onShowsAncillaryLociChange = onShowsAncillaryLociChange
        self.onSmartCohortSelected = onSmartCohortSelected
        self.onSmartCohortDeleted = onSmartCohortDeleted
        self.onSmartCohortAddRequested = onSmartCohortAddRequested
        self.onCurrentWorkbookUpdateRequested = onCurrentWorkbookUpdateRequested
    }

    public var body: some View {
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
            if state.currentWorkbookUpdate != nil {
                Divider()
                currentWorkbookSection
            }
            if !state.haplotypeDefinitionRows.isEmpty {
                Divider()
                haplotypeDefinitionsSection
            }
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
                Toggle(isOn: Binding(
                    get: { state.showsAncillaryLoci },
                    set: { onShowsAncillaryLociChange?($0) }
                )) {
                    Text("Show observed-only loci")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .help("Include loci the active haplotype definition set does not analyze (e.g. MHC-AG, MHC-70 for MCM).")
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private var smartCohortsSection: some View {
        GenotypeSmartCohortSection(
            cohorts: state.smartCohorts,
            onSelect: { cohort in
                onSmartCohortSelected?(cohort)
            },
            onDelete: { cohort in
                onSmartCohortDeleted?(cohort)
            },
            onAdd: {
                onSmartCohortAddRequested?()
            }
        )
    }

    private var haplotypeDefinitionsSection: some View {
        DisclosureGroup("Haplotype Definitions", isExpanded: .constant(true)) {
            VStack(alignment: .leading, spacing: 8) {
                rowStack(state.haplotypeDefinitionRows)
                HStack(spacing: 8) {
                    Button("Open Definitions...") {
                        NotificationCenter.default.post(
                            name: .genotypeResultOpenHaplotypeDefinitions,
                            object: nil,
                            userInfo: windowScopedUserInfo()
                        )
                    }
                    .controlSize(.small)
                    if let folderURL = state.haplotypeDefinitionsFolderURL {
                        Button("Reveal Folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([folderURL])
                        }
                        .controlSize(.small)
                    }
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

    private var currentWorkbookSection: some View {
        DisclosureGroup("Current Workbook", isExpanded: $isCurrentWorkbookExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let update = state.currentWorkbookUpdate {
                    Text(update.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Update current.xlsx") {
                        onCurrentWorkbookUpdateRequested?()
                    }
                    .controlSize(.small)
                    .disabled(!update.isEnabled)
                    .help("Apply Review viewport haplotype edits and audit timeline to artifacts/workbooks/current.xlsx.")
                    Text("Writes displayed haplotype calls, Overrides, and Audit Log worksheets.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
