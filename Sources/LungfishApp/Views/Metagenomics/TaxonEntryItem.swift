// TaxonEntryItem.swift - Wraps a TaxonTarget entry for NSOutlineView child items
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishIO
import os.log

/// Wraps a `TaxonTarget` entry within a collection for NSOutlineView child items.
final class TaxonEntryItem: NSObject {
    let target: TaxonTarget
    weak var parent: CollectionItem?

    /// Number of reads detected for this taxon in the current classification result.
    var detectedReads: Int = 0

    init(target: TaxonTarget, parent: CollectionItem) {
        self.target = target
        self.parent = parent
    }
}
