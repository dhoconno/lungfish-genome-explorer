// NativeProjectCopyImportError.swift - A refusal of the native copy that a person can read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A refusal of `NativeProjectCopyImportService` in words a person can read. The words name the link inside the item and say
/// what to try, and show no folder of the copy's hidden stage. `CrossProjectItemCopier` turns it into its own refusal, which
/// also names the item and exits like the other refusals of a copy.
package enum NativeProjectCopyImportError: Error, LocalizedError, Equatable {
    /// A link inside the item points to a folder. The copy follows a link to a file and cannot follow a link to a folder.
    /// `link` is the path of the link inside the item.
    case folderLink(link: String)

    package var errorDescription: String? {
        switch self {
        case .folderLink(let link):
            return [
                "\(link) is a link to a folder, and Lungfish copies a link to a file but not a link to a folder.",
                "Replace the link with a copy of the folder it points to, or remove the link, then copy it again."
            ].joined(separator: " ")
        }
    }
}
