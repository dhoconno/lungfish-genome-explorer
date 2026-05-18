// SidebarImportRequestTracker.swift - Import request completion accounting
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

struct SidebarImportRequestTrackerUpdate {
    let pendingCount: Int
    let succeeded: Int
    let failed: Int
    let isFinished: Bool
}

/// Main-thread import tracking state used by File > Import.
///
/// This object is captured by notification handlers that are `@Sendable`.
/// The handler immediately hops to `MainActor` before mutating state.
final class SidebarImportRequestTracker: @unchecked Sendable {
    let requestID: String
    var pendingURLs: Set<URL>
    var succeeded: Int = 0
    var failed: Int = 0
    var observerToken: NSObjectProtocol?

    init(requestID: String, trackedURLs: [URL]) {
        self.requestID = requestID
        self.pendingURLs = Set(trackedURLs.map(\.standardizedFileURL))
    }

    func registerCompletion(
        requestID completionRequestID: String?,
        completedURL: URL?,
        wasSuccessful: Bool
    ) -> SidebarImportRequestTrackerUpdate? {
        guard let completionRequestID,
              completionRequestID == requestID,
              let completedURL = completedURL?.standardizedFileURL,
              pendingURLs.contains(completedURL) else {
            return nil
        }

        pendingURLs.remove(completedURL)
        if wasSuccessful {
            succeeded += 1
        } else {
            failed += 1
        }

        return SidebarImportRequestTrackerUpdate(
            pendingCount: pendingURLs.count,
            succeeded: succeeded,
            failed: failed,
            isFinished: pendingURLs.isEmpty
        )
    }
}
