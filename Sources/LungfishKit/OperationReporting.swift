// OperationReporting.swift - The calls an operation makes on the Operations panel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The calls an operation makes to register itself in the Operations panel
/// and to report on its run (finding R4 in the 2026-10-02 architecture review).
///
/// `OperationCenter` is the production conformer. A test passes
/// `RecordingOperationReporter` from LungfishKitTestSupport, or a fresh
/// `OperationCenter()`, so a launch site can be checked without touching
/// `OperationCenter.shared`. docs/contracts/ADDING-AN-OPERATION.md shows the
/// launch-site pattern and its tests.
///
/// Each requirement repeats the signature of the `OperationCenter` method
/// with the same name, so `OperationCenter` conforms with no new code and no
/// change in behaviour. Bundle locks stay inside `OperationCenter`. A
/// conformer only answers whether `begin` started the operation or refused it.
///
/// A requirement cannot carry default arguments, so the extension below adds
/// the shorter forms operation code calls. Its `begin` has no default for
/// `operationType` or `cliCommand`, so a call through this protocol always
/// names both.
@MainActor
public protocol OperationReporting: AnyObject, Sendable {
    /// Registers an operation. Returns `.refused` when a requested bundle
    /// lock is held, and the caller then launches nothing.
    func begin(
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
    ) -> OperationStartResult

    /// Sets the callback that stops the worker when the user cancels.
    func setCancelCallback(for id: UUID, callback: @escaping @Sendable () -> Void)

    /// Replaces the recorded command once the exact invocation is known.
    func setCommand(id: UUID, command: String)

    @discardableResult
    func update(id: UUID, progress: Double, detail: String) -> Bool

    @discardableResult
    func updateWithLog(
        id: UUID,
        progress: Double,
        detail: String,
        level: OperationLogLevel,
        deduplicateAdjacent: Bool
    ) -> Bool

    @discardableResult
    func updateProgress(id: UUID, evidence: OperationProgressEvidence?, detail: String) -> Bool

    func updateBytes(id: UUID, bytesDownloaded: Int64, totalBytes: Int64?)

    func log(id: UUID, level: OperationLogLevel, message: String)

    /// Ties an incomplete analysis directory to the operation.
    func trackAnalysisOutput(_ url: URL, for id: UUID)

    @discardableResult
    func complete(id: UUID, detail: String, finishedAt: Date) -> Bool

    @discardableResult
    func complete(id: UUID, detail: String, bundleURLs: [URL], finishedAt: Date) -> Bool

    @discardableResult
    func complete(id: UUID, detail: String, outputURLs: [URL], finishedAt: Date) -> Bool

    @discardableResult
    func completeWithWarning(id: UUID, detail: String) -> Bool

    @discardableResult
    func completeWithWarning(id: UUID, detail: String, bundleURLs: [URL]) -> Bool

    @discardableResult
    func completeWithWarning(id: UUID, detail: String, outputURLs: [URL]) -> Bool

    @discardableResult
    func fail(
        id: UUID,
        detail: String,
        errorMessage: String?,
        errorDetail: String?,
        finishedAt: Date
    ) -> Bool

    /// Records that the worker stopped after a cancel request.
    @discardableResult
    func acknowledgeCancellation(id: UUID, detail: String, finishedAt: Date) -> Bool

    /// Asks the operation to stop by calling its cancel callback.
    func cancel(id: UUID)
}

// MARK: - Shorter forms

public extension OperationReporting {
    /// Registers an operation. `operationType` and `cliCommand` have no
    /// default, so the caller always names both.
    func begin(
        title: String,
        detail: String,
        operationType: OperationType,
        targetBundleURL: URL? = nil,
        additionalLockedBundleURLs: [URL] = [],
        cliCommand: String?,
        workflowRunID: UUID? = nil,
        routeContext: OperationRouteContext? = nil,
        onCancel: (@Sendable () -> Void)? = nil
    ) -> OperationStartResult {
        begin(
            title: title,
            detail: detail,
            operationType: operationType,
            targetBundleURL: targetBundleURL,
            additionalLockedBundleURLs: additionalLockedBundleURLs,
            startedAt: Date(),
            cliCommand: cliCommand,
            workflowRunID: workflowRunID,
            routeContext: routeContext,
            onCancel: onCancel
        )
    }

    @discardableResult
    func updateWithLog(
        id: UUID,
        progress: Double,
        detail: String,
        level: OperationLogLevel = .info
    ) -> Bool {
        updateWithLog(id: id, progress: progress, detail: detail, level: level, deduplicateAdjacent: true)
    }

    @discardableResult
    func complete(id: UUID, detail: String) -> Bool {
        complete(id: id, detail: detail, finishedAt: Date())
    }

    @discardableResult
    func complete(id: UUID, detail: String, bundleURLs: [URL]) -> Bool {
        complete(id: id, detail: detail, bundleURLs: bundleURLs, finishedAt: Date())
    }

    @discardableResult
    func complete(id: UUID, detail: String, outputURLs: [URL]) -> Bool {
        complete(id: id, detail: detail, outputURLs: outputURLs, finishedAt: Date())
    }

    @discardableResult
    func fail(
        id: UUID,
        detail: String,
        errorMessage: String? = nil,
        errorDetail: String? = nil
    ) -> Bool {
        fail(id: id, detail: detail, errorMessage: errorMessage, errorDetail: errorDetail, finishedAt: Date())
    }

    @discardableResult
    func acknowledgeCancellation(id: UUID, detail: String = "Cancelled by user") -> Bool {
        acknowledgeCancellation(id: id, detail: detail, finishedAt: Date())
    }
}

// MARK: - Refusals outside OperationCenter

extension OperationStartRefusal {
    /// Builds a refusal outside `OperationCenter`, for a conformer such as a
    /// test double that simulates a held bundle lock. The memberwise
    /// initializer is internal to LungfishKit, so other modules use this one.
    public init(id: UUID, blockedBy blockingOperationTitle: String, message: String) {
        self.init(id: id, blockingOperationTitle: blockingOperationTitle, message: message)
    }
}

/// Thrown by an async entry point that must return a value when its `begin`
/// was refused. Nothing was launched, and the Operations panel already shows
/// the refused row.
public struct OperationRefusedError: LocalizedError, Sendable {
    public let refusal: OperationStartRefusal

    public init(_ refusal: OperationStartRefusal) {
        self.refusal = refusal
    }

    public var errorDescription: String? { refusal.message }
}

extension OperationStartResult {
    /// The started operation's ID, for an async entry point that must return
    /// a value. Throws `OperationRefusedError` when `begin` was refused.
    public func requireStarted() throws -> UUID {
        switch self {
        case .started(let id):
            return id
        case .refused(let refusal):
            throw OperationRefusedError(refusal)
        }
    }
}
