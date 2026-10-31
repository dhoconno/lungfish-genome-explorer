// CollectionItem.swift - Wraps a TaxaCollection for use as an NSOutlineView parent item
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishIO
import os.log

// MARK: - OutlineItem Wrappers

/// Wraps a `TaxaCollection` for use as an NSOutlineView parent item.
///
/// NSOutlineView uses object identity to track items. Since `TaxaCollection`
/// is a value type (struct), we wrap it in a reference type so the outline
/// view can identify it across reloads.
final class CollectionItem: NSObject {
    let collection: TaxaCollection

    /// Whether each taxon entry is enabled for extraction. Keyed by tax ID.
    var enabledTaxa: [Int: Bool]

    init(collection: TaxaCollection) {
        self.collection = collection
        self.enabledTaxa = Dictionary(uniqueKeysWithValues: collection.taxa.map { ($0.taxId, true) })
    }

    /// Returns the enabled `TaxonTarget` entries.
    var enabledTargets: [TaxonTarget] {
        collection.taxa.filter { enabledTaxa[$0.taxId] ?? true }
    }
}
