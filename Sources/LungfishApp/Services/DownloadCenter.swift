// OperationCenter.swift - Centralized operation tracking with bundle locking
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
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
    case nfCoreWorkflow = "nf-core Workflow"
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

/// Log level for operation log entries.
///
/// Separate from ``LogLevel`` in WorkflowExecutionView to avoid coupling
/// the operation tracking system to the workflow UI module. The levels
/// mirror standard syslog severity tiers.
public enum OperationLogLevel: String, Sendable, Codable {
    case debug
    case info
    case warning
    case error
}

@MainActor
public final class OperationCenter: ObservableObject {
    public struct Item: Identifiable, Sendable {
        public enum State: String, Sendable {
            case running
            case completed
            case failed
        }

        public let id: UUID
        public var title: String
        public var detail: String
        public var progress: Double
        public var state: State
        public var operationType: OperationType
        public var startedAt: Date
        public var finishedAt: Date?
        /// File URLs produced by this operation (e.g. .lungfishref bundle paths).
        /// Set when the operation completes via ``complete(id:detail:bundleURLs:)``.
        public var bundleURLs: [URL]
        /// The bundle this operation is targeting, used for bundle locking.
        public var targetBundleURL: URL?
        /// Callback invoked when the user cancels this operation.
        public nonisolated(unsafe) var onCancel: (@Sendable () -> Void)?

        // MARK: - Enhanced diagnostics

        /// The reconstructed `lungfish [subcommand] [args]` CLI invocation, if applicable.
        public var cliCommand: String?
        /// Step-by-step log entries recorded during this operation.
        public var logEntries: [OperationLogEntry] = []
        /// User-facing error summary shown prominently on failure.
        public var errorMessage: String?
        /// Extended diagnostic detail (stack trace, stderr, etc.) for debugging.
        public var errorDetail: String?

        public var hasWarnings: Bool {
            logEntries.contains { $0.level == .warning }
        }

        public var displayStateLabel: String {
            switch state {
            case .running:
                return "Running"
            case .completed:
                return hasWarnings ? "Completed with Warnings" : "Completed"
            case .failed:
                return "Failed"
            }
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
            bundleURLs: [URL] = [],
            targetBundleURL: URL? = nil,
            onCancel: (@Sendable () -> Void)? = nil,
            cliCommand: String? = nil
        ) {
            self.id = id
            self.title = title
            self.detail = detail
            self.progress = progress
            self.state = state
            self.operationType = operationType
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.bundleURLs = bundleURLs
            self.targetBundleURL = targetBundleURL
            self.onCancel = onCancel
            self.cliCommand = cliCommand
        }
    }

    public static let shared = OperationCenter()

    @Published public private(set) var items: [Item] = []

    /// Called when an operation completes with bundle URLs that need importing.
    /// The AppDelegate sets this once at startup to handle bundle import.
    public var onBundleReady: (([URL]) -> Void)?

    /// Maps bundle path string to the operation ID that holds the lock.
    private var bundleLocks: [String: UUID] = [:]

    public var activeCount: Int {
        items.filter { $0.state == .running }.count
    }

    // MARK: - Bundle Locking

    /// Returns true if no running operation is currently targeting the given bundle.
    public func canStartOperation(on bundleURL: URL?) -> Bool {
        guard let bundleURL else { return true }
        let key = bundleURL.standardizedFileURL.path
        guard let lockHolder = bundleLocks[key] else { return true }
        // Verify the lock holder is still running (stale lock protection)
        return items.first(where: { $0.id == lockHolder && $0.state == .running }) == nil
    }

    /// Returns the running item that currently holds the lock on the given bundle, if any.
    public func activeLockHolder(for bundleURL: URL?) -> Item? {
        guard let bundleURL else { return nil }
        let key = bundleURL.standardizedFileURL.path
        guard let lockHolder = bundleLocks[key] else { return nil }
        return items.first(where: { $0.id == lockHolder && $0.state == .running })
    }

    private func lockBundle(for id: UUID, url: URL?) {
        guard let url else { return }
        let key = url.standardizedFileURL.path
        bundleLocks[key] = id
    }

    private func unlockBundle(for id: UUID) {
        bundleLocks = bundleLocks.filter { $0.value != id }
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

    /// Builds a properly shell-quoted `lungfish` CLI command string.
    ///
    /// Arguments containing spaces, quotes, or shell metacharacters are
    /// wrapped in single quotes with internal single quotes escaped.
    ///
    /// - Parameters:
    ///   - subcommand: The lungfish subcommand (e.g. `"fetch"`, `"classify"`).
    ///   - args: Positional and flag arguments.
    /// - Returns: A copy-pasteable shell command string.
    public nonisolated static func buildCLICommand(subcommand: String, args: [String]) -> String {
        let allParts = ["lungfish", subcommand] + args
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
        cliCommand: String? = nil,
        onCancel: (@Sendable () -> Void)? = nil
    ) -> UUID {
        let id = UUID()
        items.insert(
            Item(
                id: id,
                title: title,
                detail: detail,
                progress: 0,
                state: .running,
                operationType: operationType,
                targetBundleURL: targetBundleURL,
                onCancel: onCancel,
                cliCommand: cliCommand
            ),
            at: 0
        )
        lockBundle(for: id, url: targetBundleURL)
        trimCompletedItemsIfNeeded()
        postStateChangedNotification(id: id, state: .running)
        return id
    }

    /// Sets the cancellation callback for an existing operation.
    /// Useful when the operation must be registered before the cancellable task handle exists.
    public func setCancelCallback(for id: UUID, callback: @escaping @Sendable () -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].onCancel = callback
    }

    public func update(id: UUID, progress: Double, detail: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].progress = max(0, min(1, progress))
        items[index].detail = detail
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
    }

    public func complete(id: UUID, detail: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .completed
        items[index].progress = 1
        items[index].detail = detail
        items[index].finishedAt = Date()
        unlockBundle(for: id)
        trimCompletedItemsIfNeeded()
        postStateChangedNotification(id: id, state: .completed)
    }

    /// Completes an operation in the warning state.
    ///
    /// The warning detail is surfaced both in the item's detail text and as a
    /// warning log entry so the Operations UI presents "Completed with Warnings".
    public func completeWithWarning(id: UUID, detail: String) {
        log(id: id, level: .warning, message: detail)
        complete(id: id, detail: detail)
    }

    /// Completes an operation and delivers bundle URLs to the app for import.
    ///
    /// This is the primary mechanism for getting built bundles from background
    /// tasks to the AppDelegate for import into the sidebar. It avoids
    /// fragile callback chains through sheet controllers that get deallocated.
    public func complete(id: UUID, detail: String, bundleURLs: [URL]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .completed
        items[index].progress = 1
        items[index].detail = detail
        items[index].bundleURLs = bundleURLs
        items[index].finishedAt = Date()
        unlockBundle(for: id)
        trimCompletedItemsIfNeeded()

        if !bundleURLs.isEmpty {
            onBundleReady?(bundleURLs)
        }
        postStateChangedNotification(id: id, state: .completed)
    }

    /// Completes an operation in the warning state and delivers bundle URLs.
    public func completeWithWarning(id: UUID, detail: String, bundleURLs: [URL]) {
        log(id: id, level: .warning, message: detail)
        complete(id: id, detail: detail, bundleURLs: bundleURLs)
    }

    /// Marks an operation as failed.
    ///
    /// - Parameters:
    ///   - id: The operation that failed.
    ///   - detail: Status detail text (shown in the detail row).
    ///   - errorMessage: Optional user-facing error summary (shown prominently in red).
    ///   - errorDetail: Optional extended diagnostic text (stderr, stack trace, etc.).
    public func fail(id: UUID, detail: String, errorMessage: String? = nil, errorDetail: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .failed
        items[index].detail = detail
        items[index].errorMessage = errorMessage
        items[index].errorDetail = errorDetail
        items[index].finishedAt = Date()
        unlockBundle(for: id)
        trimCompletedItemsIfNeeded()
        postStateChangedNotification(id: id, state: .failed)
    }

    /// Cancels a running operation by invoking its cancel callback and marking it failed.
    public func cancel(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .running else { return }
        items[index].onCancel?()
        fail(id: id, detail: "Cancelled by user")
    }

    /// Cancels all running operations.
    public func cancelAll() {
        let runningIDs = items.filter { $0.state == .running }.map(\.id)
        for id in runningIDs {
            cancel(id: id)
        }
    }

    public func clearCompleted() {
        items.removeAll { $0.state != .running }
    }

    /// Removes a single completed or failed item by ID.
    ///
    /// Running operations cannot be cleared — cancel them first.
    ///
    /// - Parameter id: The item to remove.
    public func clearItem(id: UUID) {
        items.removeAll { $0.id == id && $0.state != .running }
    }

    private func trimCompletedItemsIfNeeded() {
        let keepLimit = 20
        let running = items.filter { $0.state == .running }
        let finished = items
            .filter { $0.state != .running }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }

        items = running + Array(finished.prefix(max(0, keepLimit - running.count)))
    }
}

/// Backwards-compatible typealias.
public typealias DownloadCenter = OperationCenter

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
