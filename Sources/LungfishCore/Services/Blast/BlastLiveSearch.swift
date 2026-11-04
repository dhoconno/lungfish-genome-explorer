// BlastLiveSearch.swift - A search on a row that has no result to show, and where a search's news goes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A search a row holds with no record to show, as its result folder has it (UX-BLAST-WORDS Q8 item 2).
package struct BlastLiveSearch: Sendable, Equatable {
    package var file: BlastSearchFile
    package var folder: URL

    package init(file: BlastSearchFile, folder: URL) {
        self.file = file
        self.folder = folder
    }

    /// Reads the search in `folder`. A folder with no readable search file gives nil.
    package static func read(folder: URL) -> BlastLiveSearch? {
        (try? BlastSearchStore(folder: folder).load()).map { BlastLiveSearch(file: $0, folder: folder) }
    }
}

/// The news every pane listens for: a search changed on disk, so a pane that shows a row asks the disk again.
///
/// This is how a late result reaches its own row. A pane looks up the row it is on, so no pane can show a verdict
/// under another row's name, and a viewer opened after the search began hears it as well as the one that began it
/// (BLAST-RUN-REPORTS-TO-OLD-VIEWER).
public enum BlastSearchNews {
    public static let changed = Notification.Name("BlastSearchNews.changed")

    /// Says that a search changed. The notification goes out on the main actor, where every pane listens.
    @MainActor public static func post() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
