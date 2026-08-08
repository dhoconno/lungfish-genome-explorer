// SequenceExportSelection.swift - Sidebar selection partitioning for File > Export > Sequences
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Task E2 (2026-08-08 repo review fix campaign, finding AS1): exportSequences()
// used to silently filter the sidebar multi-selection down to
// `.referenceBundle`/`.sequence` items before exporting, with no indication
// to the user that a mixed selection (e.g. a reference bundle plus a FASTQ
// bundle or classification result) had non-exportable items dropped. This
// type makes that partition an explicit, testable value so the caller can
// report exactly what was skipped instead of quietly narrowing the scope.

import Foundation

/// The result of splitting a sidebar selection into items File > Export >
/// Sequences can actually act on versus items it must skip.
struct SequenceExportSelection {
    /// Items whose type is exportable as sequences (.referenceBundle,
    /// .sequence).
    let exportable: [SidebarItem]
    /// Items from the original selection that are not exportable as
    /// sequences and will be excluded from the export.
    let skipped: [SidebarItem]

    /// Whether the export can proceed with `exportable` (non-empty).
    var hasExportableItems: Bool { !exportable.isEmpty }

    /// Human-readable names of the skipped items, for an alert or log line.
    var skippedDescriptions: [String] { skipped.map(\.title) }

    static func partition(_ items: [SidebarItem]) -> SequenceExportSelection {
        var exportable: [SidebarItem] = []
        var skipped: [SidebarItem] = []
        for item in items {
            if Self.isExportableAsSequence(item.type) {
                exportable.append(item)
            } else {
                skipped.append(item)
            }
        }
        return SequenceExportSelection(exportable: exportable, skipped: skipped)
    }

    /// `.referenceBundle` (via `SidebarItemType.bundleCapabilities.canExportSequences`
    /// — the same single source of truth the sidebar context menu consults)
    /// carries a sequence the export pipeline knows how to read; plain
    /// `.sequence` files do too. Every other sidebar item type (FASTQ
    /// bundles, MHC reference bundles, MSA/tree/primer-scheme/genotype/12S
    /// bundles, classification results, folders, etc.) is not exportable
    /// here. See `SidebarItem.bundleCapabilities` for why `.mhcReferenceBundle`
    /// is excluded despite being reference-shaped.
    static func isExportableAsSequence(_ type: SidebarItemType) -> Bool {
        type == .sequence || type.bundleCapabilities.canExportSequences
    }
}
