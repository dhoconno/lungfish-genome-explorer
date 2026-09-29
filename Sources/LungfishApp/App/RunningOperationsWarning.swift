// RunningOperationsWarning.swift - Text of the quit/close-with-running-operations sheets
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// Wording shared by the quit and window-close warnings (FEA-06).
///
/// Partial output of a cancelled run stays hidden from the sidebar. The next
/// time the project opens, the Operations Panel lists it as an Interrupted
/// row (size on disk, Remove…), so the text points there.
@MainActor
enum RunningOperationsWarning {
    enum Kind {
        case quit
        case closeWindow
    }

    static func messageText(kind: Kind, count: Int) -> String {
        let operations = count == 1 ? "1 Operation" : "\(count) Operations"
        switch kind {
        case .quit: return "Quit with \(operations) Running?"
        case .closeWindow: return "Close Window with \(operations) Running?"
        }
    }

    static func informativeText(kind: Kind, operations: [OperationCenter.Item]) -> String {
        let count = operations.count
        let plural = count == 1 ? "" : "s"
        let listedTitles = operations.prefix(6).map { "• \($0.title)" }.joined(separator: "\n")
        let overflowNote = count > 6 ? "\n… and \(count - 6) more" : ""
        let lead: String
        switch kind {
        case .quit:
            lead = "Quitting now will cancel the following operation\(plural)."
        case .closeWindow:
            lead = "Closing this window now will cancel the following operation\(plural) for this project."
        }
        return lead
            + " Any partial output stays out of the sidebar. The next time you open the project, "
            + "the Operations Panel lists it as Interrupted, with its size on disk and a Remove button.\n\n"
            + listedTitles + overflowNote
    }
}
