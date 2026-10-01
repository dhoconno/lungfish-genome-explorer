// TaxTriageRowCommands.swift - One command set for both TaxTriage organism tables
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import SwiftUI

/// What a TaxTriage row command needs to know about the row it acts on, so
/// the batch table (``TaxTriageMetric`` rows) and the per-sample table
/// (``TaxTriageTableRow`` rows) share one set of commands.
struct TaxTriageRowSubject {
    let organism: String
    let taxId: Int?
    /// The value Copy Accession writes, or nil when the table has no such
    /// command.
    let accession: String?
    let tsvFields: [String]
}

/// The row commands of both TaxTriage organism tables.
///
/// The context menu, Selection > Table Row validation and each row's
/// accessibility actions read ``available(for:)``, so they list the same
/// commands under the same titles. Extract Reads and Verify with BLAST need
/// the table and its callbacks, so each table runs those itself. The rest
/// run here.
@MainActor
enum TaxTriageRowCommands {
    /// The context menu's sections, in display order.
    static let sections: [[ResultRowCommand]] = [
        [.blastVerify],
        [.copyName, .copyAccession, .copyTaxonID, .copyAsTSV],
        [.openTaxonomyOnNCBI],
        [.extractReads],
    ]

    static let supported: Set<ResultRowCommand> = Set(sections.flatMap { $0 })

    /// The commands that apply to `subjects`. Extract Reads takes any
    /// selection and every other command acts on exactly one row.
    static func available(for subjects: [TaxTriageRowSubject]) -> [ResultRowCommand] {
        guard let subject = subjects.first else { return [] }
        guard subjects.count == 1 else { return [.extractReads] }
        var commands: [ResultRowCommand] = [.blastVerify, .copyName]
        if subject.accession != nil { commands.append(.copyAccession) }
        commands.append(contentsOf: [.copyTaxonID, .copyAsTSV, .openTaxonomyOnNCBI, .extractReads])
        return commands
    }

    /// The context menu for a table whose handlers are the shared selectors.
    static func makeContextMenu(target: AnyObject, includingAccession: Bool) -> NSMenu {
        let menu = NSMenu()
        for (index, section) in sections.enumerated() {
            let commands = section.filter { includingAccession || $0 != .copyAccession }
            guard !commands.isEmpty else { continue }
            if index > 0 { menu.addItem(.separator()) }
            for command in commands {
                menu.addItem(command.makeContextMenuItem(target: target, action: command.menuSelector))
            }
        }
        return menu
    }

    /// Runs a command that needs only the row's own values. Returns false for
    /// the commands the table runs itself.
    @discardableResult
    static func perform(_ command: ResultRowCommand, on subject: TaxTriageRowSubject) -> Bool {
        switch command {
        case .copyName:
            writeToPasteboard(subject.organism)
        case .copyAccession:
            guard let accession = subject.accession else { return true }
            writeToPasteboard(accession)
        case .copyTaxonID:
            writeToPasteboard(subject.taxId.map(String.init) ?? "")
        case .copyAsTSV:
            writeToPasteboard(subject.tsvFields.joined(separator: "\t"))
        case .openTaxonomyOnNCBI:
            let urlString: String
            if let taxId = subject.taxId {
                urlString = "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=\(taxId)"
            } else {
                let encoded = subject.organism.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                    ?? subject.organism
                urlString = "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?name=\(encoded)"
            }
            if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
        default:
            return false
        }
        return true
    }

    /// Shows the BLAST read-count popover for a row, anchored to the row.
    static func presentBlastPopover(
        taxonName: String,
        readsClade: Int,
        anchorRect: NSRect,
        in view: NSView,
        onRun: @escaping @MainActor (Int) -> Void
    ) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 160)
        popover.contentViewController = NSHostingController(
            rootView: BlastConfigPopoverView(
                taxonName: taxonName,
                readsClade: readsClade,
                // Matches the database ViewerViewController+TaxTriage submits to.
                database: "core_nt",
                onRun: { [weak popover] readCount in
                    popover?.close()
                    onRun(readCount)
                }
            )
        )
        popover.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
    }

    private static func writeToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
