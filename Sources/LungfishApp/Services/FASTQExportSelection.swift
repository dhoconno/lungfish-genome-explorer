// FASTQExportSelection.swift - Sidebar selection partitioning for File > Export > FASTQ
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Task E4 (2026-08-08 repo review fix campaign, finding AS15): exportFASTQ()
// used to silently filter the sidebar multi-selection down to
// `.fastqBundle` items with a URL via a bare `.filter`, so a mixed
// selection (e.g. FASTQ bundles alongside a reference bundle or assembly)
// exported fewer files than selected with no indication of what was
// dropped. This type makes that partition an explicit, testable value,
// mirroring SequenceExportSelection (AS1/E2).

import Foundation

/// The result of splitting a sidebar selection into items File > Export >
/// FASTQ can actually act on versus items it must skip.
struct FASTQExportSelection {
    /// Items whose type is `.fastqBundle` and have a resolvable URL.
    let exportable: [SidebarItem]
    /// Items from the original selection that are not exportable as FASTQ
    /// and will be excluded from the export.
    let skipped: [SidebarItem]

    /// Whether the export can proceed with `exportable` (non-empty).
    var hasExportableItems: Bool { !exportable.isEmpty }

    /// Human-readable names of the skipped items, for an alert or log line.
    var skippedDescriptions: [String] { skipped.map(\.title) }

    static func partition(_ items: [SidebarItem]) -> FASTQExportSelection {
        var exportable: [SidebarItem] = []
        var skipped: [SidebarItem] = []
        for item in items {
            if item.type == .fastqBundle, item.url != nil {
                exportable.append(item)
            } else {
                skipped.append(item)
            }
        }
        return FASTQExportSelection(exportable: exportable, skipped: skipped)
    }
}
