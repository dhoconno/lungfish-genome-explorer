// ProvenanceInspectableItem.swift - The file or bundle whose provenance the Inspector shows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// The file or bundle whose provenance the Inspector shows. Two items are equal when they name the
/// same file by standardized path, with the same sidebar type, content mode and display name, so
/// the two to four loads one open makes of an item share one lookup.
struct ProvenanceInspectableItem: Equatable {
    var url: URL?
    var sidebarType: SidebarItemType?
    var contentMode: ViewportContentMode
    var displayName: String?

    init(
        url: URL?,
        sidebarType: SidebarItemType?,
        contentMode: ViewportContentMode,
        displayName: String?
    ) {
        self.url = url
        self.sidebarType = sidebarType
        self.contentMode = contentMode
        self.displayName = displayName
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url?.standardizedFileURL.path == rhs.url?.standardizedFileURL.path
            && lhs.sidebarType == rhs.sidebarType && lhs.contentMode == rhs.contentMode
            && lhs.displayName == rhs.displayName
    }
}
