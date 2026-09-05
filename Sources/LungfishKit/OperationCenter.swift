// OperationCenter.swift - Centralized operation tracking with bundle locking
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Combine
import LungfishCore
import LungfishWorkflow
import SwiftUI

/// The type of long-running operation being tracked.
public enum OperationType: String, Sendable {
    case download = "Download"
    case bamImport = "BAM Import"
    case vcfImport = "VCF Import"
    case bundleBuild = "Bundle Build"
    case export = "Export"
    case assembly = "Assembly"
    case ingestion = "Ingestion"
    case fastqOperation = "FASTQ Op"
    case qualityReport = "Quality Report"
    case taxonomyExtraction = "Extraction"
    case classification = "Classification"
    case blastVerification = "BLAST"
    case bamPrimerTrim = "Primer Trim"
    case variantCalling = "Variant Calling"
    case workflow = "Workflow"
    case viralRecon = "Viral Recon"
    case applicationExportImport = "Application Export"
    case condaPluginPack = "Plugin Pack"
    case multipleSequenceAlignmentImport = "MSA Import"
    case multipleSequenceAlignmentGeneration = "MSA Generation"
    case multipleSequenceAlignmentAction = "MSA Action"
    case phylogeneticTreeImport = "Tree Import"
    case phylogeneticTreeInference = "Tree Inference"
    case phylogeneticTreeTransform = "Tree Transform"
}

/// A timestamped log entry recorded during an operation's lifecycle.
///
/// Log entries provide step-by-step visibility into what an operation
/// is doing, surfaced in the Operations Panel's expanded detail view.
public struct OperationLogEntry: Sendable, Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let level: OperationLogLevel
    public let message: String

    public init(timestamp: Date = Date(), level: OperationLogLevel, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

public struct OperationRetryMetadata: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let attempt: Int
    public let maxRetries: Int
    public let statusCode: Int
    public let delaySeconds: TimeInterval
    public let message: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        attempt: Int,
        maxRetries: Int,
        statusCode: Int,
        delaySeconds: TimeInterval,
        message: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.attempt = attempt
        self.maxRetries = maxRetries
        self.statusCode = statusCode
        self.delaySeconds = delaySeconds
        self.message = message
    }

    public var displayText: String {
        "Retrying after HTTP \(statusCode) (attempt \(attempt)/\(maxRetries), next in \(Self.formatDelay(delaySeconds)))"
    }

    private static func formatDelay(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            let minutes = Int(seconds) / 60
            let remainder = Int(seconds) % 60
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
        }
        return "\(Int(seconds.rounded()))s"
    }
}

/// Log level for operation log entries.
///
/// The levels mirror standard syslog severity tiers.
public enum OperationLogLevel: String, Sendable, Codable {
    case debug
    case info
    case warning
    case error
}

/// Window/project context used to route operation results back to the originating workspace.
public struct OperationRouteContext: Sendable, Codable, Equatable {
    public let projectURL: URL?
    public let windowStateScopeID: UUID?

    public init(projectURL: URL?, windowStateScope: WindowStateScope?) {
        self.projectURL = projectURL?.standardizedFileURL
        self.windowStateScopeID = windowStateScope?.id
    }

    public init(projectURL: URL?, windowStateScopeID: UUID?) {
        self.projectURL = projectURL?.standardizedFileURL
        self.windowStateScopeID = windowStateScopeID
    }
}

@MainActor
public final class OperationCenter: ObservableObject {
    public enum Change: Sendable, Equatable {
        case inserted(id: UUID, index: Int)
        case updated(id: UUID, index: Int)
        case removed(ids: [UUID])
        case reloaded
    }

    public struct Item: Identifiable, Sendable {
        public enum State: String, Sendable {
            case running
            case cancelling
            case completed
            case cancelled
            case failed

            public var isActive: Bool {
                self == .running || self == .cancelling
            }
        }

        public let id: UUID
        public var title: String
        public var detail: String
        public var progress: Double
        public var state: State
        public var operationType: OperationType
        public var startedAt: Date
        public var finishedAt: Date?
        public var wallTimeSeconds: TimeInterval?
        public var peakMemoryBytes: UInt64?
        /// File URLs produced by this operation (e.g. .lungfishref bundle paths).
        /// Set when the operation completes via ``complete(id:detail:bundleURLs:)``.
        public var bundleURLs: [URL]
        /// Non-bundle file URLs produced by this operation (e.g. exported FASTA or TSV files).
        /// These are surfaced in the Operations Panel but are not routed through bundle import.
        public var outputURLs: [URL]
        /// The bundle this operation is targeting, used for bundle locking.
        public var targetBundleURL: URL?
        /// Callback invoked when the user cancels this operation.
        public nonisolated(unsafe) var onCancel: (@Sendable () -> Void)?

        // MARK: - Enhanced diagnostics

        /// The reconstructed `lungfish [subcommand] [args]` CLI invocation, if applicable.
        public var cliCommand: String?
        /// Step-by-step log entries recorded during this operation.
        public var logEntries: [OperationLogEntry] = []
        /// Retry metadata for rate limits or transient failures.
        public var retryEvents: [OperationRetryMetadata] = []
        /// User-facing error summary shown prominently on failure.
        public var errorMessage: String?
        /// Extended diagnostic detail (stack trace, stderr, etc.) for debugging.
        public var errorDetail: String?
        /// Durable workflow-builder run identifier carried by parent and child rows.
        public var workflowRunID: UUID?
        /// The project/window context that launched this operation, when available.
        public var routeContext: OperationRouteContext?
        /// Where the automatic failure report for this operation was written.
        /// Nil until the operation fails, and also when the report could not be
        /// written (a logging failure is never allowed to escalate).
        public var failureReportURL: URL?

        public var hasWarnings: Bool {
            logEntries.contains { $0.level == .warning }
        }

        public var displayStateLabel: String {
            switch state {
            case .running:
                return retryEvents.isEmpty ? "Running" : "Retrying"
            case .cancelling:
                return "Cancelling"
            case .completed:
                return hasWarnings ? "Completed with Warnings" : "Completed"
            case .cancelled:
                return "Cancelled"
            case .failed:
                return "Failed"
            }
        }

        public var isCancellable: Bool {
            state == .running && onCancel != nil
        }

        // MARK: - Byte-level progress tracking

        /// Total expected bytes for this operation (if known ahead of time).
        public var totalBytes: Int64? = nil
        /// Bytes downloaded/processed so far.
        public var bytesDownloaded: Int64? = nil

        public init(
            id: UUID = UUID(),
            title: String,
            detail: String,
            progress: Double,
            state: State,
            operationType: OperationType = .download,
            startedAt: Date = Date(),
            finishedAt: Date? = nil,
            wallTimeSeconds: TimeInterval? = nil,
            peakMemoryBytes: UInt64? = nil,
            bundleURLs: [URL] = [],
            outputURLs: [URL] = [],
            targetBundleURL: URL? = nil,
            onCancel: (@Sendable () -> Void)? = nil,
            cliCommand: String? = nil,
            workflowRunID: UUID? = nil,
            routeContext: OperationRouteContext? = nil,
            errorMessage: String? = nil,
            errorDetail: String? = nil
        ) {
            self.id = id
            self.title = title
            self.detail = detail
            self.progress = progress
            self.state = state
            self.operationType = operationType
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.wallTimeSeconds = wallTimeSeconds
            self.peakMemoryBytes = peakMemoryBytes
            self.bundleURLs = bundleURLs
            self.outputURLs = outputURLs
            self.targetBundleURL = targetBundleURL
            self.onCancel = onCancel
            self.cliCommand = cliCommand
            self.workflowRunID = workflowRunID
            self.routeContext = routeContext
            self.errorMessage = errorMessage
            self.errorDetail = errorDetail
        }
    }

    public static let shared = OperationCenter()

    @Published public private(set) var items: [Item] = []
    public let changes = PassthroughSubject<Change, Never>()

    /// Called when an operation completes with bundle URLs that need importing.
    /// The AppDelegate sets this once at startup to handle bundle import.
    public var onBundleReady: (([URL]) -> Void)?
    /// Context-aware bundle delivery for multi-window project sessions.
    public var onBundleReadyWithContext: (([URL], OperationRouteContext?) -> Void)?

    /// Writes a diagnostic report to disk whenever an operation fails, so a
    /// failure can be read from a file instead of only from a live panel.
    /// Tests substitute a store rooted in a temporary directory.
    public var failureReportStore = OperationFailureReportStore()

    private enum BundleLockScope {
        case exact
        case tree
    }

    private struct BundleLock {
        let operationID: UUID
        let scope: BundleLockScope
    }

    /// Canonical paths and their active owner/scope share one lock authority.
    private var bundleLocks: [String: BundleLock] = [:]

    /// Creates an empty operation center.
    ///
    /// In the running app, prefer the shared singleton ``shared``. A fresh
    /// instance is primarily useful for isolated tests that need their own
    /// operation state. Exposed publicly so callers outside this module (such
    /// as test targets) can construct an isolated instance.
    public init() {}

    public var activeCount: Int {
        items.filter { $0.state.isActive }.count
    }

    // MARK: - Bundle Locking

    /// Returns whether an ordinary exact-target operation can start without
    /// conflicting with an active exact target or overlapping tree lease.
    public func canStartOperation(on bundleURL: URL?) -> Bool {
        activeLockHolder(for: bundleURL) == nil
    }

    /// Returns the active owner blocking an ordinary exact-target operation.
    public func activeLockHolder(for bundleURL: URL?) -> Item? {
        guard let bundleURL else { return nil }
        return activeLockHolder(forCanonicalPath: canonicalLockPath(bundleURL), requestedScope: .exact)
    }

    private func canonicalLockPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func activeLockHolder(forCanonicalPath path: String, requestedScope: BundleLockScope) -> Item? {
        let requestedComponents = URL(fileURLWithPath: path).pathComponents
        for existingPath in bundleLocks.keys.sorted() {
            guard let lock = bundleLocks[existingPath] else { continue }
            let existingComponents = URL(fileURLWithPath: existingPath).pathComponents
            let conflicts = path == existingPath || ((requestedScope == .tree || lock.scope == .tree)
                && (requestedComponents.starts(with: existingComponents)
                    || existingComponents.starts(with: requestedComponents)))
            guard conflicts,
                  let owner = items.first(where: { $0.id == lock.operationID && $0.state.isActive }) else { continue }
            return owner
        }
        return nil
    }

    private func unlockBundle(for id: UUID) {
        bundleLocks = bundleLocks.filter { $0.value.operationID != id }
    }

    private func postStateChangedNotification(id: UUID, state: Item.State) {
        NotificationCenter.default.post(
            name: .operationStateChanged,
            object: self,
            userInfo: [
                "operationID": id,
                "operationState": state.rawValue,
            ]
        )
    }

    // MARK: - CLI Command Builder

    /// Builds a properly shell-quoted Lungfish CLI command string.
    ///
    /// Arguments containing spaces, quotes, or shell metacharacters are
    /// wrapped in single quotes with internal single quotes escaped.
    ///
    /// - Parameters:
    ///   - subcommand: The lungfish-cli subcommand path (e.g. `"fetch"`, `"conda classify"`, `"fastq import-ont"`).
    ///   - args: Positional and flag arguments.
    /// - Returns: A copy-pasteable shell command string.
    public nonisolated static func buildCLICommand(subcommand: String, args: [String]) -> String {
        let subcommandParts = subcommand
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let allParts = [CLICommandIdentity.executableName] + subcommandParts + args
        let quoted = allParts.map { shellEscape($0) }
        return quoted.joined(separator: " ")
    }

    // MARK: - Lifecycle

    /// Starts tracking a new operation.
    ///
    /// - Parameters:
    ///   - title: Human-readable operation title.
    ///   - detail: Initial status detail text.
    ///   - operationType: The category of operation.
    ///   - targetBundleURL: Optional bundle URL for locking.
    ///   - cliCommand: Optional reconstructed CLI invocation for display.
    ///   - onCancel: Callback invoked if the user cancels the operation.
    /// - Returns: The unique ID for the new operation item.
    public func start(
        title: String,
        detail: String,
        operationType: OperationType = .download,
        targetBundleURL: URL? = nil,
        additionalLockedBundleURLs: [URL] = [],
        startedAt: Date = Date(),
        cliCommand: String? = nil,
        workflowRunID: UUID? = nil,
        routeContext: OperationRouteContext? = nil,
        onCancel: (@Sendable () -> Void)? = nil
    ) -> UUID {
        let id = UUID()
        var requestedLocks: [String: BundleLockScope] = [:]
        if let targetBundleURL { requestedLocks[canonicalLockPath(targetBundleURL)] = .exact }
        // An additional URL protects the whole tree, including when it is an
        // alias/duplicate of the target. Ordinary targets retain exact scope.
        for url in additionalLockedBundleURLs { requestedLocks[canonicalLockPath(url)] = .tree }
        let requests = requestedLocks.sorted { $0.key < $1.key }
        // The main-actor conflict check completes before any key is acquired.
        if let lockHolder = requests.compactMap({ request in
            activeLockHolder(forCanonicalPath: request.key, requestedScope: request.value)
        }).first {
            let finishedAt = Date()
            let blockedDetail = "\"\(lockHolder.title)\" is currently running on this bundle. Please wait for it to finish."
            items.insert(
                Item(
                    id: id,
                    title: title,
                    detail: blockedDetail,
                    progress: 1,
                    state: .failed,
                    operationType: operationType,
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    wallTimeSeconds: max(0, finishedAt.timeIntervalSince(startedAt)),
                    targetBundleURL: targetBundleURL,
                    routeContext: routeContext,
                    errorMessage: "Bundle is busy"
                ),
                at: 0
            )
            changes.send(.inserted(id: id, index: 0))
            notifyRemovedItems(trimCompletedItemsIfNeeded())
            postStateChangedNotification(id: id, state: .failed)
            return id
        }

        items.insert(
            Item(
                id: id,
                title: title,
                detail: detail,
                progress: 0,
                state: .running,
                operationType: operationType,
                startedAt: startedAt,
                targetBundleURL: targetBundleURL,
                onCancel: onCancel,
                cliCommand: cliCommand,
                workflowRunID: workflowRunID,
                routeContext: routeContext
            ),
            at: 0
        )
        for request in requests {
            bundleLocks[request.key] = BundleLock(operationID: id, scope: request.value)
        }
        changes.send(.inserted(id: id, index: 0))
        notifyRemovedItems(trimCompletedItemsIfNeeded())
        postStateChangedNotification(id: id, state: .running)
        return id
    }

    /// Sets the cancellation callback for an existing operation.
    /// Useful when the operation must be registered before the cancellable task handle exists.
    public func setCancelCallback(for id: UUID, callback: @escaping @Sendable () -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .running else { return }
        items[index].onCancel = callback
        changes.send(.updated(id: id, index: index))
    }

    @discardableResult
    public func update(id: UUID, progress: Double, detail: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard items[index].state == .running else { return false }
        items[index].progress = max(0, min(1, progress))
        items[index].detail = detail
        changes.send(.updated(id: id, index: index))
        return true
    }

    /// Updates visible progress and records the same status in operation history.
    ///
    /// Progress callbacks can fire many times with identical text, so adjacent
    /// duplicate messages are suppressed by default.
    @discardableResult
    public func updateWithLog(
        id: UUID,
        progress: Double,
        detail: String,
        level: OperationLogLevel = .info,
        deduplicateAdjacent: Bool = true
    ) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard items[index].state == .running else { return false }
        items[index].progress = max(0, min(1, progress))
        items[index].detail = detail

        if deduplicateAdjacent,
           items[index].logEntries.last?.message == detail,
           items[index].logEntries.last?.level == level {
            changes.send(.updated(id: id, index: index))
            return true
        }
        let entry = OperationLogEntry(level: level, message: detail)
        items[index].logEntries.append(entry)
        changes.send(.updated(id: id, index: index))
        return true
    }

    /// Updates resource usage observed for an operation.
    public func updateResourceStats(id: UUID, peakMemoryBytes: UInt64? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let peakMemoryBytes {
            let existing = items[index].peakMemoryBytes ?? 0
            items[index].peakMemoryBytes = max(existing, peakMemoryBytes)
        }
        changes.send(.updated(id: id, index: index))
    }

    /// Updates byte progress for an operation, computing the progress fraction automatically.
    ///
    /// The detail text is auto-generated as "X MB / Y GB · ETA Zm Ws" when enough
    /// information is available. The ETA is derived from elapsed time and progress fraction.
    ///
    /// - Parameters:
    ///   - id: The operation to update.
    ///   - bytesDownloaded: Bytes transferred so far.
    ///   - totalBytes: Total expected bytes (nil if unknown).
    public func updateBytes(id: UUID, bytesDownloaded: Int64, totalBytes: Int64?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].bytesDownloaded = bytesDownloaded
        // Only update totalBytes if we now have a value (don't overwrite a known value with nil)
        if let total = totalBytes {
            items[index].totalBytes = total
        }
        let effectiveTotal = totalBytes ?? items[index].totalBytes
        // Compute progress fraction
        if let total = effectiveTotal, total > 0 {
            items[index].progress = Double(bytesDownloaded) / Double(total)
        }
        // Auto-generate detail text with transferred/total sizes
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        let downloaded = formatter.string(fromByteCount: bytesDownloaded)
        // Base detail: "X MB" or "X MB / Y GB"
        var detail: String
        if let total = effectiveTotal {
            let totalStr = formatter.string(fromByteCount: total)
            detail = "\(downloaded) / \(totalStr)"
        } else {
            detail = downloaded
        }
        // Append ETA when we have enough elapsed time and meaningful progress
        let elapsed = Date().timeIntervalSince(items[index].startedAt)
        let progress = items[index].progress
        if progress > 0.01 && elapsed > 2 {
            let estimatedTotal = elapsed / progress
            let remaining = estimatedTotal - elapsed
            let etaStr = formatETAInterval(remaining)
            detail += " · ETA \(etaStr)"
        }
        items[index].detail = detail
        changes.send(.updated(id: id, index: index))
    }

    /// Appends a timestamped log entry to an operation's log.
    ///
    /// Log entries are displayed in the Operations Panel when a row is expanded,
    /// giving step-by-step visibility into the operation's progress.
    ///
    /// - Parameters:
    ///   - id: The operation to log against.
    ///   - level: Severity level of the log entry.
    ///   - message: The log message text.
    public func log(id: UUID, level: OperationLogLevel, message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let entry = OperationLogEntry(level: level, message: message)
        items[index].logEntries.append(entry)
        changes.send(.updated(id: id, index: index))
    }

    public func recordRetry(
        id: UUID,
        attempt: Int,
        maxRetries: Int,
        statusCode: Int,
        delaySeconds: TimeInterval,
        message: String? = nil
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let retry = OperationRetryMetadata(
            attempt: attempt,
            maxRetries: maxRetries,
            statusCode: statusCode,
            delaySeconds: delaySeconds,
            message: message
        )
        items[index].retryEvents.append(retry)
        items[index].detail = retry.displayText

        var logMessage = retry.displayText
        if let message, !message.isEmpty {
            logMessage = "\(message): \(logMessage)"
        }
        items[index].logEntries.append(OperationLogEntry(level: .warning, message: logMessage))
        changes.send(.updated(id: id, index: index))
    }

    /// The worker calls a terminal method only after process exit, stream drain
    /// and owned output cleanup. Accepted cancellation always wins over its result.
    @discardableResult
    public func complete(id: UUID, detail: String, finishedAt: Date = Date()) -> Bool {
        finishWorker(id: id, state: .completed, detail: detail, finishedAt: finishedAt)
    }

    @discardableResult
    public func complete(id: UUID, detail: String, bundleURLs: [URL], finishedAt: Date = Date()) -> Bool {
        finishWorker(id: id, state: .completed, detail: detail, bundleURLs: bundleURLs, finishedAt: finishedAt)
    }

    @discardableResult
    public func complete(id: UUID, detail: String, outputURLs: [URL], finishedAt: Date = Date()) -> Bool {
        finishWorker(id: id, state: .completed, detail: detail, outputURLs: outputURLs, finishedAt: finishedAt)
    }

    @discardableResult
    public func completeWithWarning(id: UUID, detail: String) -> Bool {
        finishWorker(id: id, state: .completed, detail: detail, warning: true)
    }

    @discardableResult
    public func completeWithWarning(id: UUID, detail: String, bundleURLs: [URL]) -> Bool {
        finishWorker(id: id, state: .completed, detail: detail, bundleURLs: bundleURLs, warning: true)
    }

    @discardableResult
    public func completeWithWarning(id: UUID, detail: String, outputURLs: [URL]) -> Bool {
        finishWorker(id: id, state: .completed, detail: detail, outputURLs: outputURLs, warning: true)
    }

    @discardableResult
    public func fail(
        id: UUID,
        detail: String,
        errorMessage: String? = nil,
        errorDetail: String? = nil,
        finishedAt: Date = Date()
    ) -> Bool {
        finishWorker(id: id, state: .failed, detail: detail, errorMessage: errorMessage,
                     errorDetail: errorDetail, finishedAt: finishedAt)
    }

    /// Acknowledges cancellation after the owning worker (or idle UI phase)
    /// has drained and cleaned up. This never invokes the cancellation signal.
    @discardableResult
    public func acknowledgeCancellation(id: UUID, detail: String = "Cancelled by user", finishedAt: Date = Date()) -> Bool {
        finishWorker(id: id, state: .cancelled, detail: detail, finishedAt: finishedAt)
    }

    private func finishWorker(
        id: UUID,
        state requestedState: Item.State,
        detail: String,
        bundleURLs: [URL] = [],
        outputURLs: [URL] = [],
        warning: Bool = false,
        errorMessage: String? = nil,
        errorDetail: String? = nil,
        finishedAt: Date = Date()
    ) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state.isActive else { return false }
        let cancellationWon = items[index].state == .cancelling
        let state: Item.State = cancellationWon ? .cancelled : requestedState
        let previousOrder = items.map(\.id)
        let routeContext = items[index].routeContext
        items[index].state = state
        items[index].detail = cancellationWon ? "Cancelled by user" : detail
        items[index].onCancel = nil
        items[index].bundleURLs = state == .completed ? bundleURLs : []
        items[index].outputURLs = state == .completed ? outputURLs : []
        items[index].errorMessage = state == .failed ? errorMessage : nil
        items[index].errorDetail = state == .failed ? errorDetail : nil
        if state == .completed {
            items[index].progress = 1
            if warning { items[index].logEntries.append(OperationLogEntry(level: .warning, message: detail)) }
        }
        finishItem(at: index, finishedAt: finishedAt)
        if state == .failed {
            items[index].failureReportURL = failureReportStore.writeReport(for: items[index])
        }
        unlockBundle(for: id)
        _ = trimCompletedItemsIfNeeded()
        publishTerminalChange(id: id, previousOrder: previousOrder)
        if state == .completed, !bundleURLs.isEmpty {
            if let onBundleReadyWithContext {
                onBundleReadyWithContext(bundleURLs, routeContext)
            } else {
                onBundleReady?(bundleURLs)
            }
        }
        postStateChangedNotification(id: id, state: state)
        // Existing UI guards must reject suppressed success and failure results.
        return state == requestedState
    }

    /// Requests cancellation. Callback return never releases the worker's bundle lock.
    /// Running operations without a cancel callback are left unchanged because the
    /// center has no mechanism to stop their underlying work.
    public func cancel(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .running,
              let onCancel = items[index].onCancel else { return }
        items[index].state = .cancelling
        items[index].detail = "Cancelling..."
        items[index].onCancel = nil
        changes.send(.updated(id: id, index: index))
        postStateChangedNotification(id: id, state: .cancelling)

        DispatchQueue.global(qos: .userInitiated).async {
            onCancel()
        }
    }

    /// Cancels all running operations.
    public func cancelAll() {
        let runningIDs = items.filter { $0.state == .running }.map(\.id)
        for id in runningIDs {
            cancel(id: id)
        }
    }

    public func clearCompleted() {
        let removedIDs = items.filter { !$0.state.isActive }.map(\.id)
        items.removeAll { !$0.state.isActive }
        notifyRemovedItems(removedIDs)
    }

    /// Removes a single finished item by ID.
    ///
    /// Running operations cannot be cleared — cancel them first.
    ///
    /// - Parameter id: The item to remove.
    public func clearItem(id: UUID) {
        let shouldRemove = items.contains { $0.id == id && !$0.state.isActive }
        items.removeAll { $0.id == id && !$0.state.isActive }
        if shouldRemove {
            changes.send(.removed(ids: [id]))
        }
    }

    private func trimCompletedItemsIfNeeded() -> [UUID] {
        let keepLimit = 20
        let previousIDs = Set(items.map(\.id))
        let running = items.filter { $0.state.isActive }
        let finished = items
            .filter { !$0.state.isActive }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }

        items = running + Array(finished.prefix(max(0, keepLimit - running.count)))
        let currentIDs = Set(items.map(\.id))
        return previousIDs.subtracting(currentIDs).map { $0 }
    }

    private func finishItem(at index: Int, finishedAt: Date) {
        items[index].finishedAt = finishedAt
        items[index].wallTimeSeconds = max(0, finishedAt.timeIntervalSince(items[index].startedAt))
    }

    private func notifyRemovedItems(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        changes.send(.removed(ids: ids))
    }

    private func publishTerminalChange(id: UUID, previousOrder: [UUID]) {
        let currentOrder = items.map(\.id)
        guard currentOrder == previousOrder,
              let index = items.firstIndex(where: { $0.id == id }) else {
            changes.send(.reloaded)
            return
        }
        changes.send(.updated(id: id, index: index))
    }
}

// MARK: - ETA Formatting

/// Formats a time interval as a compact ETA string (e.g., "2m 30s", "45s", "<1s").
private func formatETAInterval(_ interval: TimeInterval) -> String {
    let secs = max(0, Int(interval))
    if secs < 60 { return secs < 2 ? "<1s" : "\(secs)s" }
    let m = secs / 60
    let s = secs % 60
    if m < 60 { return s > 0 ? "\(m)m \(s)s" : "\(m)m" }
    let h = m / 60
    let rem = m % 60
    return rem > 0 ? "\(h)h \(rem)m" : "\(h)h"
}
