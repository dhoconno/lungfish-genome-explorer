// ImportResultFolderLedger.swift - The result folders this process's imports began, so a cancel removes only those
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import Synchronization

/// The folders that the imports of this process began (Phase 2.12, finding 2 of the review of lane 12.04, applied
/// by lane 12.05 to the NAO-MGS and NVD imports).
///
/// An import service marks the folder it begins as in progress through ``markInProgress(_:detail:)``, and the
/// command that runs the service asks ``createdSince(_:)`` which folders its own run began. A cancel then removes
/// those folders and no other. A folder that carries the kind's prefix can belong to another import that runs at
/// the same time, or to one that finished, because the Import Center starts one command for each file it imports.
package enum ImportResultFolderLedger {
    private static let created = Mutex<[URL]>([])

    /// How many folders this process began so far. A run reads it before it starts.
    package static var count: Int {
        created.withLock { $0.count }
    }

    /// Marks `directory` as in progress for the sidebar, as `OperationMarker` does, and notes that this process began it.
    package static func markInProgress(_ directory: URL, detail: String) {
        OperationMarker.markInProgress(directory, detail: detail)
        created.withLock { $0.append(directory) }
    }

    /// The folders this process began after the first `count`.
    package static func createdSince(_ count: Int) -> [URL] {
        created.withLock { Array($0.dropFirst(count)) }
    }
}
