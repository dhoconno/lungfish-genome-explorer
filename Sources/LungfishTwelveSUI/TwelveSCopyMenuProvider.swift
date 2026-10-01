// TwelveSCopyMenuProvider.swift — selection-aware copy context menu for the 12S tables
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// Pure formatting of clipboard payloads for the 12S copy menu (unit-tested).
///
/// The enum is `public` so the App's Inspector Detail section can reuse
/// ``referenceFASTA(_:)``; the remaining helpers stay internal to the leaf.
public enum TwelveSCopyFormatting {
    static func names(_ rows: [TwelveSTargetSampleRow]) -> String {
        rows.map(\.scientificName).joined(separator: "\n")
    }
    static func unresolvedNames(_ rows: [TwelveSUnresolvedSequence]) -> String {
        rows.map(\.sequenceID).joined(separator: "\n")
    }
    static func sequence(_ row: TwelveSUnresolvedSequence) -> String { row.sequence }
    static func fasta(_ rows: [TwelveSUnresolvedSequence]) -> String {
        rows.map { ">\($0.sequenceID)\n\($0.sequence)" }.joined(separator: "\n")
    }

    /// FASTA for a species' matched reference sequences (Detail tab "Copy All").
    public static func referenceFASTA(_ sequences: [TwelveSReferenceSequence]) -> String {
        sequences.map { ">\($0.targetID)\n\($0.sequence)" }.joined(separator: "\n")
    }

    static let targetHeader = [
        "Sample", "Scientific Name", "Common Names", "Group", "Tax ID",
        "Exact Reads", "% of Sample", "Refs", "Alternates",
    ]
    static func targetRowsTSV(_ rows: [TwelveSTargetSampleRow]) -> String {
        var out = [targetHeader.joined(separator: "\t")]
        for r in rows {
            out.append([
                r.sampleDisplayName,
                r.scientificName,
                r.commonNamesText,
                r.displayTaxonGroups.joined(separator: "; "),
                r.taxids.joined(separator: "; "),
                String(r.exactReads),
                String(format: "%.1f%%", r.samplePercent),
                String(r.referenceTargetCount),
                String(TwelveSTargetTableView.alternateTexts(for: r).count),
            ].joined(separator: "\t"))
        }
        return out.joined(separator: "\n")
    }

    static let unresolvedHeader = ["Sequence", "Reads", "Samples", "Chimera", "Bases"]
    static func unresolvedRowsTSV(_ rows: [TwelveSUnresolvedSequence]) -> String {
        var out = [unresolvedHeader.joined(separator: "\t")]
        for r in rows {
            out.append([
                r.sequenceID,
                String(r.readCount),
                String(r.sampleCounts.filter { $0.value > 0 }.count),
                r.chimeraStatus.displayName,
                r.sequence,
            ].joined(separator: "\t"))
        }
        return out.joined(separator: "\n")
    }
}

/// Wraps a closure so it can be the `target`/`action` of an `NSMenuItem`,
/// keeping the closure alive for the menu's lifetime.
@MainActor
private final class TwelveSCopyActionTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

/// Builds the selection-aware copy menu and writes payloads to a pasteboard.
///
/// The menu, Selection > Table Row and each row's accessibility actions all
/// read ``targetEntries(rows:pasteboard:onOpenURL:)`` and
/// ``unresolvedEntries(rows:pasteboard:)``, so they offer the same commands
/// under the same titles.
@MainActor
enum TwelveSCopyMenuProvider {
    enum Mode { case targets, unresolved }

    /// One command of the copy menu: its title, the shared row command the
    /// menu bar reaches it through (nil for the species lookups), and what it
    /// does.
    struct Entry {
        let title: String
        let command: ResultRowCommand?
        /// True for the lookups, which the context menu sets apart with a
        /// separator.
        let isLookup: Bool
        let perform: @MainActor () -> Void
    }

    /// Titles for the items shown given selection state — drives both the live
    /// menu and the unit tests.
    static func itemTitles(mode: Mode, selectedCount: Int, hasSequence: Bool) -> [String] {
        var titles: [String] = []
        titles.append(selectedCount > 1 ? "Copy Names" : "Copy Name")
        if mode == .unresolved {
            if selectedCount > 1 {
                titles.append("Copy Sequences")
            } else if hasSequence {
                titles.append("Copy Sequence")
            }
        }
        if selectedCount > 1 {
            titles.append("Copy Rows")
        }
        return titles
    }

    /// The commands for the current target-mode selection, each writing to
    /// `pasteboard` when performed. For a single-row selection, also
    /// "Learn More About <species>" (NCBI) and "View Photo of <species>"
    /// (Wikipedia), which invoke `onOpenURL`.
    static func targetEntries(
        rows: [TwelveSTargetSampleRow],
        pasteboard: PasteboardWriting,
        onOpenURL: @escaping (URL) -> Void
    ) -> [Entry] {
        guard !rows.isEmpty else { return [] }
        var entries: [Entry] = []
        for title in itemTitles(mode: .targets, selectedCount: rows.count, hasSequence: false) {
            switch title {
            case "Copy Name", "Copy Names":
                entries.append(Entry(title: title, command: .copyName, isLookup: false) {
                    pasteboard.setString(TwelveSCopyFormatting.names(rows))
                })
            case "Copy Rows":
                entries.append(Entry(title: title, command: .copyAsTSV, isLookup: false) {
                    pasteboard.setString(TwelveSCopyFormatting.targetRowsTSV(rows))
                })
            default:
                break
            }
        }
        if rows.count == 1, let row = rows.first {
            let name = row.scientificName
            let taxid = row.taxids.first
            entries.append(Entry(title: "Learn More About \(name)", command: nil, isLookup: true) {
                onOpenURL(TwelveSSpeciesLinks.ncbiTaxonomyURL(taxid: taxid, scientificName: name))
            })
            entries.append(Entry(title: "View Photo of \(name)", command: nil, isLookup: true) {
                onOpenURL(TwelveSSpeciesLinks.wikipediaURL(scientificName: name))
            })
        }
        return entries
    }

    /// The commands for the current unresolved-mode selection.
    static func unresolvedEntries(
        rows: [TwelveSUnresolvedSequence],
        pasteboard: PasteboardWriting
    ) -> [Entry] {
        guard !rows.isEmpty else { return [] }
        let hasSequence = rows.first.map { !$0.sequence.isEmpty } ?? false
        var entries: [Entry] = []
        for title in itemTitles(mode: .unresolved, selectedCount: rows.count, hasSequence: hasSequence) {
            switch title {
            case "Copy Name", "Copy Names":
                entries.append(Entry(title: title, command: .copyName, isLookup: false) {
                    pasteboard.setString(TwelveSCopyFormatting.unresolvedNames(rows))
                })
            case "Copy Sequence":
                if let row = rows.first {
                    entries.append(Entry(title: title, command: .copySequence, isLookup: false) {
                        pasteboard.setString(TwelveSCopyFormatting.sequence(row))
                    })
                }
            case "Copy Sequences":
                entries.append(Entry(title: title, command: .copySequence, isLookup: false) {
                    pasteboard.setString(TwelveSCopyFormatting.fasta(rows))
                })
            case "Copy Rows":
                entries.append(Entry(title: title, command: .copyAsTSV, isLookup: false) {
                    pasteboard.setString(TwelveSCopyFormatting.unresolvedRowsTSV(rows))
                })
            default:
                break
            }
        }
        return entries
    }

    /// The commands as accessibility custom actions, named after their titles.
    static func accessibilityActions(_ entries: [Entry]) -> [NSAccessibilityCustomAction] {
        entries.map { entry in
            AccessibilityCellActions.makeAction(name: entry.title) { entry.perform() }
        }
    }

    /// Populates `menu` with copy items for the current target-mode selection,
    /// each writing to `pasteboard` when chosen. For a single-row selection, also
    /// appends "Learn More About <species>" (NCBI) and "View Photo of <species>"
    /// (Wikipedia), which invoke `onOpenURL`.
    static func populateTargetMenu(
        _ menu: NSMenu,
        rows: [TwelveSTargetSampleRow],
        pasteboard: PasteboardWriting,
        onOpenURL: @escaping (URL) -> Void
    ) {
        menu.removeAllItems()
        populate(menu, with: targetEntries(rows: rows, pasteboard: pasteboard, onOpenURL: onOpenURL))
    }

    /// Populates `menu` with copy items for the current unresolved-mode selection.
    static func populateUnresolvedMenu(
        _ menu: NSMenu,
        rows: [TwelveSUnresolvedSequence],
        pasteboard: PasteboardWriting
    ) {
        menu.removeAllItems()
        populate(menu, with: unresolvedEntries(rows: rows, pasteboard: pasteboard))
    }

    private static func populate(_ menu: NSMenu, with entries: [Entry]) {
        var addedLookupSeparator = false
        for entry in entries {
            if entry.isLookup, !addedLookupSeparator {
                menu.addItem(NSMenuItem.separator())
                addedLookupSeparator = true
            }
            addItem(menu, title: entry.title, handler: entry.perform)
        }
    }

    private static func addItem(_ menu: NSMenu, title: String, handler: @escaping () -> Void) {
        let target = TwelveSCopyActionTarget(handler)
        let item = NSMenuItem(title: title, action: #selector(TwelveSCopyActionTarget.fire), keyEquivalent: "")
        item.target = target
        // Retain the target for the menu item's lifetime.
        item.representedObject = target
        menu.addItem(item)
    }
}
