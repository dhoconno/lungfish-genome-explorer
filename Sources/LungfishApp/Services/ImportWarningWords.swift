// ImportWarningWords.swift - The words an import row ends on when its run logged a warning
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// The detail line of an import row that finished with warnings (row IMPORT-WARN-SUBTITLE, walk W-29).
///
/// The row reads Completed with Warnings because its log holds a line at warning level, and only the Log said what the
/// warning was, for example that 1,500 pairs did not merge. The detail line, the subtitle under the title, now names the
/// first cause as the Log words it and counts the rest. The row has one line for it, which cuts at the edge, so the panel
/// keeps the whole text in the tooltip and the Log keeps every line.
enum ImportWarningWords {
    /// The distinct warning lines of `item`'s log, in the order they were logged.
    static func causes(in item: OperationCenter.Item) -> [String] {
        var seen = Set<String>()
        return item.logEntries.compactMap { entry -> String? in
            guard entry.level == .warning else { return nil }
            let cause = oneLine(entry.message)
            return cause.isEmpty || !seen.insert(cause).inserted ? nil : cause
        }
    }

    /// `base` alone when the run logged no warning. Otherwise `base`, how many warnings the Log holds, the first cause as
    /// a sentence and, when there are more, where the others are.
    static func detail(_ base: String, causes: [String]) -> String {
        guard let first = causes.first else { return base }
        let count = causes.count
        var words = "\(base) with \(count == 1 ? "a warning" : "\(count) warnings"). \(sentence(first))"
        if count > 1 {
            words += count == 2 ? " The Log names the other warning." : " The Log names the other \(count - 1) warnings."
        }
        return words
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// `cause` with a full stop added when it ends in none of `.`, `!` and `?`.
    private static func sentence(_ cause: String) -> String {
        guard let last = cause.last, !".!?".contains(last) else { return cause }
        return cause + "."
    }
}
