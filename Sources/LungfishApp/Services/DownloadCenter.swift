// OperationCenter.swift - Centralized operation tracking with bundle locking
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SwiftUI

/// The type of long-running operation being tracked.
public enum OperationType: String, Sendable {
    case download = "Download"
    case bamImport = "BAM Import"
    case vcfImport = "VCF Import"
    case bundleBuild = "Bundle Build"
    case export = "Export"
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
            onCancel: (@Sendable () -> Void)? = nil
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

    // MARK: - Lifecycle

    public func start(
        title: String,
        detail: String,
        operationType: OperationType = .download,
        targetBundleURL: URL? = nil,
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
                onCancel: onCancel
            ),
            at: 0
        )
        lockBundle(for: id, url: targetBundleURL)
        trimCompletedItemsIfNeeded()
        postStateChangedNotification(id: id, state: .running)
        return id
    }

    public func update(id: UUID, progress: Double, detail: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].progress = max(0, min(1, progress))
        items[index].detail = detail
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

    public func fail(id: UUID, detail: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .failed
        items[index].detail = detail
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
