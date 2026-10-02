// RecordingOperationReporter.swift - An OperationReporting test double that records every call
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// Records every call operation code makes through `OperationReporting`, so a
/// test can check what a launch site registered without touching
/// `OperationCenter.shared`.
///
/// Set ``lockHeldBy`` (or pass it to the initializer) to make `begin` return
/// `.refused`, as it does when another operation holds the bundle lock. The
/// refused call is still recorded, with state ``Item/State-swift.enum/refused``,
/// so a test can check the lock the site asked for.
///
/// Terminal calls follow `OperationCenter`: they return `false` once the item
/// has finished, and a completion or failure that arrives while a cancel is
/// pending records `.cancelled` and returns `false`. Unlike `OperationCenter`,
/// ``cancel(id:)`` runs the cancel callback synchronously, so a test needs no
/// wait to see it.
@MainActor
public final class RecordingOperationReporter: OperationReporting {
    /// One `begin` call and everything reported against its id.
    public struct Item: Identifiable, Sendable {
        public enum State: String, Sendable, Equatable {
            case running
            case cancelling
            case completed
            case failed
            case cancelled
            /// `begin` returned `.refused`. Nothing should run.
            case refused
        }

        public struct ProgressUpdate: Sendable, Equatable {
            /// Nil for an ``RecordingOperationReporter/updateProgress(id:evidence:detail:)``
            /// or ``RecordingOperationReporter/updateBytes(id:bytesDownloaded:totalBytes:)`` call.
            public let progress: Double?
            public let detail: String
            /// The evidence an `updateProgress` call passed, if any.
            public let evidence: OperationProgressEvidence?
        }

        public struct LogEntry: Sendable, Equatable {
            public let level: OperationLogLevel
            public let message: String
        }

        public struct Failure: Sendable, Equatable {
            public let detail: String
            public let errorMessage: String?
            public let errorDetail: String?
        }

        public let id: UUID
        public let title: String
        public let initialDetail: String
        public let operationType: OperationType
        public let targetBundleURL: URL?
        public let additionalLockedBundleURLs: [URL]
        public let startedAt: Date
        public let workflowRunID: UUID?
        public let routeContext: OperationRouteContext?
        /// The command passed to `begin`, replaced by any later `setCommand`.
        public internal(set) var cliCommand: String?
        public internal(set) var state: State
        /// The latest detail text from `begin`, an update or a terminal call.
        public internal(set) var detail: String
        public internal(set) var progressUpdates: [ProgressUpdate] = []
        public internal(set) var logs: [LogEntry] = []
        public internal(set) var hasCancelCallback: Bool
        public internal(set) var cancelRequested = false
        public internal(set) var completedWithWarning = false
        public internal(set) var bundleURLs: [URL] = []
        public internal(set) var outputURLs: [URL] = []
        public internal(set) var failure: Failure?
        public internal(set) var trackedAnalysisOutputs: [URL] = []

        public var isActive: Bool { state == .running || state == .cancelling }
    }

    /// Every `begin` call in order, including refused ones.
    public private(set) var items: [Item] = []

    /// When non-nil, `begin` returns `.refused` as if an operation with this
    /// title held the requested bundle lock.
    public var lockHeldBy: String?

    private var cancelCallbacks: [UUID: @Sendable () -> Void] = [:]

    public init(lockHeldBy: String? = nil) {
        self.lockHeldBy = lockHeldBy
    }

    /// The items `begin` started, in order.
    public var startedItems: [Item] { items.filter { $0.state != .refused } }

    /// The item with `id`, if `begin` recorded one.
    public func item(_ id: UUID) -> Item? {
        items.first { $0.id == id }
    }

    // MARK: - OperationReporting

    public func begin(
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
    ) -> OperationStartResult {
        let id = UUID()
        let refusedBy = lockHeldBy
        let message = refusedBy.map {
            "\"\($0)\" is currently running on this bundle. Please wait for it to finish."
        }
        items.append(Item(
            id: id,
            title: title,
            initialDetail: detail,
            operationType: operationType,
            targetBundleURL: targetBundleURL,
            additionalLockedBundleURLs: additionalLockedBundleURLs,
            startedAt: startedAt,
            workflowRunID: workflowRunID,
            routeContext: routeContext,
            cliCommand: cliCommand,
            state: refusedBy == nil ? .running : .refused,
            detail: message ?? detail,
            hasCancelCallback: refusedBy == nil && onCancel != nil
        ))
        if let refusedBy, let message {
            return .refused(OperationStartRefusal(id: id, blockedBy: refusedBy, message: message))
        }
        if let onCancel { cancelCallbacks[id] = onCancel }
        return .started(id)
    }

    public func setCancelCallback(for id: UUID, callback: @escaping @Sendable () -> Void) {
        guard let index = index(of: id), items[index].state == .running else { return }
        cancelCallbacks[id] = callback
        items[index].hasCancelCallback = true
    }

    public func setCommand(id: UUID, command: String) {
        guard let index = index(of: id), items[index].isActive else { return }
        items[index].cliCommand = command
    }

    @discardableResult
    public func update(id: UUID, progress: Double, detail: String) -> Bool {
        recordProgress(id: id, progress: progress, detail: detail, logLevel: nil)
    }

    @discardableResult
    public func updateWithLog(
        id: UUID,
        progress: Double,
        detail: String,
        level: OperationLogLevel,
        deduplicateAdjacent: Bool
    ) -> Bool {
        recordProgress(id: id, progress: progress, detail: detail, logLevel: level)
    }

    @discardableResult
    public func updateProgress(id: UUID, evidence: OperationProgressEvidence?, detail: String) -> Bool {
        recordProgress(id: id, progress: nil, detail: detail, logLevel: nil, evidence: evidence)
    }

    public func updateBytes(id: UUID, bytesDownloaded: Int64, totalBytes: Int64?) {
        let total = totalBytes.map { " of \($0)" } ?? ""
        _ = recordProgress(id: id, progress: nil, detail: "\(bytesDownloaded) bytes\(total)", logLevel: nil)
    }

    public func log(id: UUID, level: OperationLogLevel, message: String) {
        guard let index = index(of: id) else { return }
        items[index].logs.append(Item.LogEntry(level: level, message: message))
    }

    public func trackAnalysisOutput(_ url: URL, for id: UUID) {
        guard let index = index(of: id) else { return }
        items[index].trackedAnalysisOutputs.append(url)
    }

    @discardableResult
    public func complete(id: UUID, detail: String, finishedAt: Date) -> Bool {
        finish(id: id, as: .completed, detail: detail)
    }

    @discardableResult
    public func complete(id: UUID, detail: String, bundleURLs: [URL], finishedAt: Date) -> Bool {
        finish(id: id, as: .completed, detail: detail, bundleURLs: bundleURLs)
    }

    @discardableResult
    public func complete(id: UUID, detail: String, outputURLs: [URL], finishedAt: Date) -> Bool {
        finish(id: id, as: .completed, detail: detail, outputURLs: outputURLs)
    }

    @discardableResult
    public func completeWithWarning(id: UUID, detail: String) -> Bool {
        finish(id: id, as: .completed, detail: detail, warning: true)
    }

    @discardableResult
    public func completeWithWarning(id: UUID, detail: String, bundleURLs: [URL]) -> Bool {
        finish(id: id, as: .completed, detail: detail, bundleURLs: bundleURLs, warning: true)
    }

    @discardableResult
    public func completeWithWarning(id: UUID, detail: String, outputURLs: [URL]) -> Bool {
        finish(id: id, as: .completed, detail: detail, outputURLs: outputURLs, warning: true)
    }

    @discardableResult
    public func fail(
        id: UUID,
        detail: String,
        errorMessage: String?,
        errorDetail: String?,
        finishedAt: Date
    ) -> Bool {
        finish(
            id: id,
            as: .failed,
            detail: detail,
            failure: Item.Failure(detail: detail, errorMessage: errorMessage, errorDetail: errorDetail)
        )
    }

    @discardableResult
    public func acknowledgeCancellation(id: UUID, detail: String, finishedAt: Date) -> Bool {
        finish(id: id, as: .cancelled, detail: detail)
    }

    public func cancel(id: UUID) {
        guard let index = index(of: id), items[index].state == .running,
              let callback = cancelCallbacks.removeValue(forKey: id) else { return }
        items[index].state = .cancelling
        items[index].cancelRequested = true
        items[index].hasCancelCallback = false
        callback()
    }

    // MARK: - Recording

    private func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    private func recordProgress(
        id: UUID,
        progress: Double?,
        detail: String,
        logLevel: OperationLogLevel?,
        evidence: OperationProgressEvidence? = nil
    ) -> Bool {
        guard let index = index(of: id), items[index].state == .running else { return false }
        items[index].progressUpdates.append(Item.ProgressUpdate(progress: progress, detail: detail, evidence: evidence))
        items[index].detail = detail
        if let logLevel {
            items[index].logs.append(Item.LogEntry(level: logLevel, message: detail))
        }
        return true
    }

    private func finish(
        id: UUID,
        as requested: Item.State,
        detail: String,
        bundleURLs: [URL] = [],
        outputURLs: [URL] = [],
        warning: Bool = false,
        failure: Item.Failure? = nil
    ) -> Bool {
        guard let index = index(of: id), items[index].isActive else { return false }
        cancelCallbacks[id] = nil
        items[index].hasCancelCallback = false
        let cancellationWon = items[index].state == .cancelling
        let state: Item.State = cancellationWon ? .cancelled : requested
        items[index].state = state
        items[index].detail = cancellationWon ? "Cancelled by user" : detail
        if state == .completed {
            items[index].bundleURLs = bundleURLs
            items[index].outputURLs = outputURLs
            items[index].completedWithWarning = warning
        }
        if state == .failed {
            items[index].failure = failure
        }
        return state == requested
    }
}
