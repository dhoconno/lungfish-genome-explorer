// MetadataColumnController+ViewMemory.swift - Metadata column layouts held by view memory (VS A10)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// The visible metadata columns, the column order and the metadata column widths of one table.
///
/// A view's state struct embeds one of these for each table that shows metadata columns, so the
/// layout travels in the item's record and not in `UserDefaults`.
public struct MetadataColumnLayoutMemory: Codable, Sendable, Equatable {
    public var visibleMetadata: [String]
    public var columnOrder: [String]
    public var metadataWidths: [String: Double]

    public init(visibleMetadata: [String], columnOrder: [String], metadataWidths: [String: Double]) {
        self.visibleMetadata = visibleMetadata
        self.columnOrder = columnOrder
        self.metadataWidths = metadataWidths
    }
}

extension MetadataColumnController.PersistedLayout {
    init(_ memory: MetadataColumnLayoutMemory) {
        self.init(
            version: 1,
            visibleMetadata: memory.visibleMetadata,
            columnOrder: memory.columnOrder,
            metadataWidths: memory.metadataWidths.mapValues { CGFloat($0) }
        )
    }

    var memory: MetadataColumnLayoutMemory {
        MetadataColumnLayoutMemory(
            visibleMetadata: visibleMetadata,
            columnOrder: columnOrder,
            metadataWidths: metadataWidths.mapValues { Double($0) }
        )
    }
}

extension MetadataColumnController {
    /// True once view memory owns this controller's layouts, so nothing is written to `userDefaults`.
    public var isViewMemoryAdopted: Bool { viewMemoryLayouts != nil }

    /// The layout of the current key as view memory should hold it, or nil while the controller
    /// holds none (no key, or nothing laid out yet). The capture is cheap and reads no store.
    public func captureViewMemory() -> MetadataColumnLayoutMemory? {
        persistedLayout?.memory
    }

    /// Hands this controller's layouts to view memory.
    ///
    /// From the first call on, no layout is written to `userDefaults`. A key that view memory
    /// holds no layout for still starts from the old `UserDefaults` value when the key is set, and
    /// that value is never written back. A non-nil `memory` is the item's stored layout. It wins
    /// over the old value and is applied to the table now as the layout of the current key. Set
    /// `persistenceKey` first, so the layout is remembered for that key while the table is on
    /// another result.
    public func applyViewMemory(_ memory: MetadataColumnLayoutMemory?) {
        if viewMemoryLayouts == nil {
            viewMemoryLayouts = [:]
            if let key = persistenceKey, let current = persistedLayout {
                viewMemoryLayouts?[key] = current
            }
        }
        guard let memory else { return }
        let layout = PersistedLayout(memory)
        persistedLayout = layout
        if let key = persistenceKey {
            viewMemoryLayouts?[key] = layout
        }
        applyPersistedLayout()
    }

    /// The layout a key starts from. View memory's own layout for the key wins. Otherwise the old
    /// `UserDefaults` value is the starting value, in either mode.
    func loadLayout(forKey key: String) -> PersistedLayout? {
        if let remembered = viewMemoryLayouts?[key] {
            return remembered
        }
        guard let data = userDefaults.data(forKey: persistenceDefaultsKey(for: key)),
              let decoded = try? JSONDecoder().decode(PersistedLayout.self, from: data),
              decoded.version == 1
        else {
            return nil
        }
        return decoded
    }

    /// Keeps a layout. After `applyViewMemory(_:)` it stays in memory, and before it the layout is
    /// written to `userDefaults` as it always was.
    func storeLayout(_ layout: PersistedLayout, forKey key: String) {
        if viewMemoryLayouts != nil {
            viewMemoryLayouts?[key] = layout
        } else if let data = try? JSONEncoder().encode(layout) {
            userDefaults.set(data, forKey: persistenceDefaultsKey(for: key))
        }
    }
}
