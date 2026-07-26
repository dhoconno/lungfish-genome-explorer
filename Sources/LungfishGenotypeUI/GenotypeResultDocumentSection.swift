import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
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

public enum GenotypeCurrentWorkbookUIPhase: Equatable, Sendable {
    case current
    case dirty
    case updating
    case dirtyWhileUpdating
    case failed(String)

    public func presentation(
        isReadOnly: Bool,
        manualChangeCount: Int = 0
    ) -> GenotypeResultCurrentWorkbookUpdateState {
        let statusText: String
        let isEnabled: Bool
        switch self {
        case .current:
            statusText = "Current — current.xlsx represents the latest LGE review state."
            isEnabled = true
        case .dirty:
            statusText = "Pending edits — current.xlsx does not include the latest LGE review state."
            isEnabled = !isReadOnly
        case .updating:
            statusText = "Updating — publishing the latest LGE review state to current.xlsx."
            isEnabled = true
        case .dirtyWhileUpdating:
            statusText = "Pending edits while updating — one newer workbook update will follow."
            isEnabled = !isReadOnly
        case .failed(let message):
            statusText = "Failed — \(message)"
            isEnabled = !isReadOnly
        }
        return GenotypeResultCurrentWorkbookUpdateState(
            manualChangeCount: manualChangeCount,
            statusText: statusText,
            isEnabled: isEnabled
        )
    }
}

public struct GenotypeCurrentWorkbookUISnapshot: Sendable {
    public let bundleURL: URL
    public let calls: [GenotypeWorkbookHaplotypeCall]
    public let includedLoci: [String]
    public let annotationSidecar: GenotypeAnnotationSidecar
    public let annotationSidecarData: Data
    public let annotationSidecarURL: URL
    public let candidateArtifacts: ONTMHCCandidateArtifactManifest?
    public let annotationOnly: Bool
    public let isReadOnly: Bool

    public init(
        bundleURL: URL,
        calls: [GenotypeWorkbookHaplotypeCall],
        includedLoci: [String],
        annotationSidecar: GenotypeAnnotationSidecar,
        annotationSidecarData: Data,
        annotationSidecarURL: URL,
        candidateArtifacts: ONTMHCCandidateArtifactManifest?,
        annotationOnly: Bool,
        isReadOnly: Bool
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.calls = calls
        self.includedLoci = includedLoci
        self.annotationSidecar = annotationSidecar
        self.annotationSidecarData = annotationSidecarData
        self.annotationSidecarURL = annotationSidecarURL.standardizedFileURL
        self.candidateArtifacts = candidateArtifacts
        self.annotationOnly = annotationOnly
        self.isReadOnly = isReadOnly
    }

    public static func encodingAnnotationSidecar(
        bundleURL: URL,
        calls: [GenotypeWorkbookHaplotypeCall],
        includedLoci: [String],
        annotationSidecar: GenotypeAnnotationSidecar,
        annotationSidecarURL: URL,
        candidateArtifacts: ONTMHCCandidateArtifactManifest?,
        annotationOnly: Bool,
        isReadOnly: Bool,
        encoder: @Sendable (GenotypeAnnotationSidecar) throws -> Data = {
            try $0.encoded()
        }
    ) throws -> Self {
        Self(
            bundleURL: bundleURL,
            calls: calls,
            includedLoci: includedLoci,
            annotationSidecar: annotationSidecar,
            annotationSidecarData: try encoder(annotationSidecar),
            annotationSidecarURL: annotationSidecarURL,
            candidateArtifacts: candidateArtifacts,
            annotationOnly: annotationOnly,
            isReadOnly: isReadOnly
        )
    }
}

public struct GenotypeCurrentWorkbookUIRequest: Sendable {
    public enum Action: Equatable, Sendable {
        case register
        case markDirty
        case synchronize(GenotypeCurrentWorkbookSyncIntent)
    }

    public let snapshot: GenotypeCurrentWorkbookUISnapshot
    public let action: Action
    public let openAfterSuccess: Bool

    public init(snapshot: GenotypeCurrentWorkbookUISnapshot, action: Action) {
        self.snapshot = snapshot
        self.action = action
        if case .synchronize(.updateAndView) = action {
            self.openAfterSuccess = true
        } else {
            self.openAfterSuccess = false
        }
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
    public var availableHaplotypeLoci: [String] = []
    public var includedHaplotypeLoci: Set<String> = []
    public var defaultIncludedHaplotypeLoci: Set<String> = []
    public var hasHaplotypingResult: Bool = false
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
        availableHaplotypeLoci: [String] = [],
        includedHaplotypeLoci: Set<String> = [],
        defaultIncludedHaplotypeLoci: Set<String> = [],
        hasHaplotypingResult: Bool = false,
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
        self.availableHaplotypeLoci = availableHaplotypeLoci
        self.includedHaplotypeLoci = includedHaplotypeLoci
        self.defaultIncludedHaplotypeLoci = defaultIncludedHaplotypeLoci
        self.hasHaplotypingResult = hasHaplotypingResult
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

    public func replacing(includedHaplotypeLoci: Set<String>) -> GenotypeResultDocumentState {
        var copy = self
        copy.includedHaplotypeLoci = includedHaplotypeLoci
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
            lhs.availableHaplotypeLoci == rhs.availableHaplotypeLoci &&
            lhs.includedHaplotypeLoci == rhs.includedHaplotypeLoci &&
            lhs.defaultIncludedHaplotypeLoci == rhs.defaultIncludedHaplotypeLoci &&
            lhs.hasHaplotypingResult == rhs.hasHaplotypingResult &&
            lhs.smartCohorts == rhs.smartCohorts &&
            lhs.auditEntries == rhs.auditEntries &&
            lhs.haplotypeDefinitionRows.elementsEqual(rhs.haplotypeDefinitionRows, by: { $0.0 == $1.0 && $0.1 == $1.1 }) &&
            lhs.haplotypeDefinitionsFolderURL == rhs.haplotypeDefinitionsFolderURL &&
            lhs.currentWorkbookUpdate == rhs.currentWorkbookUpdate
    }
}

enum GenotypeResultDocumentComponent: Equatable {
    case header
    case divider
    case includedLoci
    case smartCohorts
    case summary
    case samples
    case currentWorkbook
    case haplotypeDefinitions
    case qc
    case artifacts
    case auditTimeline
}

public struct GenotypeResultDocumentSection: View {
    let state: GenotypeResultDocumentState
    var onViewModeChange: ((GenotypeSummaryViewMode) -> Void)? = nil
    var onShowsAncillaryLociChange: ((Bool) -> Void)? = nil
    var onIncludedLociChange: ((Set<String>) -> Void)? = nil
    var onSmartCohortSelected: ((GenotypeCohortSmartFilter) -> Void)? = nil
    var onSmartCohortDeleted: ((GenotypeCohortSmartFilter) -> Void)? = nil
    var onSmartCohortAddRequested: (() -> Void)? = nil
    var onCurrentWorkbookUpdateRequested: (() -> Void)? = nil

    @State private var isSummaryExpanded = true
    @State private var isQCExpanded = true
    @State private var isArtifactsExpanded = true
    @State private var isSamplesExpanded = true
    @State private var isIncludedLociExpanded = true
    @State private var isCurrentWorkbookExpanded = true
    @State private var isAuditTimelineExpanded = false
    @State private var isHaplotypeDefinitionsExpanded = true

    public init(
        state: GenotypeResultDocumentState,
        onViewModeChange: ((GenotypeSummaryViewMode) -> Void)? = nil,
        onShowsAncillaryLociChange: ((Bool) -> Void)? = nil,
        onIncludedLociChange: ((Set<String>) -> Void)? = nil,
        onSmartCohortSelected: ((GenotypeCohortSmartFilter) -> Void)? = nil,
        onSmartCohortDeleted: ((GenotypeCohortSmartFilter) -> Void)? = nil,
        onSmartCohortAddRequested: (() -> Void)? = nil,
        onCurrentWorkbookUpdateRequested: (() -> Void)? = nil
    ) {
        self.state = state
        self.onViewModeChange = onViewModeChange
        self.onShowsAncillaryLociChange = onShowsAncillaryLociChange
        self.onIncludedLociChange = onIncludedLociChange
        self.onSmartCohortSelected = onSmartCohortSelected
        self.onSmartCohortDeleted = onSmartCohortDeleted
        self.onSmartCohortAddRequested = onSmartCohortAddRequested
        self.onCurrentWorkbookUpdateRequested = onCurrentWorkbookUpdateRequested
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(visibleComponents.enumerated()), id: \.offset) { entry in
                componentView(entry.element)
            }
        }
    }

    @ViewBuilder
    private func componentView(_ component: GenotypeResultDocumentComponent) -> some View {
        switch component {
        case .header:
            header
        case .divider:
            Divider()
        case .includedLoci:
            includedLociSection
        case .smartCohorts:
            smartCohortsSection
        case .summary:
            summarySection
        case .samples:
            samplesSection
        case .currentWorkbook:
            currentWorkbookSection
        case .haplotypeDefinitions:
            haplotypeDefinitionsSection
        case .qc:
            qcSection
        case .artifacts:
            artifactsSection
        case .auditTimeline:
            auditTimelineSection
        }
    }

    private var visibleComponents: [GenotypeResultDocumentComponent] {
        var components: [GenotypeResultDocumentComponent] = [
            .header,
            .divider,
            .includedLoci,
        ]
        if state.hasHaplotypingResult {
            components += [.divider, .smartCohorts]
        }
        components += [.divider, .summary, .divider, .samples]
        if state.currentWorkbookUpdate != nil {
            components += [.divider, .currentWorkbook]
        }
        if !state.haplotypeDefinitionRows.isEmpty {
            components += [.divider, .haplotypeDefinitions]
        }
        components += [.divider, .qc, .divider, .artifacts]
        if !state.auditEntries.isEmpty {
            components += [.divider, .auditTimeline]
        }
        return components
    }

    private var auditTimelineSection: some View {
        DisclosureGroup("Audit Timeline", isExpanded: $isAuditTimelineExpanded) {
            GenotypeAuditTimelineSection(entries: state.auditEntries)
                .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private var includedLociSection: some View {
        DisclosureGroup("Included Loci", isExpanded: $isIncludedLociExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Included loci appear in Outline. Workbook-supported loci are written to current.xlsx when you update the workbook.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("All") {
                        onIncludedLociChange?(Set(state.availableHaplotypeLoci))
                    }
                    .controlSize(.small)
                    .disabled(state.availableHaplotypeLoci.isEmpty)
                    Button("Default") {
                        onIncludedLociChange?(state.defaultIncludedHaplotypeLoci)
                    }
                    .controlSize(.small)
                    .disabled(state.availableHaplotypeLoci.isEmpty)
                }
                if state.availableHaplotypeLoci.isEmpty {
                    Text("No deterministic haplotype loci are available.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(state.availableHaplotypeLoci, id: \.self) { locus in
                            Toggle(isOn: Binding(
                                get: { state.includedHaplotypeLoci.contains(locus) },
                                set: { isIncluded in
                                    var next = state.includedHaplotypeLoci
                                    if isIncluded {
                                        next.insert(locus)
                                    } else {
                                        next.remove(locus)
                                    }
                                    onIncludedLociChange?(next)
                                }
                            )) {
                                Text(locus)
                                    .font(.caption)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private var smartCohortsSection: some View {
        GenotypeSmartCohortSection(
            cohorts: state.smartCohorts,
            onSelect: { cohort in
                guard state.hasHaplotypingResult else { return }
                onSmartCohortSelected?(cohort)
            },
            onDelete: { cohort in
                guard state.hasHaplotypingResult else { return }
                onSmartCohortDeleted?(cohort)
            },
            onAdd: {
                guard state.hasHaplotypingResult else { return }
                onSmartCohortAddRequested?()
            }
        )
    }

    private var haplotypeDefinitionsSection: some View {
        DisclosureGroup("Haplotype Definitions", isExpanded: $isHaplotypeDefinitionsExpanded) {
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
                    Button("Update and View Current Excel Version") {
                        onCurrentWorkbookUpdateRequested?()
                    }
                    .controlSize(.small)
                    .disabled(!update.isEnabled)
                    .help("Open current.xlsx immediately when current; otherwise update it once and open the successful revision.")
                    Text("Writes displayed haplotype calls, matrix annotations, Overrides, and Audit Log worksheets.")
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

#if DEBUG
extension GenotypeResultDocumentSection {
    var testingSmartCohortActionsAvailable: Bool {
        state.hasHaplotypingResult
    }

    var testingVisibleComponents: [GenotypeResultDocumentComponent] {
        visibleComponents
    }
}
#endif
