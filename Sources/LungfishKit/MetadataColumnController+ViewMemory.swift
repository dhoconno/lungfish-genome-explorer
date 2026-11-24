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
    /// The defaults a controller made with none of its own reads its layouts from and, when it does not adopt view
    /// memory, writes them to. The app's is `.standard`. A test that shows result views points it at a suite of its own
    /// before the views are made and back when it ends, so no table writes the runner's defaults (QA 6). Only a test
    /// sets it, through `@testable import LungfishKit`.
    public internal(set) static var defaultUserDefaults: UserDefaults = .standard

    /// A controller for a table whose owner keeps its view in view memory (VS A10, QA 6). It makes the declaration of
    /// `adoptViewMemory()` before any key is set, so the table writes no layout to `userDefaults` from its first key on.
    /// A table that holds one in a stored property makes the declaration there, with no other change.
    public static func adoptingViewMemory(
        contentTypographyOwnership: ContentTypographyOwnership = .standalone,
        userDefaults: UserDefaults = MetadataColumnController.defaultUserDefaults
    ) -> MetadataColumnController {
        let controller = MetadataColumnController(
            contentTypographyOwnership: contentTypographyOwnership, userDefaults: userDefaults
        )
        controller.adoptViewMemory()
        return controller
    }

    /// True once view memory owns this controller's layouts, so nothing is written to `userDefaults`.
    public var isViewMemoryAdopted: Bool { viewMemoryLayouts != nil }

    /// Declares that this controller's owner keeps its view in view memory. Make it before the first `persistenceKey`:
    /// setting a key restores and refreshes the columns, and a refresh before the declaration writes the layout to
    /// `userDefaults` as a table that does not adopt always has. From this call on a layout stays in memory, by key,
    /// until the owner's capture takes it, and the old `UserDefaults` value of a key is read only as its starting value
    /// and never written back. A second call changes nothing.
    public func adoptViewMemory() {
        guard viewMemoryLayouts == nil else { return }
        viewMemoryLayouts = [:]
        if let key = persistenceKey, let current = persistedLayout {
            viewMemoryLayouts?[key] = current
        }
    }

    /// The layout of the current key as view memory should hold it, or nil while the controller
    /// holds none (no key, or nothing laid out yet). The capture is cheap and reads no store.
    public func captureViewMemory() -> MetadataColumnLayoutMemory? {
        persistedLayout?.memory
    }

    /// Applies the item's stored layout to the current key.
    ///
    /// The order is: `adoptViewMemory()` (or `adoptingViewMemory(...)`) when the controller is made, then
    /// `persistenceKey`, then this call in the owner's restore. The declaration comes first so that no layout reaches
    /// `userDefaults`, and the key comes before this call so the layout is remembered for that key while the table is
    /// on another result. A call on a controller that has not declared makes the declaration then. A key that view
    /// memory holds no layout for starts from the old `UserDefaults` value when the key is set, and that value is never
    /// written back. A non-nil `memory` wins over the old value and is applied to the table now. A nil `memory` changes
    /// no column.
    public func applyViewMemory(_ memory: MetadataColumnLayoutMemory?) {
        adoptViewMemory()
        guard let memory else { return }
        let layout = PersistedLayout(memory)
        persistedLayout = layout
        if let key = persistenceKey {
            viewMemoryLayouts?[key] = layout
        }
        applyPersistedLayout()
    }

    /// Applies a kept layout only when it differs from the table's, so a restore of an equal layout refreshes no
    /// column and starts no re-filter in the owner. A nil layout changes nothing.
    public func applyKeptLayout(_ layout: MetadataColumnLayoutMemory?) {
        guard let layout, layout != captureViewMemory() else { return }
        applyViewMemory(layout)
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

    /// Keeps a layout. After `adoptViewMemory()` it stays in memory, and on a controller that has not
    /// declared it is written to `userDefaults` as it always was.
    func storeLayout(_ layout: PersistedLayout, forKey key: String) {
        if viewMemoryLayouts != nil {
            viewMemoryLayouts?[key] = layout
        } else if let data = try? JSONEncoder().encode(layout) {
            userDefaults.set(data, forKey: persistenceDefaultsKey(for: key))
        }
    }
}
