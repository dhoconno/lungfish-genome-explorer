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
    static func names(_ rows: [TwelveSScientificNameCountRow]) -> String {
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
        "Scientific Name", "Common Names", "Group", "Tax ID",
        "Exact Reads", "Refs", "Max %", "Alternates",
    ]
    static func targetRowsTSV(_ rows: [TwelveSScientificNameCountRow]) -> String {
        var out = [targetHeader.joined(separator: "\t")]
        for r in rows {
            out.append([
                r.scientificName,
                r.commonNamesText,
                r.displayTaxonGroups.joined(separator: "; "),
                r.taxids.joined(separator: "; "),
                String(r.totalExactReads),
                String(r.referenceTargetCount),
                String(format: "%.1f%%", r.maxSamplePercent),
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
@MainActor
enum TwelveSCopyMenuProvider {
    enum Mode { case targets, unresolved }

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

    /// Populates `menu` with copy items for the current target-mode selection,
    /// each writing to `pasteboard` when chosen.
    static func populateTargetMenu(
        _ menu: NSMenu,
        rows: [TwelveSScientificNameCountRow],
        pasteboard: PasteboardWriting
    ) {
        menu.removeAllItems()
        guard !rows.isEmpty else { return }
        let titles = itemTitles(mode: .targets, selectedCount: rows.count, hasSequence: false)
        for title in titles {
            switch title {
            case "Copy Name", "Copy Names":
                addItem(menu, title: title) { pasteboard.setString(TwelveSCopyFormatting.names(rows)) }
            case "Copy Rows":
                addItem(menu, title: title) { pasteboard.setString(TwelveSCopyFormatting.targetRowsTSV(rows)) }
            default:
                break
            }
        }
    }

    /// Populates `menu` with copy items for the current unresolved-mode selection.
    static func populateUnresolvedMenu(
        _ menu: NSMenu,
        rows: [TwelveSUnresolvedSequence],
        pasteboard: PasteboardWriting
    ) {
        menu.removeAllItems()
        guard !rows.isEmpty else { return }
        let hasSequence = rows.first.map { !$0.sequence.isEmpty } ?? false
        let titles = itemTitles(mode: .unresolved, selectedCount: rows.count, hasSequence: hasSequence)
        for title in titles {
            switch title {
            case "Copy Name", "Copy Names":
                addItem(menu, title: title) { pasteboard.setString(TwelveSCopyFormatting.unresolvedNames(rows)) }
            case "Copy Sequence":
                if let row = rows.first {
                    addItem(menu, title: title) { pasteboard.setString(TwelveSCopyFormatting.sequence(row)) }
                }
            case "Copy Sequences":
                addItem(menu, title: title) { pasteboard.setString(TwelveSCopyFormatting.fasta(rows)) }
            case "Copy Rows":
                addItem(menu, title: title) { pasteboard.setString(TwelveSCopyFormatting.unresolvedRowsTSV(rows)) }
            default:
                break
            }
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
