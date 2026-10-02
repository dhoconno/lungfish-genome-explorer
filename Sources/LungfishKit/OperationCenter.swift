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
    case mapping = "Mapping"
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
    /// True for the single synthetic entry `appendLogEntryCapped` inserts in
    /// place of the elided middle entries once a log exceeds
    /// `Item.maxRetainedLogEntries`. Never set by ordinary log calls.
    public let isElisionMarker: Bool

    public init(timestamp: Date = Date(), level: OperationLogLevel, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.isElisionMarker = false
    }

    fileprivate init(elidedCount: Int, timestamp: Date) {
        self.timestamp = timestamp
        self.level = .info
        self.message = "… \(elidedCount) entr\(elidedCount == 1 ? "y" : "ies") omitted"
        self.isElisionMarker = true
    }
}

/// The reason `OperationCenter.begin` refused to start an operation.
///
/// Currently the only refusal reason is a conflicting bundle lock, but this is
/// a struct (not a bare string) so a future refusal reason can be added
/// without changing every caller's switch statement into a compile error in
/// the wrong place.
public struct OperationStartRefusal: Sendable {
    /// The id of the visible "Bundle is busy" failed row `OperationCenter`
    /// inserted for this refusal, so a caller that wants to reference it
    /// (for example, to log alongside the refusal) can.
    public let id: UUID
    /// The title of the operation currently holding the conflicting lock.
    public let blockingOperationTitle: String
    /// A user-facing message describing the conflict, matching the failed
    /// row's `detail` text.
    public let message: String
}

/// The result of `OperationCenter.begin`, which the caller must switch on
/// before doing any work that mutates the target bundle or launches a
/// subprocess/transport.
public enum OperationStartResult: Sendable {
    /// The operation was registered and is `.running`. The caller may proceed.
    case started(UUID)
    /// A bundle lock conflicted. The caller MUST NOT launch a subprocess,
    /// transport, or bundle mutation. A visible "Bundle is busy" failed row
    /// has already been inserted; the caller needs to do nothing further
    /// unless it wants to log or present its own message using `refusal`.
    case refused(OperationStartRefusal)

    /// The started operation's id, or `nil` when refused.
    public var startedID: UUID? {
        if case .started(let id) = self { return id }
        return nil
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
            /// An analysis run found on disk whose producer is gone: its result
            /// directory still carries an ``AnalysisRunRecord``. Listed for
            /// review and removal only, never created by a running operation.
            case interrupted

            public var isActive: Bool {
                self == .running || self == .cancelling
            }
        }

        public let id: UUID
        public var title: String
        public var detail: String
        /// Legacy compatibility value; not evidence of measured work or remaining time.
        public var progress: Double
        public private(set) var progressEvidence: OperationProgressEvidence?
        private var progressRate = OperationProgressRate()

        fileprivate mutating func setProgressEvidence(_ evidence: OperationProgressEvidence?) {
            progressEvidence = evidence
            progressRate.record(evidence)
        }

        public var displayProgressFraction: Double? {
            state.isActive ? progressEvidence?.validatedFraction : nil
        }

        /// Lifecycle stays visible even when a qualified percentage is available.
        public var displayProgressLabel: String {
            guard let fraction = displayProgressFraction, let evidence = progressEvidence else {
                return displayStateLabel
            }
            let qualifier = evidence.basis == .estimated ? "≈" : ""
            let scope = evidence.scope == .stage ? " of stage" : ""
            return "\(displayStateLabel) · \(qualifier)\(Int((fraction * 100).rounded()))%\(scope)"
        }

        public func estimatedRemainingTime(at date: Date) -> TimeInterval? {
            guard state == .running else { return nil }
            return progressRate.remainingTime(at: date)
        }

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
        ///
        /// PERF-15: bounded by ``appendLogEntryCapped(_:)`` to at most
        /// ``maxRetainedLogEntries`` (the first ``keepFirstLogEntries`` plus
        /// the most recent entries, joined by one elision-marker entry once
        /// the cap is exceeded), so a long-running operation with many
        /// tool-invocation log lines does not grow this array without bound.
        public var logEntries: [OperationLogEntry] = []

        /// The total number of log entries ever recorded for this operation,
        /// including ones ``appendLogEntryCapped(_:)`` has since elided from
        /// ``logEntries``. Also supports pending-line counts in the log inspector.
        fileprivate var totalLogEntryCount = 0
        /// Lifetime count, including entries omitted from the bounded preview.
        public var logEntryCount: Int { max(totalLogEntryCount, logEntries.count) }
        public var latestLogEntry: OperationLogEntry? { logEntries.last }
        /// Outcome evidence is retained independently of the preview cap.
        public private(set) var warningCount = 0

        /// Entries kept from the start of the log when the cap is exceeded.
        fileprivate static let keepFirstLogEntries = 100
        /// Total entries retained in ``logEntries`` once capped (first +
        /// most-recent + one elision marker).
        public static let maxRetainedLogEntries = 2_000

        /// Appends one log entry, then re-applies the retention cap.
        ///
        /// Once ``totalLogEntryCount`` exceeds ``maxRetainedLogEntries``, this
        /// keeps the first ``keepFirstLogEntries`` entries, drops from the
        /// middle, and keeps enough of the tail (including the entry just
        /// appended) to stay at the cap, replacing the dropped span with a
        /// single "N entries omitted" marker. Each call after that only has
        /// to drop the marker, the new oldest kept-tail entry, and insert an
        /// updated marker plus the new entry, so cost stays O(1) amortized
        /// rather than re-scanning the whole log on every call.
        /// Ends a failed operation's log with why it failed. Without this the
        /// log (and the row's latest-line) stopped at the last progress
        /// message, such as "Running minimap2...", and the error only showed
        /// in the row subtitle. Texts the worker already logged as the most
        /// recent entries are not repeated.
        fileprivate mutating func appendFailureLogEntries(
            detail: String,
            errorMessage: String?,
            errorDetail: String?
        ) {
            var texts: [String] = []
            for candidate in [errorMessage, detail, errorDetail] {
                guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty,
                      !texts.contains(text) else { continue }
                texts.append(text)
            }
            let recentMessages = Set(logEntries.suffix(3).map {
                $0.message.trimmingCharacters(in: .whitespacesAndNewlines)
            })
            for (offset, text) in texts.enumerated() where !recentMessages.contains(text) {
                let message = offset == 0 ? "Failed: \(text)" : text
                guard !recentMessages.contains(message) else { continue }
                appendLogEntryCapped(OperationLogEntry(level: .error, message: message))
            }
        }

        fileprivate mutating func appendLogEntryCapped(_ entry: OperationLogEntry) {
            logEntries.append(entry)
            totalLogEntryCount += 1
            if entry.level == .warning { warningCount += 1 }
            guard logEntries.count > Self.maxRetainedLogEntries else { return }

            let keepFirst = Self.keepFirstLogEntries
            // Reserve one slot for the elision marker itself.
            let keepLastCount = Self.maxRetainedLogEntries - keepFirst - 1
            let firstEntries = Array(logEntries.prefix(keepFirst))
            let lastEntries = Array(logEntries.suffix(keepLastCount))
            let elidedCount = totalLogEntryCount - firstEntries.count - lastEntries.count
            let marker = OperationLogEntry(elidedCount: max(0, elidedCount), timestamp: entry.timestamp)
            logEntries = firstEntries + [marker] + lastEntries
        }
        /// Retry metadata for rate limits or transient failures.
        public var retryEvents: [OperationRetryMetadata] = []
        /// User-facing error summary shown prominently on failure.
        public var errorMessage: String?
        /// Extended diagnostic detail (stack trace, stderr, etc.) for debugging.
        public var errorDetail: String?
        /// Durable workflow run identifier carried by parent and child rows.
        public var workflowRunID: UUID?
        /// The project/window context that launched this operation, when available.
        public var routeContext: OperationRouteContext?
        /// Where the automatic failure report for this operation was written.
        /// Nil until the operation fails, and also when the report could not be
        /// written (a logging failure is never allowed to escalate).
        public var failureReportURL: URL?
        /// For an ``State/interrupted`` row: the incomplete result directory
        /// that "Remove Partial Output" and "Reveal in Finder" act on.
        public var interruptedRunDirectory: URL?
        /// For an ``State/interrupted`` row: scratch folders in the project's
        /// `.tmp/` that the run's (gone) producer left behind. Their size is
        /// part of the row's size on disk, and "Remove Partial Output"
        /// removes them after checking again that no live process owns them.
        public var interruptedRunScratchDirectories: [URL] = []

        public var hasWarnings: Bool {
            warningCount > 0 || logEntries.contains { $0.level == .warning }
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
            case .interrupted:
                return "Interrupted"
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
    /// Operations that ``cancel(id:)`` forced to `.cancelled` after the grace
    /// period while their worker was still running (NEW-08), keyed by ID with a
    /// snapshot of the item. Their bundle locks stay held until the worker
    /// itself calls a terminal method, because it may still be writing.
    private var abandonedWorkers: [UUID: Item] = [:]

    /// Incomplete analysis directories and the operations (or holds) whose
    /// outcome decides them, keyed by standardized path.
    private struct AnalysisOutputTracking {
        let directory: URL
        var pending: Set<UUID>
        var succeeded: Bool
        var outcome: AnalysisRunRecord.Outcome?
    }

    private var analysisOutputs: [String: AnalysisOutputTracking] = [:]

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

    /// All currently running or cancelling operations.
    ///
    /// Used by FEA-06's quit and window-close warnings: `applicationShouldTerminate`
    /// checks every active item, while a window-close check narrows to
    /// ``activeItems(forProjectURL:)`` so closing one project window does not
    /// warn about work running in a different project's window.
    public var activeItems: [Item] {
        items.filter { $0.state.isActive }
    }

    /// Active operations whose ``OperationRouteContext/projectURL`` matches
    /// `projectURL`, plus any active operation with no route context (routing
    /// is best-effort, so an unrouted operation is treated as belonging to
    /// every window rather than silently ignored).
    public func activeItems(forProjectURL projectURL: URL?) -> [Item] {
        guard let projectURL else { return activeItems }
        let standardized = projectURL.standardizedFileURL
        return activeItems.filter { item in
            guard let itemProjectURL = item.routeContext?.projectURL else { return true }
            return itemProjectURL == standardized
        }
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
                  let owner = items.first(where: { $0.id == lock.operationID && $0.state.isActive })
                    ?? abandonedWorkers[lock.operationID] else { continue }
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
    /// This entry point cannot tell its caller whether the bundle lock refused
    /// the operation: it always returns a normal `UUID`, even when the row it
    /// inserted is already `.failed` ("Bundle is busy"). Any caller that passes
    /// `targetBundleURL` or `additionalLockedBundleURLs` — i.e. any caller for
    /// whom the refusal matters — must use ``begin(title:detail:operationType:targetBundleURL:additionalLockedBundleURLs:startedAt:cliCommand:workflowRunID:routeContext:onCancel:)``
    /// instead, and must not launch a subprocess or mutate the bundle unless it
    /// receives `.started`. This overload remains for callers with no bundle
    /// target, where refusal cannot occur.
    ///
    /// - Parameters:
    ///   - title: Human-readable operation title.
    ///   - detail: Initial status detail text.
    ///   - operationType: The category of operation.
    ///   - targetBundleURL: Optional bundle URL for locking.
    ///   - cliCommand: Optional reconstructed CLI invocation for display.
    ///   - onCancel: Callback invoked if the user cancels the operation.
    /// - Returns: The unique ID for the new operation item.
    @available(*, deprecated, message: "Use begin(...) when the operation carries a targetBundleURL or additionalLockedBundleURLs, so a bundle-lock refusal cannot be ignored.")
    @discardableResult
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
        insertOperation(
            title: title,
            detail: detail,
            operationType: operationType,
            targetBundleURL: targetBundleURL,
            additionalLockedBundleURLs: additionalLockedBundleURLs,
            startedAt: startedAt,
            cliCommand: cliCommand,
            workflowRunID: workflowRunID,
            routeContext: routeContext,
            onCancel: onCancel
        ).id
    }

    /// Starts tracking a new operation, refusing a call the caller cannot ignore.
    ///
    /// Unlike ``start(title:detail:operationType:targetBundleURL:additionalLockedBundleURLs:startedAt:cliCommand:workflowRunID:routeContext:onCancel:)``,
    /// this makes a bundle-lock conflict a value the caller must switch on. The
    /// visible "Bundle is busy" failed row is still inserted on refusal (same
    /// behaviour as `start`) so the Operations panel keeps showing what
    /// happened; only the return type changes so the refusal cannot be
    /// dropped on the floor.
    ///
    /// Callers MUST NOT launch a subprocess, transport, or bundle mutation
    /// before checking the result, and MUST NOT do so at all when the result
    /// is `.refused`.
    ///
    /// - Returns: `.started(UUID)` when the operation was registered and is
    ///   now `.running`, or `.refused(OperationStartRefusal)` when a bundle
    ///   lock conflicted. The refused case's `id` is the id of the visible
    ///   failed row, in case the caller wants to reference it.
    public func begin(
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
    ) -> OperationStartResult {
        let outcome = insertOperation(
            title: title,
            detail: detail,
            operationType: operationType,
            targetBundleURL: targetBundleURL,
            additionalLockedBundleURLs: additionalLockedBundleURLs,
            startedAt: startedAt,
            cliCommand: cliCommand,
            workflowRunID: workflowRunID,
            routeContext: routeContext,
            onCancel: onCancel
        )
        guard let refusal = outcome.refusal else { return .started(outcome.id) }
        return .refused(refusal)
    }

    private struct InsertOutcome {
        let id: UUID
        let refusal: OperationStartRefusal?
    }

    private func insertOperation(
        title: String,
        detail: String,
        operationType: OperationType,
        targetBundleURL: URL?,
        additionalLockedBundleURLs: [URL],
        startedAt: Date,
        cliCommand: String?,
        workflowRunID: UUID?,
        routeContext: OperationRouteContext?,
        onCancel: (@Sendable () -> Void)?
    ) -> InsertOutcome {
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
            return InsertOutcome(
                id: id,
                refusal: OperationStartRefusal(id: id, blockingOperationTitle: lockHolder.title, message: blockedDetail)
            )
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
        return InsertOutcome(id: id, refusal: nil)
    }

    /// Sets the cancellation callback for an existing operation.
    /// Useful when the operation must be registered before the cancellable task handle exists.
    public func setCancelCallback(for id: UUID, callback: @escaping @Sendable () -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .running else { return }
        items[index].onCancel = callback
        changes.send(.updated(id: id, index: index))
    }

    /// Records the exact current native invocation once a workflow launches it.
    public func setCommand(id: UUID, command: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state.isActive else { return }
        items[index].cliCommand = command
        changes.send(.updated(id: id, index: index))
    }

    @discardableResult
    public func update(id: UUID, progress: Double, detail: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard items[index].state == .running else { return false }
        items[index].setProgressEvidence(nil)
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
        items[index].setProgressEvidence(nil)
        items[index].progress = max(0, min(1, progress))
        items[index].detail = detail

        if deduplicateAdjacent,
           items[index].logEntries.last?.message == detail,
           items[index].logEntries.last?.level == level {
            changes.send(.updated(id: id, index: index))
            return true
        }
        let entry = OperationLogEntry(level: level, message: detail)
        items[index].appendLogEntryCapped(entry)
        changes.send(.updated(id: id, index: index))
        return true
    }

    /// Records scoped, qualified progress. Passing nil clears previous evidence and ETA.
    @discardableResult
    public func updateProgress(id: UUID, evidence: OperationProgressEvidence?, detail: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .running else { return false }
        items[index].setProgressEvidence(evidence)
        items[index].progress = evidence?.validatedFraction ?? 0
        items[index].detail = detail
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

    /// Records measured byte progress. Nil total means no new total; an explicitly
    /// invalid total clears the previous denominator. ETA is presented separately
    /// through `Item.estimatedRemainingTime(at:)`, so detail never contains a stale ETA.
    public func updateBytes(id: UUID, bytesDownloaded: Int64, totalBytes: Int64?) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .running else { return }
        items[index].bytesDownloaded = bytesDownloaded
        if let totalBytes { items[index].totalBytes = totalBytes > 0 ? totalBytes : nil }
        let effectiveTotal = items[index].totalBytes
        let evidence = OperationProgressEvidence(
            phase: "bytes", scope: .overall, basis: .measured,
            completed: Double(bytesDownloaded), total: effectiveTotal.map(Double.init), unit: "bytes"
        )
        items[index].setProgressEvidence(evidence)
        items[index].progress = evidence.validatedFraction ?? 0
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        let downloaded = formatter.string(fromByteCount: bytesDownloaded)
        if let total = effectiveTotal {
            items[index].detail = "\(downloaded) / \(formatter.string(fromByteCount: total))"
        } else {
            items[index].detail = downloaded
        }
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
        items[index].appendLogEntryCapped(entry)
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
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .running else { return }
        items[index].setProgressEvidence(nil)
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
        items[index].appendLogEntryCapped(OperationLogEntry(level: .warning, message: logMessage))
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
        finishedAt: Date = Date(),
        retainBundleLock: Bool = false
    ) -> Bool {
        if abandonedWorkers.removeValue(forKey: id) != nil {
            // The abandoned worker finally returned: its result is discarded
            // (the operation is already cancelled) but its lock is released now.
            unlockBundle(for: id)
            return false
        }
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
            if warning { items[index].appendLogEntryCapped(OperationLogEntry(level: .warning, message: detail)) }
        }
        if state == .failed {
            items[index].appendFailureLogEntries(
                detail: detail, errorMessage: errorMessage, errorDetail: errorDetail
            )
        }
        finishItem(at: index, finishedAt: finishedAt)
        if state == .failed {
            items[index].failureReportURL = failureReportStore.writeReport(for: items[index])
        }
        // A producer that completes with a detail only (Kraken2, EsViritu,
        // TaxTriage, ...) still made a result: the analysis directory it
        // tracked. Record it so the Operations Panel's Results button and
        // Reveal Output Files work. It is not passed to `onBundleReady`,
        // which imports downloaded bundles.
        if state == .completed, bundleURLs.isEmpty {
            let tracked = trackedAnalysisDirectories(for: id)
            if !tracked.isEmpty { items[index].bundleURLs = tracked }
        }
        // Before any terminal notification, so a caller that refreshes the
        // sidebar or selects the result right after completing finds it.
        settleAnalysisOutputs(
            for: id,
            succeeded: state == .completed,
            outcome: state == .failed ? .failed : (state == .cancelled ? .cancelled : nil)
        )
        if retainBundleLock {
            abandonedWorkers[id] = items[index]
        } else {
            unlockBundle(for: id)
        }
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
    ///
    /// NEW-08: `onCancel` only *signals* the worker (e.g. `task.cancel()`, killing a
    /// subprocess tree); it does not, by itself, guarantee the worker's `Task` ever
    /// returns to call a terminal method (`complete`/`fail`/`acknowledgeCancellation`).
    /// A worker blocked in an uninterruptible pre-tool stage -- a synchronous
    /// filesystem call stuck waiting on something outside the process, for
    /// example -- never observes `Task.isCancelled` and never returns, so without a
    /// fallback the operation stays `.cancelling` (shown as active, bundle still
    /// locked) forever, exactly as NEW-08 was found live: tool processes gone, but
    /// the row never left the active list. After ``cancelGracePeriod``, if the
    /// operation is still `.cancelling`, this forces it to a terminal `.cancelled`
    /// state and releases its bundle lock itself. `finishWorker`'s own guard
    /// (`state.isActive`) then makes a late-returning worker's own terminal call a
    /// safe no-op -- it cannot resurrect or double-complete an operation this
    /// already closed out.
    ///
    /// The forced path does NOT release the bundle lock: the worker may still be
    /// running (a tool ignoring SIGTERM, a large copy finishing) and could write
    /// into a bundle another operation has just locked. The lock stays held,
    /// through ``abandonedWorkers``, until the worker itself calls a terminal
    /// method. The operation leaves the active list, so Cancel All, the quit
    /// warning and the Operations menu no longer wait on it.
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

        let gracePeriod = cancelGracePeriod
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(gracePeriod))
            guard let self else { return }
            self.forceAcknowledgeCancellationIfStillCancelling(id: id)
        }
    }

    /// How long ``cancel(id:)`` waits for a worker to return on its own after
    /// being signalled before forcing the operation to `.cancelled`. Overridable
    /// only for tests, so a grace-period test does not need to wait the
    /// production duration.
    var cancelGracePeriod: TimeInterval = 10

    /// Forces a still-`.cancelling` operation to `.cancelled` and releases its
    /// bundle lock. A no-op if the operation already reached any terminal state
    /// (including a worker that returned in time and completed/failed normally,
    /// which already raced `finishWorker`'s cancellation-wins rule) or if it is
    /// no longer `.cancelling` for any other reason.
    private func forceAcknowledgeCancellationIfStillCancelling(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .cancelling else { return }
        // `finishWorker` always writes the plain "Cancelled by user" detail
        // once cancellation wins, so the diagnostic that this was a *forced*
        // cancellation (the worker never came back on its own) is recorded
        // as a log entry instead, where the Operations Panel's expanded row
        // history can still surface it.
        items[index].appendLogEntryCapped(
            OperationLogEntry(
                level: .warning,
                message: "Worker did not respond to cancellation within \(Int(cancelGracePeriod))s; marked cancelled. Its bundle stays locked until the worker exits."
            )
        )
        _ = finishWorker(id: id, state: .cancelled, detail: "Cancelled by user", retainBundleLock: true)
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

    // MARK: - Analysis run outputs

    /// Ties an incomplete analysis directory to an operation.
    ///
    /// `url` may be the result directory itself or any directory inside it
    /// (a batch sample directory resolves to its batch root). When every
    /// operation and hold tracking the directory has finished and at least
    /// one of them completed (completed with warnings included), its
    /// ``AnalysisRunRecord`` is removed so the result appears, and
    /// `Notification.Name.analysisRunOutputsCompleted` is posted. Failed and
    /// cancelled runs leave the record, so the directory stays hidden.
    /// A directory without a record (complete or legacy) is ignored.
    public func trackAnalysisOutput(_ url: URL, for id: UUID) {
        guard let directory = AnalysisRunRecord.enclosingIncompleteDirectory(for: url) else { return }
        let key = directory.standardizedFileURL.path
        if let command = items.first(where: { $0.id == id })?.cliCommand,
           AnalysisRunRecord.load(from: directory)?.command == nil {
            AnalysisRunRecord.updateCommand(command, in: directory)
        }
        guard let item = items.first(where: { $0.id == id }), item.state.isActive else {
            // The operation already finished: settle against its outcome now.
            var tracking = analysisOutputs[key] ?? AnalysisOutputTracking(directory: directory, pending: [], succeeded: false, outcome: nil)
            if let index = items.firstIndex(where: { $0.id == id }), items[index].state == .completed {
                tracking.succeeded = true
                if items[index].bundleURLs.isEmpty {
                    items[index].bundleURLs = [directory]
                    changes.send(.updated(id: id, index: index))
                }
            }
            analysisOutputs[key] = tracking
            settleIfIdle(key: key)
            return
        }
        var tracking = analysisOutputs[key] ?? AnalysisOutputTracking(directory: directory, pending: [], succeeded: false, outcome: nil)
        tracking.pending.insert(id)
        analysisOutputs[key] = tracking
    }

    /// Keeps an incomplete directory hidden across several operations run
    /// one after another (a sequential batch). Release it after the last one.
    public func holdAnalysisOutput(_ url: URL) -> UUID {
        let token = UUID()
        guard let directory = AnalysisRunRecord.enclosingIncompleteDirectory(for: url) else { return token }
        let key = directory.standardizedFileURL.path
        var tracking = analysisOutputs[key] ?? AnalysisOutputTracking(directory: directory, pending: [], succeeded: false, outcome: nil)
        tracking.pending.insert(token)
        analysisOutputs[key] = tracking
        return token
    }

    /// Releases a ``holdAnalysisOutput(_:)`` token. `succeeded` adds to, and
    /// never overrides, the outcomes of the tracked operations.
    public func releaseAnalysisOutputHold(_ token: UUID, succeeded: Bool) {
        settleAnalysisOutputs(for: token, succeeded: succeeded)
    }

    /// Whether a live operation or hold still decides this directory.
    public func isTrackingAnalysisOutput(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        return !(analysisOutputs[key]?.pending.isEmpty ?? true)
    }

    /// The analysis directories an operation is still tracking, in path order.
    private func trackedAnalysisDirectories(for id: UUID) -> [URL] {
        analysisOutputs.values
            .filter { $0.pending.contains(id) }
            .map(\.directory)
            .sorted { $0.path < $1.path }
    }

    private func settleAnalysisOutputs(for id: UUID, succeeded: Bool, outcome: AnalysisRunRecord.Outcome? = nil) {
        let keys = analysisOutputs.compactMap { key, tracking in tracking.pending.contains(id) ? key : nil }
        guard !keys.isEmpty else { return }
        var completed: [URL] = []
        for key in keys {
            guard var tracking = analysisOutputs[key] else { continue }
            tracking.pending.remove(id)
            tracking.succeeded = tracking.succeeded || succeeded
            tracking.outcome = outcome ?? tracking.outcome
            analysisOutputs[key] = tracking
            if let url = settleIfIdle(key: key, notify: false) { completed.append(url) }
        }
        postAnalysisOutputsCompleted(completed)
    }

    @discardableResult
    private func settleIfIdle(key: String, notify: Bool = true) -> URL? {
        guard let tracking = analysisOutputs[key], tracking.pending.isEmpty else { return nil }
        analysisOutputs.removeValue(forKey: key)
        guard tracking.succeeded else {
            // Stays incomplete and hidden. The outcome only labels the row a
            // later project open lists for review.
            AnalysisRunRecord.recordOutcome(tracking.outcome ?? .failed, in: tracking.directory)
            return nil
        }
        AnalysisRunRecord.markComplete(tracking.directory)
        if notify { postAnalysisOutputsCompleted([tracking.directory]) }
        return tracking.directory
    }

    private func postAnalysisOutputsCompleted(_ directories: [URL]) {
        guard !directories.isEmpty else { return }
        NotificationCenter.default.post(
            name: .analysisRunOutputsCompleted,
            object: self,
            userInfo: ["directories": directories]
        )
    }

    // MARK: - Interrupted analysis runs

    /// An incomplete analysis directory whose producer is gone.
    public struct InterruptedAnalysisRun: Sendable {
        public let directory: URL
        public let record: AnalysisRunRecord?
        /// Size of the result directory plus its scratch folders.
        public let sizeOnDiskBytes: Int64
        public let projectURL: URL?
        /// Abandoned scratch folders in the project's `.tmp/` (see
        /// `AnalysisRunScratch` in LungfishIO).
        public let scratchDirectories: [URL]
        /// The part of ``sizeOnDiskBytes`` held by ``scratchDirectories``.
        public let scratchSizeOnDiskBytes: Int64

        public init(
            directory: URL,
            record: AnalysisRunRecord?,
            sizeOnDiskBytes: Int64,
            projectURL: URL? = nil,
            scratchDirectories: [URL] = [],
            scratchSizeOnDiskBytes: Int64 = 0
        ) {
            self.directory = directory
            self.record = record
            self.sizeOnDiskBytes = sizeOnDiskBytes
            self.projectURL = projectURL
            self.scratchDirectories = scratchDirectories
            self.scratchSizeOnDiskBytes = scratchSizeOnDiskBytes
        }
    }

    /// Lists an interrupted run in the Operations Panel as an
    /// ``Item/State/interrupted`` row. Nothing on disk is changed.
    ///
    /// - Returns: The new row's ID, or `nil` when the directory is already
    ///   listed or a live operation still tracks it.
    @discardableResult
    public func registerInterruptedAnalysisRun(_ run: InterruptedAnalysisRun) -> UUID? {
        let key = run.directory.standardizedFileURL.path
        guard !isTrackingAnalysisOutput(run.directory),
              !items.contains(where: { $0.interruptedRunDirectory?.standardizedFileURL.path == key })
        else { return nil }

        let name = run.record?.analysisName ?? run.directory.lastPathComponent
        let startedAt = run.record?.startedAt
            ?? ((try? run.directory.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date())
        let size = ByteCountFormatter.string(fromByteCount: run.sizeOnDiskBytes, countStyle: .file)
        let started = startedAt.formatted(date: .abbreviated, time: .shortened)
        let now = Date()
        let kind: String
        switch run.record?.outcome {
        case .failed: kind = "Failed run"
        case .cancelled: kind = "Cancelled run"
        case nil: kind = "Interrupted run"
        }
        var item = Item(
            title: "\(name): \(run.directory.lastPathComponent)",
            detail: "\(kind) started \(started) · \(size) on disk",
            progress: 0,
            state: .interrupted,
            operationType: .workflow,
            startedAt: startedAt,
            finishedAt: now,
            cliCommand: run.record?.command,
            routeContext: run.projectURL.map { OperationRouteContext(projectURL: $0, windowStateScopeID: nil) }
        )
        item.interruptedRunDirectory = run.directory
        item.interruptedRunScratchDirectories = run.scratchDirectories
        var lines = [
            "\(kind) of \(name) found at \(run.directory.path).",
            "It never finished, so its partial output is hidden from the sidebar.",
            "Started \(started); \(size) on disk.",
        ]
        if !run.scratchDirectories.isEmpty {
            let scratchSize = ByteCountFormatter.string(fromByteCount: run.scratchSizeOnDiskBytes, countStyle: .file)
            lines.append("That includes \(scratchSize) of temporary files the run left in the project:")
            lines.append(contentsOf: run.scratchDirectories.map { "  \($0.path)" })
        }
        if let record = run.record {
            lines.append("Recorded by process \(record.processIdentifier) on \(record.hostName).")
        }
        for line in lines {
            item.appendLogEntryCapped(OperationLogEntry(level: .warning, message: line))
        }
        items.insert(item, at: 0)
        changes.send(.inserted(id: item.id, index: 0))
        notifyRemovedItems(trimCompletedItemsIfNeeded())
        postStateChangedNotification(id: item.id, state: .interrupted)
        return item.id
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

// MARK: - Sequential analysis batches

/// Keeps a batch root hidden across children that run one after another,
/// without delaying it past the last child.
///
/// Between two children no operation tracks the batch root, so a hold keeps
/// it incomplete. The hold is released as soon as the **last** child has
/// started and tracks the root itself. The root is then marked complete by
/// that child's own completion (when any child completed), before the
/// caller refreshes the sidebar and selects the result, instead of only
/// after the batch loop ends.
@MainActor
public final class SequentialAnalysisBatchHold {
    private let center: OperationCenter
    private var token: UUID?
    private var remainingChildren: Int

    /// - Parameters:
    ///   - directory: The batch root, or `nil` when the batch has none
    ///     (every call is then a no-op).
    ///   - childCount: How many children the batch will try to start.
    public init(directory: URL?, childCount: Int, center: OperationCenter = .shared) {
        self.center = center
        self.remainingChildren = childCount
        self.token = directory.map { center.holdAnalysisOutput($0) }
    }

    /// Call once per child, after launching it: a started child tracks its
    /// output (and so the batch root) by then. A child that could not start
    /// counts too. After the last child, the hold is released.
    public func didLaunchChild() {
        remainingChildren -= 1
        if remainingChildren <= 0 { release(succeeded: false) }
    }

    /// Call once the batch loop has ended, whether it ran every child or
    /// stopped early. `succeeded` adds to the children's own outcomes.
    public func finish(succeeded: Bool) {
        release(succeeded: succeeded)
    }

    private func release(succeeded: Bool) {
        guard let token else { return }
        self.token = nil
        center.releaseAnalysisOutputHold(token, succeeded: succeeded)
    }
}
