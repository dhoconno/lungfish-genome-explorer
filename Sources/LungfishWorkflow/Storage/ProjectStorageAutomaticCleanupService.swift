import CryptoKit
import Foundation
import LungfishIO

public struct ProjectStorageAutomaticCleanupWarning:
    Equatable,
    Sendable
{
    public let relativePath: String?
    public let message: String

    public init(relativePath: String?, message: String) {
        self.relativePath = relativePath
        self.message = message
    }
}

public struct ProjectStorageAutomaticCleanupResult:
    Equatable,
    Sendable
{
    public enum State: Equatable, Sendable {
        case noEligibleEntries
        case completed
        case retryRecommended
        case cancelled
    }

    public let state: State
    public let scannedEntryCount: Int
    public let selectedEntryCount: Int
    public let warnings: [ProjectStorageAutomaticCleanupWarning]
    public let summaryURL: URL?
    public let provenanceURL: URL?

    public init(
        state: State,
        scannedEntryCount: Int,
        selectedEntryCount: Int,
        warnings: [ProjectStorageAutomaticCleanupWarning],
        summaryURL: URL?,
        provenanceURL: URL?
    ) {
        self.state = state
        self.scannedEntryCount = scannedEntryCount
        self.selectedEntryCount = selectedEntryCount
        self.warnings = warnings
        self.summaryURL = summaryURL
        self.provenanceURL = provenanceURL
    }
}

/// Performs conservative, project-scoped periodic cleanup.
///
/// The service never uses age as authority. It asks `ProjectStorageScanner` to
/// prove each individual temporary child removable, persists a preparation
/// receipt, then delegates identity revalidation, locking, disposition
/// journaling, and movement to Trash to `ProjectStorageCleanupExecutor`.
public struct ProjectStorageAutomaticCleanupService: Sendable {
    public enum Trigger: String, Sendable {
        case periodic
        case userRequested = "user-requested"
    }

    struct Invocation: Sendable {
        let projectURL: URL
        let projectIdentity: FileSystemObjectIdentity
        let cleanupID: UUID
        let selectedEntries: [ProjectStorageEntry]
        let workflowName: String
        let workflowVersion: String
        let toolName: String
        let toolVersion: String
        let argv: [String]
        let durableReplayArgv: [String]?
        let options: ProvenanceOptions
        let runtimeIdentity: ProvenanceRuntimeIdentity
        let startedAt: Date
    }

    struct FailureInvocation: Sendable {
        let failureID: UUID
        let cleanupID: UUID
        let projectURL: URL
        let trigger: Trigger
        let workflowVersion: String
        let toolName: String
        let toolVersion: String
        let argv: [String]
        let durableReplayArgv: [String]?
        let options: ProvenanceOptions
        let runtimeIdentity: ProvenanceRuntimeIdentity
        let startedAt: Date
        let completedAt: Date
        let errorMessage: String
    }

    struct FailureReceipt: Sendable {
        let summaryURL: URL
        let provenanceURL: URL
    }

    struct Operations: Sendable {
        var scan:
            @Sendable (URL) throws -> ProjectStorageScanResult
        var executeSelected:
            @Sendable (Invocation) async throws
                -> ProjectStorageCleanupExecutionResult
        var recordFailure:
            @Sendable (FailureInvocation) throws -> FailureReceipt
        var makeCleanupID: @Sendable () -> UUID
        var makeFailureID: @Sendable () -> UUID
        var now: @Sendable () -> Date
        var processArgv: @Sendable () -> [String]
        var runtimeIdentity:
            @Sendable () -> ProvenanceRuntimeIdentity
        var toolVersion: @Sendable () -> String

        init(
            scan:
                @escaping @Sendable (URL) throws
                    -> ProjectStorageScanResult = {
                        try ProjectStorageScanner().scan(projectURL: $0)
                    },
            executeSelected:
                @escaping @Sendable (Invocation) async throws
                    -> ProjectStorageCleanupExecutionResult = {
                        invocation in
                        let preparation =
                            try ProjectStorageCleanupReceiptWriter()
                                .prepareConfirmedCleanup(
                                    .init(
                                        cleanupID: invocation.cleanupID,
                                        projectURL: invocation.projectURL,
                                        projectIdentity:
                                            invocation.projectIdentity,
                                        selectedEntries:
                                            invocation.selectedEntries,
                                        workflowName:
                                            invocation.workflowName,
                                        workflowVersion:
                                            invocation.workflowVersion,
                                        toolName: invocation.toolName,
                                        toolVersion:
                                            invocation.toolVersion,
                                        argv: invocation.argv,
                                        durableReplayArgv:
                                            invocation
                                                .durableReplayArgv,
                                        options: invocation.options,
                                        runtimeIdentity:
                                            invocation.runtimeIdentity,
                                        startedAt: invocation.startedAt
                                    )
                                )
                        guard preparation.journal.cleanupID
                            == invocation.cleanupID else {
                            throw
                                ProjectStorageAutomaticCleanupCompositionError
                                .cleanupIDMismatch
                        }
                        do {
                            return try await
                                ProjectStorageCleanupExecutor().execute(
                                    .init(
                                        projectURL:
                                            invocation.projectURL,
                                        cleanupID: invocation.cleanupID,
                                        argv: invocation.argv,
                                        durableReplayArgv:
                                            invocation.durableReplayArgv,
                                        options: invocation.options,
                                        runtimeIdentity:
                                            invocation.runtimeIdentity,
                                        startedAt: invocation.startedAt
                                    )
                                )
                        } catch is CancellationError {
                            throw
                                ProjectStorageAutomaticCleanupPublishedCancellation(
                                    result:
                                        try latestPublishedCleanupExecution(
                                            preparation:
                                                preparation
                                        )
                                )
                        }
                    },
            recordFailure:
                @escaping @Sendable (FailureInvocation) throws
                    -> FailureReceipt = {
                        try writeAutomaticCleanupFailureReceipt($0)
                    },
            makeCleanupID: @escaping @Sendable () -> UUID = UUID.init,
            makeFailureID: @escaping @Sendable () -> UUID = UUID.init,
            now: @escaping @Sendable () -> Date = Date.init,
            processArgv:
                @escaping @Sendable () -> [String] = {
                    CommandLine.arguments
                },
            runtimeIdentity:
                @escaping @Sendable ()
                    -> ProvenanceRuntimeIdentity = {
                        ProvenanceRuntimeIdentity()
                    },
            toolVersion:
                @escaping @Sendable () -> String = {
                    WorkflowRun.currentAppVersion
                }
        ) {
            self.scan = scan
            self.executeSelected = executeSelected
            self.recordFailure = recordFailure
            self.makeCleanupID = makeCleanupID
            self.makeFailureID = makeFailureID
            self.now = now
            self.processArgv = processArgv
            self.runtimeIdentity = runtimeIdentity
            self.toolVersion = toolVersion
        }
    }

    private let operations: Operations

    public init() {
        operations = .init()
    }

    init(operations: Operations) {
        self.operations = operations
    }

    public func run(
        projectURL: URL,
        trigger: Trigger = .periodic
    ) async -> ProjectStorageAutomaticCleanupResult {
        let project = projectURL.standardizedFileURL
        let cleanupID = operations.makeCleanupID()
        let startedAt = operations.now()
        let runtimeIdentity = operations.runtimeIdentity()
        let toolVersion = operations.toolVersion()
        let baseArgv = operations.processArgv()
        let options = Self.options(trigger: trigger)
        let scan: ProjectStorageScanResult
        do {
            try Task.checkCancellation()
            scan = try operations.scan(project)
            try Task.checkCancellation()
        } catch is CancellationError {
            return result(state: .cancelled)
        } catch {
            return recordFailure(
                error,
                cleanupID: cleanupID,
                projectURL: project,
                trigger: trigger,
                argv: baseArgv,
                options: options,
                runtimeIdentity: runtimeIdentity,
                toolVersion: toolVersion,
                startedAt: startedAt
            )
        }

        let selected = scan.entries
            .filter(Self.isEligibleForAutomaticCleanup)
            .sorted { $0.relativePath < $1.relativePath }
        guard !selected.isEmpty else {
            return result(
                state: .noEligibleEntries,
                scannedEntryCount: scan.entries.count
            )
        }

        let argv = baseArgv
        let selectedOptions = Self.options(
            trigger: trigger,
            selectedEntries: selected
        )
        let invocation = Invocation(
            projectURL: project,
            projectIdentity: scan.projectIdentity,
            cleanupID: cleanupID,
            selectedEntries: selected,
            workflowName: "Project Temporary Storage Cleanup",
            workflowVersion: toolVersion,
            toolName: "Lungfish",
            toolVersion: toolVersion,
            argv: argv,
            durableReplayArgv: nil,
            options: selectedOptions,
            runtimeIdentity: runtimeIdentity,
            startedAt: startedAt
        )

        do {
            let execution = try await operations.executeSelected(invocation)
            let warnings = execution.summary.items.compactMap {
                item -> ProjectStorageAutomaticCleanupWarning? in
                guard item.state != .movedToTrash else { return nil }
                return .init(
                    relativePath: item.sourceRelativePath,
                    message:
                        item.reason
                        ?? "Automatic cleanup could not safely complete."
                )
            }
            let needsRetry =
                execution.summary.state != .completed
                || !warnings.isEmpty
            return result(
                state: needsRetry ? .retryRecommended : .completed,
                scannedEntryCount: scan.entries.count,
                selectedEntryCount: selected.count,
                warnings: warnings,
                summaryURL: execution.summaryURL,
                provenanceURL: execution.provenanceURL
            )
        } catch let cancellation
            as ProjectStorageAutomaticCleanupPublishedCancellation
        {
            let warnings = cancellation.result.summary.items.compactMap {
                item -> ProjectStorageAutomaticCleanupWarning? in
                guard item.state != .movedToTrash else { return nil }
                return .init(
                    relativePath: item.sourceRelativePath,
                    message:
                        item.reason
                        ?? "Cleanup was cancelled before this item completed."
                )
            }
            return result(
                state: .cancelled,
                scannedEntryCount: scan.entries.count,
                selectedEntryCount: selected.count,
                warnings: warnings,
                summaryURL: cancellation.result.summaryURL,
                provenanceURL: cancellation.result.provenanceURL
            )
        } catch is CancellationError {
            return result(
                state: .cancelled,
                scannedEntryCount: scan.entries.count,
                selectedEntryCount: selected.count
            )
        } catch {
            return recordFailure(
                error,
                cleanupID: cleanupID,
                projectURL: project,
                trigger: trigger,
                argv: argv,
                options: selectedOptions,
                runtimeIdentity: runtimeIdentity,
                toolVersion: toolVersion,
                startedAt: startedAt,
                scannedEntryCount: scan.entries.count,
                selectedEntryCount: selected.count
            )
        }
    }

    private static func isEligibleForAutomaticCleanup(
        _ entry: ProjectStorageEntry
    ) -> Bool {
        guard entry.category == .temporary,
              entry.classification.isRemovable else {
            return false
        }
        switch entry.classification.code {
        case .completedOwnedWork, .conclusivelyOrphanedOwnedWork:
            return true
        default:
            return false
        }
    }

    private static func options(
        trigger: Trigger,
        selectedEntries: [ProjectStorageEntry] = []
    ) -> ProvenanceOptions {
        var explicit: [String: ParameterValue] = [
            "trigger": .string(trigger.rawValue),
        ]
        if !selectedEntries.isEmpty {
            explicit["selectedRelativePaths"] = .array(
                selectedEntries.map {
                    .string($0.relativePath)
                }
            )
        }
        return .init(
            explicit: explicit,
            defaults: [
                "category": .string("temporary"),
                "permanentDeleteFallback": .boolean(false),
                "requiresOwnedMarker": .boolean(true),
            ],
            resolvedDefaults: [
                "category": .string("temporary"),
                "permanentDeleteFallback": .boolean(false),
                "requiresOwnedMarker": .boolean(true),
            ]
        )
    }

    private func recordFailure(
        _ error: Error,
        cleanupID: UUID,
        projectURL: URL,
        trigger: Trigger,
        argv: [String],
        options: ProvenanceOptions,
        runtimeIdentity: ProvenanceRuntimeIdentity,
        toolVersion: String,
        startedAt: Date,
        scannedEntryCount: Int = 0,
        selectedEntryCount: Int = 0
    ) -> ProjectStorageAutomaticCleanupResult {
        let message = error.localizedDescription
        do {
            let receipt = try operations.recordFailure(
                .init(
                    failureID: operations.makeFailureID(),
                    cleanupID: cleanupID,
                    projectURL: projectURL,
                    trigger: trigger,
                    workflowVersion: toolVersion,
                    toolName: "Lungfish",
                    toolVersion: toolVersion,
                    argv: argv,
                    durableReplayArgv: nil,
                    options: options,
                    runtimeIdentity: runtimeIdentity,
                    startedAt: startedAt,
                    completedAt: operations.now(),
                    errorMessage: message
                )
            )
            return result(
                state: .retryRecommended,
                scannedEntryCount: scannedEntryCount,
                selectedEntryCount: selectedEntryCount,
                warnings: [
                    .init(relativePath: nil, message: message),
                ],
                summaryURL: receipt.summaryURL,
                provenanceURL: receipt.provenanceURL
            )
        } catch {
            return result(
                state: .retryRecommended,
                scannedEntryCount: scannedEntryCount,
                selectedEntryCount: selectedEntryCount,
                warnings: [
                    .init(relativePath: nil, message: message),
                    .init(
                        relativePath: nil,
                        message:
                            "Could not durably record the cleanup retry "
                            + "warning: \(error.localizedDescription)"
                    ),
                ]
            )
        }
    }

    private func result(
        state: ProjectStorageAutomaticCleanupResult.State,
        scannedEntryCount: Int = 0,
        selectedEntryCount: Int = 0,
        warnings: [ProjectStorageAutomaticCleanupWarning] = [],
        summaryURL: URL? = nil,
        provenanceURL: URL? = nil
    ) -> ProjectStorageAutomaticCleanupResult {
        .init(
            state: state,
            scannedEntryCount: scannedEntryCount,
            selectedEntryCount: selectedEntryCount,
            warnings: warnings,
            summaryURL: summaryURL,
            provenanceURL: provenanceURL
        )
    }
}

private struct ProjectStorageAutomaticCleanupFailureRecord:
    Codable,
    Sendable
{
    let schemaVersion: Int
    let failureID: UUID
    let cleanupID: UUID
    let projectPath: String
    let trigger: String
    let retryRecommended: Bool
    let startedAt: Date
    let completedAt: Date
    let error: String
}

private enum ProjectStorageAutomaticCleanupCompositionError:
    Error,
    LocalizedError
{
    case cleanupIDMismatch
    case missingCancellationReceipt
    case mismatchedCancellationReceipt

    var errorDescription: String? {
        switch self {
        case .cleanupIDMismatch:
            return "The prepared project-storage receipt did not preserve its cleanup ID."
        case .missingCancellationReceipt:
            return "The cancelled project-storage cleanup did not publish a complete receipt."
        case .mismatchedCancellationReceipt:
            return "The cancelled project-storage cleanup receipt does not match its cleanup ID."
        }
    }
}

struct ProjectStorageAutomaticCleanupPublishedCancellation:
    Error
{
    let result: ProjectStorageCleanupExecutionResult
}

private func latestPublishedCleanupExecution(
    preparation: ProjectStorageCleanupPreparation
) throws -> ProjectStorageCleanupExecutionResult {
    let names = try FileManager.default.contentsOfDirectory(
        atPath: preparation.operationDirectoryURL.path
    )
    guard let summaryName = names.filter({
        $0.hasPrefix("execution-summary-") && $0.hasSuffix(".json")
    }).sorted().last else {
        throw ProjectStorageAutomaticCleanupCompositionError
            .missingCancellationReceipt
    }
    let sequence = summaryName
        .dropFirst("execution-summary-".count)
        .dropLast(".json".count)
    let provenanceName = "execution-provenance-\(sequence).json"
    guard names.contains(provenanceName) else {
        throw ProjectStorageAutomaticCleanupCompositionError
            .missingCancellationReceipt
    }
    let summaryURL = preparation.operationDirectoryURL
        .appendingPathComponent(summaryName)
    let provenanceURL = preparation.operationDirectoryURL
        .appendingPathComponent(provenanceName)
    let summary = try ProvenanceJSON.decoder.decode(
        ProjectStorageCleanupExecutionSummary.self,
        from: Data(contentsOf: summaryURL)
    )
    let provenance = try ProvenanceEnvelopeReader.decodeCanonical(
        Data(contentsOf: provenanceURL)
    )
    guard summary.cleanupID == preparation.journal.cleanupID,
          provenance.id == preparation.journal.cleanupID else {
        throw ProjectStorageAutomaticCleanupCompositionError
            .mismatchedCancellationReceipt
    }
    return .init(
        summary: summary,
        summaryURL: summaryURL,
        provenanceURL: provenanceURL
    )
}

private func writeAutomaticCleanupFailureReceipt(
    _ invocation: ProjectStorageAutomaticCleanupService.FailureInvocation
) throws -> ProjectStorageAutomaticCleanupService.FailureReceipt {
    let writer = ProjectOperationHistoryWriter(
        projectURL: invocation.projectURL
    )
    let operationURL = writer.operationDirectoryURL(
        for: invocation.failureID
    )
    let summaryName = "automatic-cleanup-failure.json"
    let provenanceName = "automatic-cleanup-failure-provenance.json"
    let summaryURL = operationURL.appendingPathComponent(summaryName)
    let provenanceURL = operationURL.appendingPathComponent(provenanceName)
    let record = ProjectStorageAutomaticCleanupFailureRecord(
        schemaVersion: 1,
        failureID: invocation.failureID,
        cleanupID: invocation.cleanupID,
        projectPath: invocation.projectURL.path,
        trigger: invocation.trigger.rawValue,
        retryRecommended: true,
        startedAt: invocation.startedAt,
        completedAt: invocation.completedAt,
        error: invocation.errorMessage
    )
    let summaryData = try ProvenanceJSON.encoder.encode(record)
    let summaryDigest = SHA256.hash(data: summaryData)
        .map { String(format: "%02x", $0) }
        .joined()
    let projectInput = ProvenanceFileDescriptor(
        path: invocation.projectURL.path,
        role: .input
    )
    let summaryOutput = ProvenanceFileDescriptor(
        path: summaryURL.path,
        checksumSHA256: summaryDigest,
        fileSize: UInt64(summaryData.count),
        format: .json,
        role: .output
    )
    let wallTime = max(
        0,
        invocation.completedAt.timeIntervalSince(invocation.startedAt)
    )
    let resolvedOptions =
        invocation.options.defaults.merging(
            invocation.options.resolvedDefaults
        ) { _, resolved in resolved }
        .merging(invocation.options.explicit) { _, explicit in explicit }
    let step = ProvenanceStep(
        toolName: invocation.toolName,
        toolVersion: invocation.toolVersion,
        argv: invocation.argv,
        durableReplayArgv: invocation.durableReplayArgv,
        resolvedOptions: resolvedOptions,
        runtimeIdentity: invocation.runtimeIdentity,
        inputs: [projectInput],
        outputs: [summaryOutput],
        exitStatus: 1,
        wallTimeSeconds: wallTime,
        stderr: invocation.errorMessage,
        startedAt: invocation.startedAt,
        completedAt: invocation.completedAt
    )
    let provenance = ProvenanceEnvelope(
        id: invocation.failureID,
        createdAt: invocation.completedAt,
        workflowName: "Project Temporary Storage Cleanup Failure",
        workflowVersion: invocation.workflowVersion,
        toolName: invocation.toolName,
        toolVersion: invocation.toolVersion,
        argv: invocation.argv,
        durableReplayArgv: invocation.durableReplayArgv,
        options: invocation.options,
        runtimeIdentity: invocation.runtimeIdentity,
        files: [projectInput],
        outputs: [summaryOutput],
        steps: [step],
        wallTimeSeconds: wallTime,
        exitStatus: 1,
        stderr: invocation.errorMessage
    )
    let provenanceData = try ProvenanceJSON.encoder.encode(provenance)
    _ = try writer.createOperation(
        operationID: invocation.failureID,
        payloads: [
            summaryName: summaryData,
            provenanceName: provenanceData,
        ]
    )
    return .init(
        summaryURL: summaryURL,
        provenanceURL: provenanceURL
    )
}
