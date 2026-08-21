// ProvenanceInspectorViewModel.swift - Generic Inspector provenance presentation model
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

struct ProvenanceInspectableItem {
    var url: URL?
    var sidebarType: SidebarItemType?
    var contentMode: ViewportContentMode
    var displayName: String?

    init(
        url: URL?,
        sidebarType: SidebarItemType?,
        contentMode: ViewportContentMode,
        displayName: String?
    ) {
        self.url = url
        self.sidebarType = sidebarType
        self.contentMode = contentMode
        self.displayName = displayName
    }
}

enum ProvenanceRequirement: Equatable {
    case notRequired
    case required(String)

    var isNotRequired: Bool {
        if case .notRequired = self { return true }
        return false
    }
}

enum ProvenanceAuditStatus: String, Equatable {
    case notRequired
    case present
    case missing
    case invalid
    case incomplete
    case stale
    case legacy
}

struct ProvenanceAuditResult: Equatable {
    var status: ProvenanceAuditStatus
    var requirement: ProvenanceRequirement
    var sidecarURL: URL?
    var messages: [String]

    var isBlocking: Bool {
        switch status {
        case .missing, .invalid, .incomplete, .stale:
            return !requirement.isNotRequired
        case .notRequired, .present, .legacy:
            return false
        }
    }

    static let notRequired = ProvenanceAuditResult(
        status: .notRequired,
        requirement: .notRequired,
        sidecarURL: nil,
        messages: []
    )
}

struct ProvenanceCoverageMonitor {
    private let scientificExtensions: Set<String> = [
        "lungfishref",
        "lungfishfastq",
        "lungfishmsa",
        "lungfishtree",
        "lungfishprimers",
        "bam",
        "cram",
        "vcf",
        "bcf",
        "fasta",
        "fa",
        "fastq",
        "fq",
    ]

    func requirement(for item: ProvenanceInspectableItem) -> ProvenanceRequirement {
        if let sidebarType = item.sidebarType, requiresProvenance(sidebarType) {
            return .required("Scientific sidebar item")
        }

        if let url = item.url, requiresProvenance(url: url) {
            return .required("Scientific file or bundle")
        }

        if item.url != nil && requiresProvenance(contentMode: item.contentMode) {
            return .required("Scientific Inspector content")
        }

        return .notRequired
    }

    func audit(_ item: ProvenanceInspectableItem) -> ProvenanceAuditResult {
        let requirement = requirement(for: item)
        guard let url = item.url else {
            guard !requirement.isNotRequired else { return .notRequired }
            return ProvenanceAuditResult(
                status: .missing,
                requirement: requirement,
                sidecarURL: nil,
                messages: ["No selected file or bundle URL is available for provenance lookup."]
            )
        }

        _ = try? MetagenomicsBatchProvenanceWriter.ensureEsVirituBatchProvenanceIfPossible(batchRoot: url)
        _ = try? MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(resultDirectory: url)
        guard let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: url) else {
            guard !requirement.isNotRequired else { return .notRequired }
            return ProvenanceAuditResult(
                status: .missing,
                requirement: requirement,
                sidecarURL: nil,
                messages: ["No provenance sidecar was found for \(url.lastPathComponent)."]
            )
        }

        let completenessMessages = completenessIssues(in: resolved.envelope)
        if !completenessMessages.isEmpty {
            return ProvenanceAuditResult(
                status: .incomplete,
                requirement: requirement,
                sidecarURL: resolved.sidecarURL,
                messages: completenessMessages
            )
        }

        return ProvenanceAuditResult(
            status: .present,
            requirement: requirement,
            sidecarURL: resolved.sidecarURL,
            messages: []
        )
    }

    private func requiresProvenance(_ type: SidebarItemType) -> Bool {
        switch type {
        case .sequence,
             .annotation,
             .alignment,
             .coverage,
             .referenceBundle,
             .mhcReferenceBundle,
             .multipleSequenceAlignmentBundle,
             .phylogeneticTreeBundle,
             .fastqBundle,
             .primerSchemeBundle,
             .genotypeResultBundle,
             .twelveSAmpliconResultBundle,
             .classificationResult,
             .esvirituResult,
             .taxTriageResult,
             .naoMgsResult,
             .nvdResult,
             .czIdResult,
             .analysisResult:
            return true
        case .group,
             .folder,
             .project,
             .document,
             .image,
             .unknown,
             .batchGroup:
            return false
        }
    }

    private func requiresProvenance(url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        if filename.hasSuffix(".fastq.gz") || filename.hasSuffix(".fq.gz") {
            return true
        }
        if filename.hasSuffix(".fasta.gz")
            || filename.hasSuffix(".fa.gz")
            || filename.hasSuffix(".vcf.gz") {
            return true
        }
        let pathExtension = url.pathExtension.lowercased()
        return scientificExtensions.contains(pathExtension)
    }

    private func requiresProvenance(contentMode: ViewportContentMode) -> Bool {
        switch contentMode {
        case .genomics, .mapping, .assembly, .fastq, .metagenomics, .genotype:
            return true
        case .empty:
            return false
        }
    }

    private func completenessIssues(in envelope: ProvenanceEnvelope) -> [String] {
        var issues: [String] = []

        if envelope.workflowName.isBlankOrUnknown {
            issues.append("Workflow name is missing.")
        }
        if envelope.workflowVersion.isBlankOrUnknown {
            issues.append("Workflow version is missing.")
        }
        if envelope.toolName.isBlankOrUnknown {
            issues.append("Tool name is missing.")
        }
        if envelope.toolVersion.isBlankOrUnknown {
            issues.append("Tool version is missing.")
        }
        if envelope.argv.isEmpty && envelope.reproducibleCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Exact argv or reproducible command is missing.")
        }
        if envelope.files.isEmpty {
            issues.append("Input/reference/output file descriptors are missing.")
        }
        if envelope.output == nil && envelope.outputs.isEmpty && !envelope.files.contains(where: { $0.role == .output }) {
            issues.append("Output descriptors are missing.")
        }
        if envelope.steps.isEmpty {
            issues.append("Workflow step list is missing.")
        }
        if envelope.exitStatus == nil {
            issues.append("Exit status is missing.")
        }
        if envelope.wallTimeSeconds == nil {
            issues.append("Wall time is missing.")
        }
        if let exitStatus = envelope.exitStatus,
           exitStatus != 0,
           envelope.stderr == nil {
            issues.append("stderr is missing for the failed workflow.")
        }
        if envelope.steps.contains(where: { ($0.exitStatus ?? 0) != 0 && $0.stderr == nil }) {
            issues.append("stderr is missing for one or more failed workflow steps.")
        }

        let descriptorIssues = missingFileMetadataDescriptors(in: envelope)
        if !descriptorIssues.isEmpty {
            issues.append(missingFileMetadataMessage(for: descriptorIssues))
        }

        return Array(OrderedSet(issues))
    }

    private func allFileDescriptors(in envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
        envelope.files
            + (envelope.output.map { [$0] } ?? [])
            + envelope.outputs
            + envelope.steps.flatMap { $0.inputs + $0.outputs }
    }

    private func descriptorLooksLikeDirectory(_ descriptor: ProvenanceFileDescriptor) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: descriptor.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func missingFileMetadataDescriptors(in envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
        let failedOutputPaths = Set(
            envelope.steps
                .filter { ($0.exitStatus ?? 0) != 0 }
                .flatMap { $0.outputs.map(\.path) }
        )
        var seen = Set<String>()
        return allFileDescriptors(in: envelope).filter { descriptor in
            let path = descriptor.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !descriptorLooksLikeDirectory(descriptor) else { return false }
            guard descriptor.checksumSHA256 == nil || descriptor.fileSize == nil else { return false }
            if failedOutputPaths.contains(descriptor.path),
               !FileManager.default.fileExists(atPath: descriptor.path) {
                return false
            }
            return seen.insert(descriptor.path).inserted
        }
    }

    private func missingFileMetadataMessage(for descriptors: [ProvenanceFileDescriptor]) -> String {
        let count = descriptors.count
        let examples = descriptors.prefix(4).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        let remaining = count - examples.count
        let suffix = remaining > 0 ? " and \(remaining) more" : ""
        let noun = count == 1 ? "file descriptor" : "file descriptors"
        return "Missing checksum or size for \(count) \(noun): \(examples.joined(separator: ", "))\(suffix)."
    }
}

struct ProvenanceWarningRow: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

struct ProvenanceRunSummary: Equatable {
    var workflowName: String = "No Provenance"
    var workflowVersion: String = ""
    var toolName: String = ""
    var toolVersion: String = ""
    var createdAt: Date?
    var schemaVersion: Int?
    var runID: UUID?
    var sidecarPath: String?
    var statusLabel: String = "No provenance required"
    var exitStatus: Int?
    var wallTimeSeconds: TimeInterval?
    var stepCount: Int = 0
    var inputCount: Int = 0
    var outputCount: Int = 0
    var signatureCount: Int = 0
}

struct ProvenanceLineageRun: Identifiable, Equatable {
    var id: UUID
    var title: String
    var subtitle: String
    var steps: [ProvenanceLineageStep]
}

struct ProvenanceLineageStep: Identifiable, Equatable {
    var id: UUID
    var ordinal: Int
    var toolName: String
    var toolVersion: String
    var command: String
    var inputPaths: [String]
    var outputPaths: [String]
    var exitStatus: Int?
    var wallTimeSeconds: TimeInterval?
    var stderr: String?
    var dependsOn: [UUID]
}

struct ProvenanceFileRow: Identifiable, Equatable {
    var id: String { "\(role)|\(path)" }
    var role: String
    var path: String
    var displayPath: String
    var checksumSHA256: String?
    var fileSize: UInt64?
    var fileSizeLabel: String
    var format: String?
    var originPath: String?
    var sourceProvenancePath: String?
    var searchText: String = ""
    var isCollapsedGroup: Bool = false
}

struct ProvenanceOptionRow: Identifiable, Equatable {
    var id: String { "\(kind)|\(name)" }
    var kind: String
    var name: String
    var value: String
}

struct ProvenanceRuntimeRow: Identifiable, Equatable {
    var id: String { label }
    var label: String
    var value: String
}

@Observable
@MainActor
final class ProvenanceInspectorViewModel {
    private static let maximumDisplayedFileRows = 500
    private static let maximumDisplayedStepPaths = 200

    var currentItem: ProvenanceInspectableItem?
    var audit: ProvenanceAuditResult = .notRequired
    var summary = ProvenanceRunSummary()
    var warnings: [ProvenanceWarningRow] = []
    var lineageRuns: [ProvenanceLineageRun] = []
    var fileRows: [ProvenanceFileRow] = []
    var optionRows: [ProvenanceOptionRow] = []
    var runtimeRows: [ProvenanceRuntimeRow] = []
    var rawJSON: String = ""
    var copyableText: String = ""
    var resolvedEnvelope: ProvenanceEnvelope?
    var resolvedSidecarURL: URL?
    var searchText: String = ""
    var isLoading: Bool = false
    var onExportRequested: ((ProvenanceExportFormat) -> Void)?

    private let monitor: ProvenanceCoverageMonitor

    /// Bumped on every `load(item:)`/`clear()` call. Captured synchronously by `load(item:)`
    /// before the background lookup starts; the detached lookup's result is only applied to
    /// `@Published`-style state if this generation still matches when it completes, so a
    /// superseded lookup from rapid sidebar navigation cannot overwrite a newer selection's
    /// result. Idiom: `SequenceViewerView.fastaOperationFetchGeneration`.
    private var loadGeneration: Int = 0

    init(monitor: ProvenanceCoverageMonitor = ProvenanceCoverageMonitor()) {
        self.monitor = monitor
    }

    var shouldShowTab: Bool {
        audit.status != .notRequired
    }

    func clear() {
        loadGeneration += 1
        isLoading = false
        currentItem = nil
        audit = .notRequired
        summary = ProvenanceRunSummary()
        warnings = []
        lineageRuns = []
        fileRows = []
        optionRows = []
        runtimeRows = []
        rawJSON = ""
        copyableText = ""
        resolvedEnvelope = nil
        resolvedSidecarURL = nil
        searchText = ""
    }

    /// Updates the inspected item and asynchronously resolves its provenance state.
    ///
    /// Synchronous and non-`async` (called from many synchronous sidebar-selection call
    /// sites -- `InspectorViewController+Notifications.swift`, `+PublicAPI.swift` -- with no
    /// `async` entry point on the AppKit side). `currentItem` and `isLoading` update
    /// immediately so the UI reflects the new selection without delay; the actual sidecar
    /// lookup (up to 5 parent-directory levels, each trying several candidate sidecar paths
    /// via `fileExists` + `Data(contentsOf:)` + `JSONDecoder`) and envelope presentation
    /// build run inside `Task.detached`, off the main actor, matching
    /// `ReferenceBundleAnnotationImportService.attachAnnotationTrack`'s structural hop: a
    /// nonisolated `async` function with no suspension point before its synchronous work
    /// inherits the caller's thread when awaited directly from `@MainActor` code, so
    /// `Task.detached` -- not just removing `@MainActor` -- is what actually forces the work
    /// off-main. The result is only applied back on the main actor if `loadGeneration` still
    /// matches the generation captured when this call started, so a superseded lookup from
    /// rapid arrow-key/click navigation cannot overwrite a newer selection's result.
    func load(item: ProvenanceInspectableItem, clearWhenUnavailable: Bool = false) {
        loadGeneration += 1
        let thisGeneration = loadGeneration
        currentItem = item
        isLoading = true

        let monitor = self.monitor
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                await Self.performLookup(item: item, monitor: monitor)
            }.value

            guard let self, thisGeneration == self.loadGeneration else { return }
            self.isLoading = false
            if clearWhenUnavailable, outcome.resolvedEnvelope == nil {
                self.clear()
            } else {
                self.apply(outcome, item: item)
            }
        }
    }

    /// The heavy, off-main portion of `load(item:)`: coverage audit (which may write missing
    /// sidecars via `MetagenomicsBatchProvenanceWriter`), the multi-level sidecar directory
    /// walk (`ProvenanceRecorder.findProvenanceEnvelope`), and JSON decode of the resolved
    /// envelope. Pure with respect to `self` -- takes a value-type snapshot of `item` and
    /// `monitor` and returns a value-type outcome -- so it is safe to run detached from the
    /// cooperative thread pool. `nonisolated` so it carries no actor isolation of its own;
    /// callers are responsible for the `Task.detached` hop (see `load(item:)`).
    nonisolated private static func performLookup(
        item: ProvenanceInspectableItem,
        monitor: ProvenanceCoverageMonitor
    ) async -> LookupOutcome {
        #if DEBUG
        loadThreadingProbe?()
        await loadFetchGate?()
        #endif
        let audit = monitor.audit(item)
        guard let url = item.url,
              let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: url) else {
            return LookupOutcome(audit: audit, resolvedEnvelope: nil, resolvedSidecarURL: nil)
        }
        return LookupOutcome(audit: audit, resolvedEnvelope: resolved.envelope, resolvedSidecarURL: resolved.sidecarURL)
    }

    private struct LookupOutcome: Sendable {
        var audit: ProvenanceAuditResult
        var resolvedEnvelope: ProvenanceEnvelope?
        var resolvedSidecarURL: URL?
    }

    /// Applies a completed off-main lookup's result to published state. Must only be called
    /// after the caller has confirmed `loadGeneration` still matches.
    private func apply(_ outcome: LookupOutcome, item: ProvenanceInspectableItem) {
        audit = outcome.audit
        guard let envelope = outcome.resolvedEnvelope, let sidecarURL = outcome.resolvedSidecarURL else {
            resolvedEnvelope = nil
            resolvedSidecarURL = nil
            buildMissingState(item: item)
            return
        }

        resolvedEnvelope = envelope
        resolvedSidecarURL = sidecarURL
        buildPresentState(envelope: envelope, sidecarURL: sidecarURL)
    }

    #if DEBUG
    /// Test-only threading probe. Invoked once at the start of `performLookup`, inside the
    /// `Task.detached` body -- i.e. after the executor hop `load(item:)` relies on for
    /// main-thread safety, and before `ProvenanceCoverageMonitor.audit`/
    /// `ProvenanceRecorder.findProvenanceEnvelope` run. Exists solely so
    /// `ProvenanceInspectorViewModelOffMainTests` can assert `!Thread.isMainThread` from
    /// inside the real call path when driven from a `@MainActor` caller. Idiom:
    /// `ReferenceBundleAnnotationImportService.threadingProbe`. Not compiled into release
    /// builds.
    nonisolated(unsafe) static var loadThreadingProbe: (@Sendable () -> Void)?

    /// Test seam: an optional async gate awaited inside `performLookup`, immediately after
    /// `loadThreadingProbe` fires and before the real sidecar walk/decode runs. Lets a test
    /// deterministically hold one in-flight lookup suspended while a second, superseding
    /// `load(item:)` call completes first and bumps `loadGeneration` -- then release the first
    /// lookup and assert its stale result is discarded by the generation guard. `nil` by
    /// default (no-op). Idiom: `SequenceViewerView.fastaOperationFetchGate`. Debug-only.
    nonisolated(unsafe) static var loadFetchGate: (@Sendable () async -> Void)?
    #endif

    func export(format: ProvenanceExportFormat) {
        onExportRequested?(format)
    }

    private func buildMissingState(item: ProvenanceInspectableItem) {
        let title = item.displayName ?? item.url?.lastPathComponent ?? "Selection"
        let statusLabel: String
        switch audit.status {
        case .missing:
            statusLabel = "Missing provenance"
        case .notRequired:
            statusLabel = "No provenance required"
        default:
            statusLabel = audit.status.rawValue.capitalized
        }
        summary = ProvenanceRunSummary(
            workflowName: title,
            statusLabel: statusLabel
        )
        warnings = warningRows(for: audit)
        if warnings.isEmpty && audit.status == .missing {
            warnings = [
                ProvenanceWarningRow(
                    title: "Missing provenance",
                    message: "This scientific bundle/result is required to have a complete provenance sidecar."
                )
            ]
        }
        lineageRuns = []
        fileRows = []
        optionRows = []
        runtimeRows = []
        rawJSON = ""
        copyableText = warnings.map { "\($0.title)\n\($0.message)" }.joined(separator: "\n\n")
    }

    private func buildPresentState(envelope: ProvenanceEnvelope, sidecarURL: URL) {
        let deduplicatedDescriptors = deduplicatedFileDescriptors(allFileDescriptors(in: envelope))
        let fastqPresentation = ProvenanceFASTQBundlePresentation(
            envelope: envelope,
            descriptors: deduplicatedDescriptors
        )
        let completeFileRows = buildFileRows(
            deduplicatedDescriptors,
            fastqPresentation: fastqPresentation
        )
        let presentationWarnings = largeRecordWarningRows(
            fileRowCount: deduplicatedDescriptors.count,
            envelope: envelope
        )
        summary = ProvenanceRunSummary(
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            createdAt: envelope.createdAt,
            schemaVersion: envelope.schemaVersion,
            runID: envelope.id,
            sidecarPath: sidecarURL.path,
            statusLabel: audit.status == .present ? "Complete" : audit.status.rawValue.capitalized,
            exitStatus: envelope.exitStatus,
            wallTimeSeconds: envelope.wallTimeSeconds,
            stepCount: envelope.steps.count,
            inputCount: inputDescriptors(in: envelope).count,
            outputCount: outputDescriptors(in: envelope).count,
            signatureCount: envelope.signatures.count
        )
        warnings = warningRows(for: audit)
            + stepWarningRows(for: envelope)
            + fastqPresentation.warningRows()
            + presentationWarnings
        lineageRuns = [
            ProvenanceLineageRun(
                id: envelope.id,
                title: envelope.workflowName,
                subtitle: "\(envelope.toolName) \(envelope.toolVersion)",
                steps: envelope.steps.enumerated().map { index, step in
                    ProvenanceLineageStep(
                        id: step.id,
                        ordinal: index + 1,
                        toolName: step.toolName,
                        toolVersion: step.toolVersion,
                        command: step.reproducibleCommand,
                        inputPaths: cappedPresentationPathList(
                            step.inputs,
                            fastqPresentation: fastqPresentation
                        ),
                        outputPaths: cappedPathList(step.outputs.map(\.path)),
                        exitStatus: step.exitStatus,
                        wallTimeSeconds: step.wallTimeSeconds,
                        stderr: step.stderr?.strippingANSIEscapeSequences(),
                        dependsOn: step.dependsOn
                    )
                }
            )
        ]
        fileRows = Array(completeFileRows.prefix(Self.maximumDisplayedFileRows))
        optionRows = buildOptionRows(envelope.options)
        runtimeRows = buildRuntimeRows(envelope.runtimeIdentity)
        rawJSON = shouldInlineRawJSON(fileRowCount: deduplicatedDescriptors.count, envelope: envelope)
            ? encodedJSON(envelope)
            : ""
        copyableText = buildCopyableText()
    }

    private func warningRows(for audit: ProvenanceAuditResult) -> [ProvenanceWarningRow] {
        audit.messages.map {
            ProvenanceWarningRow(title: warningTitle(for: audit.status, message: $0), message: $0)
        }
    }

    private func warningTitle(for status: ProvenanceAuditStatus, message: String) -> String {
        if message.hasPrefix("Missing checksum or size") {
            return "File metadata incomplete"
        }
        switch status {
        case .missing:
            return "Missing provenance"
        case .invalid:
            return "Invalid provenance"
        case .incomplete:
            return "Incomplete provenance"
        case .stale:
            return "Stale provenance"
        case .legacy:
            return "Legacy provenance"
        case .notRequired, .present:
            return "Provenance"
        }
    }

    private func stepWarningRows(for envelope: ProvenanceEnvelope) -> [ProvenanceWarningRow] {
        envelope.steps.compactMap { step in
            guard let exitStatus = step.exitStatus, exitStatus != 0 else { return nil }
            let stepName = step.toolName.isBlankOrUnknown ? "Workflow step" : step.toolName
            return ProvenanceWarningRow(
                title: "Step exited non-zero",
                message: "\(stepName) exited with status \(exitStatus); see stderr in Lineage for details."
            )
        }
    }

    private func inputDescriptors(in envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
        deduplicatedFileDescriptors(
            allFileDescriptors(in: envelope).filter {
                $0.role == .input || $0.role == .reference || $0.role == .index
            }
        )
    }

    private func outputDescriptors(in envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
        deduplicatedFileDescriptors(
            allFileDescriptors(in: envelope).filter {
                $0.role == .output || $0.role == .report || $0.role == .log
            }
        )
    }

    private func allFileDescriptors(in envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
        envelope.files
            + (envelope.output.map { [$0] } ?? [])
            + envelope.outputs
            + envelope.steps.flatMap { $0.inputs + $0.outputs }
    }

    private func deduplicatedFileDescriptors(_ descriptors: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        return descriptors.filter { descriptor in
            let key = "\(descriptor.role.rawValue)|\(descriptor.path)"
            return seen.insert(key).inserted
        }
    }

    private func buildFileRows(
        _ descriptors: [ProvenanceFileDescriptor],
        fastqPresentation: ProvenanceFASTQBundlePresentation
    ) -> [ProvenanceFileRow] {
        var rows: [ProvenanceFileRow] = []
        var emittedFASTQBundles = Set<String>()

        for descriptor in descriptors {
            if let group = fastqPresentation.group(for: descriptor) {
                guard emittedFASTQBundles.insert(group.bundlePath).inserted else { continue }
                rows.append(
                    ProvenanceFileRow(
                        role: descriptor.role.displayName,
                        path: group.bundlePath,
                        displayPath: group.bundleName,
                        checksumSHA256: nil,
                        fileSize: group.totalBytes,
                        fileSizeLabel: group.fileSizeLabel,
                        format: "FASTQ bundle",
                        originPath: nil,
                        sourceProvenancePath: nil,
                        searchText: group.searchText,
                        isCollapsedGroup: true
                    )
                )
                continue
            }

            rows.append(
                ProvenanceFileRow(
                    role: descriptor.role.displayName,
                    path: descriptor.path,
                    displayPath: descriptor.path.middleTruncatedPath(),
                    checksumSHA256: descriptor.checksumSHA256,
                    fileSize: descriptor.fileSize,
                    fileSizeLabel: descriptor.fileSize.map(LungfishFormatters.formatBytes) ?? "Size not recorded",
                    format: descriptor.format?.rawValue,
                    originPath: descriptor.originPath,
                    sourceProvenancePath: descriptor.sourceProvenancePath
                )
            )
        }

        return rows.sorted { lhs, rhs in
            if lhs.role == rhs.role {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            return lhs.role < rhs.role
        }
    }

    private func cappedPresentationPathList(
        _ descriptors: [ProvenanceFileDescriptor],
        fastqPresentation: ProvenanceFASTQBundlePresentation
    ) -> [String] {
        var paths: [String] = []
        var emittedFASTQBundles = Set<String>()
        var emittedPaths = Set<String>()

        for descriptor in descriptors {
            if let group = fastqPresentation.group(for: descriptor) {
                guard emittedFASTQBundles.insert(group.bundlePath).inserted else { continue }
                paths.append(group.pathListLabel)
                continue
            }

            guard emittedPaths.insert(descriptor.path).inserted else { continue }
            paths.append(descriptor.path)
        }

        return cappedPathList(paths)
    }

    private func cappedPathList(_ paths: [String]) -> [String] {
        guard paths.count > Self.maximumDisplayedStepPaths else {
            return paths
        }
        let remaining = paths.count - Self.maximumDisplayedStepPaths
        return Array(paths.prefix(Self.maximumDisplayedStepPaths)) + [
            "... \(remaining) more paths omitted from Inspector display; use Export for the complete provenance JSON.",
        ]
    }

    private func largeRecordWarningRows(
        fileRowCount: Int,
        envelope: ProvenanceEnvelope
    ) -> [ProvenanceWarningRow] {
        let hasLargePathList = envelope.steps.contains {
            $0.inputs.count > Self.maximumDisplayedStepPaths
                || $0.outputs.count > Self.maximumDisplayedStepPaths
        }
        guard fileRowCount > Self.maximumDisplayedFileRows || hasLargePathList else {
            return []
        }
        return [
            ProvenanceWarningRow(
                title: "Large provenance record",
                message: "Inspector display is capped at \(Self.maximumDisplayedFileRows) file rows and \(Self.maximumDisplayedStepPaths) paths per step; use Export for the complete provenance JSON."
            ),
        ]
    }

    private func shouldInlineRawJSON(fileRowCount: Int, envelope: ProvenanceEnvelope) -> Bool {
        guard fileRowCount <= Self.maximumDisplayedFileRows else {
            return false
        }
        return !envelope.steps.contains {
            $0.inputs.count > Self.maximumDisplayedStepPaths
                || $0.outputs.count > Self.maximumDisplayedStepPaths
        }
    }

    private func buildOptionRows(_ options: ProvenanceOptions) -> [ProvenanceOptionRow] {
        rows(from: options.explicit, kind: "Explicit")
            + rows(from: options.defaults, kind: "Default")
            + rows(from: options.resolvedDefaults, kind: "Resolved Default")
    }

    private func rows(from values: [String: ParameterValue], kind: String) -> [ProvenanceOptionRow] {
        values.keys.sorted().map { key in
            ProvenanceOptionRow(kind: kind, name: key, value: values[key]?.displayValue ?? "")
        }
    }

    private func buildRuntimeRows(_ runtime: ProvenanceRuntimeIdentity) -> [ProvenanceRuntimeRow] {
        var rows: [ProvenanceRuntimeRow] = [
            ProvenanceRuntimeRow(label: "App Version", value: runtime.appVersion),
            ProvenanceRuntimeRow(label: "Executable", value: runtime.executablePath),
            ProvenanceRuntimeRow(label: "Process ID", value: "\(runtime.processIdentifier)"),
            ProvenanceRuntimeRow(label: "OS", value: runtime.operatingSystemVersion),
            ProvenanceRuntimeRow(label: "Architecture", value: runtime.architecture),
        ]
        appendOptional("Git Revision", runtime.gitRevision, to: &rows)
        appendOptional("User", runtime.user, to: &rows)
        appendOptional("Conda Environment", runtime.condaEnvironment, to: &rows)
        appendOptional("Conda Prefix", runtime.condaPrefix, to: &rows)
        appendOptional("Plugin Pack", runtime.pluginPack, to: &rows)
        appendOptional("Container Image", runtime.containerImage, to: &rows)
        appendOptional("Container Digest", runtime.containerDigest, to: &rows)
        appendOptional("Dependency Set", runtime.dependencySet, to: &rows)
        return rows
    }

    private func appendOptional(_ label: String, _ value: String?, to rows: inout [ProvenanceRuntimeRow]) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rows.append(ProvenanceRuntimeRow(label: label, value: value))
    }

    private func encodedJSON(_ envelope: ProvenanceEnvelope) -> String {
        guard let data = try? ProvenanceJSON.encoder.encode(envelope) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func buildCopyableText() -> String {
        var sections: [String] = []

        sections.append(
            labeledLines(
                title: "Run Summary",
                rows: [
                    ("Workflow", summary.workflowName),
                    ("Workflow Version", summary.workflowVersion),
                    ("Tool", summary.toolVersion.isEmpty ? summary.toolName : "\(summary.toolName) \(summary.toolVersion)"),
                    ("Created", summary.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? ""),
                    ("Exit Status", summary.exitStatus.map(String.init) ?? ""),
                    ("Wall Time", summary.wallTimeSeconds.map { "\(String(format: "%.2f", $0)) s" } ?? ""),
                    ("Steps", "\(summary.stepCount)"),
                    ("Inputs", "\(summary.inputCount)"),
                    ("Outputs", "\(summary.outputCount)"),
                    ("Sidecar", summary.sidecarPath ?? ""),
                ]
            )
        )

        if !warnings.isEmpty {
            sections.append(
                "Warnings\n" + warnings.map { "\($0.title): \($0.message)" }.joined(separator: "\n")
            )
        }

        if !lineageRuns.isEmpty {
            var lines = ["Lineage"]
            for run in lineageRuns {
                lines.append("\(run.title) - \(run.subtitle)")
                for step in run.steps {
                    lines.append("\(step.ordinal). \(step.toolName) \(step.toolVersion)".trimmingCharacters(in: .whitespaces))
                    appendIfPresent("Command", step.command, to: &lines)
                    appendList("Inputs", step.inputPaths, to: &lines)
                    appendList("Outputs", step.outputPaths, to: &lines)
                    appendIfPresent("Exit Status", step.exitStatus.map(String.init) ?? "", to: &lines)
                    appendIfPresent("Wall Time", step.wallTimeSeconds.map { "\(String(format: "%.2f", $0)) s" } ?? "", to: &lines)
                    appendIfPresent("stderr", step.stderr ?? "", to: &lines)
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if !fileRows.isEmpty {
            var lines = ["Files & Outputs"]
            for row in fileRows {
                lines.append("\(row.role): \(row.path)")
                lines.append("  \(fileMetadataSummary(for: row))")
                appendIfPresent("  sha256", row.checksumSHA256 ?? "", to: &lines)
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if !optionRows.isEmpty {
            sections.append(
                labeledLines(
                    title: "Invocation & Options",
                    rows: optionRows.map { ("\($0.name) (\($0.kind))", $0.value) }
                )
            )
        }

        if !runtimeRows.isEmpty {
            sections.append(labeledLines(title: "Runtime", rows: runtimeRows.map { ($0.label, $0.value) }))
        }

        return sections
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private func labeledLines(title: String, rows: [(String, String)]) -> String {
        var lines = [title]
        for row in rows {
            appendIfPresent(row.0, row.1, to: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private func appendList(_ label: String, _ values: [String], to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("\(label):")
        lines.append(contentsOf: values.map { "  \($0)" })
    }

    private func appendIfPresent(_ label: String, _ value: String, to lines: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append("\(label): \(value)")
    }

    private func fileMetadataSummary(for row: ProvenanceFileRow) -> String {
        var parts = [row.fileSizeLabel]
        if let format = row.format, !format.isEmpty {
            parts.append("Format: \(format)")
        }
        return parts.joined(separator: " | ")
    }

}

private struct ProvenanceFASTQBundlePresentation {
    struct Group: Equatable {
        var bundlePath: String
        var bundleName: String
        var chunkDescriptorCount: Int
        var totalBytes: UInt64?
        var searchText: String

        var fileSizeLabel: String {
            let chunkLabel = "\(chunkDescriptorCount) FASTQ \(chunkDescriptorCount == 1 ? "chunk" : "chunks")"
            guard let totalBytes else { return chunkLabel }
            return "\(chunkLabel) | \(LungfishFormatters.formatBytes(totalBytes))"
        }

        var pathListLabel: String {
            let chunkLabel = "\(chunkDescriptorCount) FASTQ \(chunkDescriptorCount == 1 ? "chunk" : "chunks")"
            guard let totalBytes else { return "\(bundleName) - \(chunkLabel)" }
            return "\(bundleName) - \(chunkLabel) (\(LungfishFormatters.formatBytes(totalBytes)))"
        }
    }

    private struct Accumulator {
        var bundlePath: String
        var paths: [String] = []
        var totalBytes: UInt64 = 0
        var hasKnownSize = false

        mutating func add(_ descriptor: ProvenanceFileDescriptor) {
            paths.append(descriptor.path)
            if let fileSize = descriptor.fileSize {
                totalBytes += fileSize
                hasKnownSize = true
            }
        }

        func group() -> Group {
            Group(
                bundlePath: bundlePath,
                bundleName: URL(fileURLWithPath: bundlePath).lastPathComponent,
                chunkDescriptorCount: paths.count,
                totalBytes: hasKnownSize ? totalBytes : nil,
                searchText: ([bundlePath] + paths).joined(separator: "\n")
            )
        }
    }

    private var bundlePathByDescriptorPath: [String: String] = [:]
    private var groupsByBundlePath: [String: Group] = [:]

    init(envelope: ProvenanceEnvelope, descriptors: [ProvenanceFileDescriptor]) {
        var bundleCandidates = Self.bundleCandidatePaths(from: envelope)
        for descriptor in descriptors where Self.isFASTQInput(descriptor) {
            if let bundlePath = Self.enclosingFASTQBundlePath(for: descriptor.path) {
                bundleCandidates.insert(bundlePath)
            }
        }

        var manifestBundlePathByDescriptorPath: [String: String] = [:]
        for bundlePath in bundleCandidates {
            Self.addManifestMapping(
                bundlePath: bundlePath,
                to: &manifestBundlePathByDescriptorPath
            )
        }

        var accumulators: [String: Accumulator] = [:]
        var seenDescriptorKeys = Set<String>()
        for descriptor in descriptors where Self.isFASTQInput(descriptor) {
            guard let bundlePath = manifestBundlePathByDescriptorPath[Self.standardizedPath(descriptor.path)]
                    ?? Self.enclosingFASTQBundlePath(for: descriptor.path) else {
                continue
            }
            let descriptorPath = Self.standardizedPath(descriptor.path)
            let key = "\(bundlePath)\u{0}\(descriptorPath)"
            guard seenDescriptorKeys.insert(key).inserted else { continue }

            bundlePathByDescriptorPath[descriptorPath] = bundlePath
            accumulators[bundlePath, default: Accumulator(bundlePath: bundlePath)].add(descriptor)
        }

        groupsByBundlePath = accumulators.mapValues { $0.group() }
    }

    func group(for descriptor: ProvenanceFileDescriptor) -> Group? {
        guard Self.isFASTQInput(descriptor),
              let bundlePath = bundlePathByDescriptorPath[Self.standardizedPath(descriptor.path)] else {
            return nil
        }
        return groupsByBundlePath[bundlePath]
    }

    func warningRows() -> [ProvenanceWarningRow] {
        let groups = groupsByBundlePath.values
            .filter { $0.chunkDescriptorCount > 1 }
            .sorted { $0.bundlePath.localizedStandardCompare($1.bundlePath) == .orderedAscending }
        guard !groups.isEmpty else { return [] }

        let chunkCount = groups.reduce(0) { $0 + $1.chunkDescriptorCount }
        let bundleList = groups
            .map { "\($0.bundleName) (\($0.chunkDescriptorCount) \(($0.chunkDescriptorCount == 1 ? "chunk" : "chunks")))" }
            .joined(separator: ", ")
        return [
            ProvenanceWarningRow(
                title: "FASTQ chunks collapsed",
                message: "Inspector grouped \(chunkCount) FASTQ chunk descriptors into \(bundleList). The complete provenance JSON still contains every per-chunk path, size, and checksum for export and replay."
            ),
        ]
    }

    private static func bundleCandidatePaths(from envelope: ProvenanceEnvelope) -> Set<String> {
        var candidates = Set<String>()
        let optionValues = Array(envelope.options.explicit.values)
            + Array(envelope.options.defaults.values)
            + Array(envelope.options.resolvedDefaults.values)
        for value in optionValues {
            for path in pathStrings(from: value) {
                if let bundlePath = enclosingFASTQBundlePath(for: path) {
                    candidates.insert(bundlePath)
                }
            }
        }
        for argument in envelope.argv {
            if let bundlePath = enclosingFASTQBundlePath(for: argument) {
                candidates.insert(bundlePath)
            }
        }
        return candidates
    }

    private static func pathStrings(from value: ParameterValue) -> [String] {
        switch value {
        case .string(let string):
            return [string]
        case .file(let url):
            return [url.path]
        case .array(let values):
            return values.flatMap(pathStrings)
        case .dictionary(let values):
            return values.values.flatMap(pathStrings)
        case .integer, .number, .boolean, .null:
            return []
        }
    }

    private static func addManifestMapping(
        bundlePath: String,
        to mapping: inout [String: String]
    ) {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        mapping[standardizedPath(bundlePath)] = bundlePath
        guard let manifest = try? FASTQSourceFileManifest.load(from: bundleURL) else { return }
        for entry in manifest.files {
            if let bundledURL = try? FASTQBundle.validatedBundleMemberURL(
                for: entry.filename,
                in: bundleURL,
                field: "source-files[].filename",
                allowExistingSymlinkEscape: true
            ) {
                mapping[standardizedPath(bundledURL.path)] = bundlePath
            }
            if !entry.originalPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                mapping[standardizedPath(entry.originalPath)] = bundlePath
            }
        }
    }

    private static func isFASTQInput(_ descriptor: ProvenanceFileDescriptor) -> Bool {
        guard descriptor.role == .input else { return false }
        if descriptor.format == .fastq { return true }
        let filename = URL(fileURLWithPath: descriptor.path).lastPathComponent.lowercased()
        return filename.hasSuffix(".fastq")
            || filename.hasSuffix(".fq")
            || filename.hasSuffix(".fastq.gz")
            || filename.hasSuffix(".fq.gz")
    }

    private static func enclosingFASTQBundlePath(for path: String) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".lungfishfastq") }) else {
            return nil
        }
        let bundleComponents = Array(components.prefix(index + 1))
        let bundlePath = NSString.path(withComponents: bundleComponents)
        return standardizedPath(bundlePath)
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

private extension String {
    var isBlankOrUnknown: Bool {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "unknown"
    }

    func middleTruncatedPath(maxLength: Int = 64) -> String {
        guard count > maxLength, maxLength > 12 else { return self }
        let headCount = max(4, maxLength / 2 - 2)
        let tailCount = max(4, maxLength - headCount - 1)
        return "\(prefix(headCount))...\(suffix(tailCount))"
    }

    func strippingANSIEscapeSequences() -> String {
        let escape = "\u{001B}"
        let bell = "\u{0007}"
        let pattern = "\(escape)(?:\\[[0-?]*[ -/]*[@-~]|\\][^\(bell)\(escape)]*(?:\(bell)|\(escape)\\\\)|[@-Z\\\\-_])"
        return replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}

private extension FileRole {
    var displayName: String {
        switch self {
        case .input: return "Input"
        case .output: return "Output"
        case .reference: return "Reference"
        case .index: return "Index"
        case .log: return "Log"
        case .report: return "Report"
        }
    }
}

private extension ParameterValue {
    var displayValue: String {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return "\(value)"
        case .number(let value):
            return "\(value)"
        case .boolean(let value):
            return value ? "true" : "false"
        case .file(let value):
            return value.path
        case .array(let values):
            return values.map(\.displayValue).joined(separator: ", ")
        case .dictionary(let values):
            return values.keys.sorted().map { "\($0): \(values[$0]?.displayValue ?? "")" }.joined(separator: ", ")
        case .null:
            return "null"
        }
    }
}

private struct OrderedSet<Element: Hashable>: Swift.Sequence {
    private let values: [Element]

    init(_ input: [Element]) {
        var seen = Set<Element>()
        values = input.filter { seen.insert($0).inserted }
    }

    func makeIterator() -> IndexingIterator<[Element]> {
        values.makeIterator()
    }
}
