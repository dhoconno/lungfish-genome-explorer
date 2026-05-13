// ProvenanceInspectorViewModel.swift - Generic Inspector provenance presentation model
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI
import LungfishCore
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

        _ = MetagenomicsBatchProvenanceWriter.ensureEsVirituBatchProvenanceIfPossible(batchRoot: url)
        _ = MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(resultDirectory: url)
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
             .multipleSequenceAlignmentBundle,
             .phylogeneticTreeBundle,
             .fastqBundle,
             .primerSchemeBundle,
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
        case .genomics, .mapping, .assembly, .fastq, .metagenomics:
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
        if envelope.stderr == nil {
            issues.append("stderr is missing; use an explicit empty value when no stderr was emitted.")
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
    var currentItem: ProvenanceInspectableItem?
    var audit: ProvenanceAuditResult = .notRequired
    var summary = ProvenanceRunSummary()
    var warnings: [ProvenanceWarningRow] = []
    var lineageRuns: [ProvenanceLineageRun] = []
    var fileRows: [ProvenanceFileRow] = []
    var optionRows: [ProvenanceOptionRow] = []
    var runtimeRows: [ProvenanceRuntimeRow] = []
    var rawJSON: String = ""
    var resolvedEnvelope: ProvenanceEnvelope?
    var resolvedSidecarURL: URL?
    var searchText: String = ""
    var onExportRequested: ((ProvenanceExportFormat) -> Void)?

    private let monitor: ProvenanceCoverageMonitor

    init(monitor: ProvenanceCoverageMonitor = ProvenanceCoverageMonitor()) {
        self.monitor = monitor
    }

    var shouldShowTab: Bool {
        audit.status != .notRequired
    }

    func clear() {
        currentItem = nil
        audit = .notRequired
        summary = ProvenanceRunSummary()
        warnings = []
        lineageRuns = []
        fileRows = []
        optionRows = []
        runtimeRows = []
        rawJSON = ""
        resolvedEnvelope = nil
        resolvedSidecarURL = nil
        searchText = ""
    }

    func load(item: ProvenanceInspectableItem) {
        currentItem = item
        audit = monitor.audit(item)
        guard let url = item.url,
              let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: url) else {
            resolvedEnvelope = nil
            resolvedSidecarURL = nil
            buildMissingState(item: item)
            return
        }

        resolvedEnvelope = resolved.envelope
        resolvedSidecarURL = resolved.sidecarURL
        buildPresentState(envelope: resolved.envelope, sidecarURL: resolved.sidecarURL)
    }

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
    }

    private func buildPresentState(envelope: ProvenanceEnvelope, sidecarURL: URL) {
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
        warnings = warningRows(for: audit) + stepWarningRows(for: envelope)
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
                        inputPaths: step.inputs.map(\.path),
                        outputPaths: step.outputs.map(\.path),
                        exitStatus: step.exitStatus,
                        wallTimeSeconds: step.wallTimeSeconds,
                        stderr: step.stderr,
                        dependsOn: step.dependsOn
                    )
                }
            )
        ]
        fileRows = buildFileRows(envelope)
        optionRows = buildOptionRows(envelope.options)
        runtimeRows = buildRuntimeRows(envelope.runtimeIdentity)
        rawJSON = encodedJSON(envelope)
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
        allFileDescriptors(in: envelope).filter { $0.role == .input || $0.role == .reference || $0.role == .index }
    }

    private func outputDescriptors(in envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
        allFileDescriptors(in: envelope).filter { $0.role == .output || $0.role == .report || $0.role == .log }
    }

    private func allFileDescriptors(in envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
        envelope.files
            + (envelope.output.map { [$0] } ?? [])
            + envelope.outputs
            + envelope.steps.flatMap { $0.inputs + $0.outputs }
    }

    private func buildFileRows(_ envelope: ProvenanceEnvelope) -> [ProvenanceFileRow] {
        var seen = Set<String>()
        return allFileDescriptors(in: envelope).compactMap { descriptor in
            let key = "\(descriptor.role.rawValue)|\(descriptor.path)"
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return ProvenanceFileRow(
                role: descriptor.role.displayName,
                path: descriptor.path,
                displayPath: descriptor.path.middleTruncatedPath(),
                checksumSHA256: descriptor.checksumSHA256,
                fileSize: descriptor.fileSize,
                fileSizeLabel: descriptor.fileSize.map(Self.formatBytes) ?? "Size not recorded",
                format: descriptor.format?.rawValue,
                originPath: descriptor.originPath,
                sourceProvenancePath: descriptor.sourceProvenancePath
            )
        }
        .sorted { lhs, rhs in
            if lhs.role == rhs.role {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            return lhs.role < rhs.role
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

    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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
