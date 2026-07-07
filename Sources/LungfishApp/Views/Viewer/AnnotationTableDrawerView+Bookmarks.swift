// AnnotationTableDrawerView+Bookmarks.swift - Variant bookmarking and flagging
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow
import UniformTypeIdentifiers
import os.log

private let bookmarkLogger = Logger(subsystem: "com.lungfish.app", category: "Bookmarks")

extension AnnotationTableDrawerView {

    // MARK: - Bookmark Column

    static let bookmarkColumn = NSUserInterfaceItemIdentifier("BookmarkColumn")

    /// Configures the bookmark (star) column as the leftmost column in variant tables.
    func addBookmarkColumnIfNeeded() {
        guard activeTab == .variants else { return }
        guard tableView.tableColumns.first(where: { $0.identifier == Self.bookmarkColumn }) == nil else { return }

        let col = NSTableColumn(identifier: Self.bookmarkColumn)
        col.title = ""
        col.width = 28
        col.minWidth = 28
        col.maxWidth = 28
        col.headerCell.alignment = .center
        // Insert as first column
        if tableView.tableColumns.isEmpty {
            tableView.addTableColumn(col)
        } else {
            tableView.addTableColumn(col)
            tableView.moveColumn(tableView.tableColumns.count - 1, toColumn: 0)
        }
    }

    /// Returns the bookmark view for a variant row.
    func bookmarkView(for row: Int) -> NSView? {
        guard row < displayedAnnotations.count else { return nil }
        let annotation = displayedAnnotations[row]
        guard let variantRowId = annotation.variantRowId else { return nil }

        let key = bookmarkKey(trackId: annotation.trackId, variantRowId: variantRowId)
        let isBookmarked = bookmarkedVariantKeys.contains(key)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 16))
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: isBookmarked ? "star.fill" : "star", accessibilityDescription: "Bookmark")
        button.contentTintColor = isBookmarked ? .systemYellow : .tertiaryLabelColor
        button.target = self
        button.action = #selector(bookmarkToggled(_:))
        button.tag = row
        return button
    }

    @objc func bookmarkToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row < displayedAnnotations.count else { return }
        let annotation = displayedAnnotations[row]
        guard let variantRowId = annotation.variantRowId else { return }
        let key = bookmarkKey(trackId: annotation.trackId, variantRowId: variantRowId)

        guard let db = variantDatabase(forTrackId: annotation.trackId) else { return }
        let newState = db.toggleBookmark(variantId: variantRowId)
        if newState {
            bookmarkedVariantKeys.insert(key)
        } else {
            bookmarkedVariantKeys.remove(key)
        }

        // Update just this row
        let colIndex = tableView.column(withIdentifier: Self.bookmarkColumn)
        if colIndex >= 0 {
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: colIndex))
        }
    }

    @objc func contextBookmarkToggle(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? AnnotationSearchIndex.SearchResult,
              let variantRowId = annotation.variantRowId else { return }
        let key = bookmarkKey(trackId: annotation.trackId, variantRowId: variantRowId)
        guard let db = variantDatabase(forTrackId: annotation.trackId) else { return }
        let newState = db.toggleBookmark(variantId: variantRowId)
        if newState {
            bookmarkedVariantKeys.insert(key)
        } else {
            bookmarkedVariantKeys.remove(key)
        }
        // Reload the bookmark column for the affected row
        if let row = displayedAnnotations.firstIndex(where: { $0.variantRowId == variantRowId && $0.trackId == annotation.trackId }) {
            let colIndex = tableView.column(withIdentifier: Self.bookmarkColumn)
            if colIndex >= 0 {
                tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: colIndex))
            }
        }
    }

    // MARK: - Bookmark State

    /// Loads bookmarked variant IDs from all variant databases.
    func loadBookmarkedVariantIds() {
        bookmarkedVariantKeys.removeAll()
        guard let index = searchIndex else { return }
        for handle in index.variantDatabaseHandles {
            for rowId in handle.db.bookmarkedVariantIds() {
                bookmarkedVariantKeys.insert(bookmarkKey(trackId: handle.trackId, variantRowId: rowId))
            }
        }
    }

    // MARK: - Bookmark Export

    /// Exports bookmarked variants to TSV.
    @objc func exportBookmarkedVariants(_ sender: Any?) {
        guard let index = searchIndex else { return }

        // Collect bookmarked variants using efficient SQL JOIN per database
        var bookmarkedResults: [AnnotationSearchIndex.SearchResult] = []
        for handle in index.variantDatabaseHandles {
            let records = handle.db.bookmarkedVariants()
            for record in records {
                bookmarkedResults.append(AnnotationSearchIndex.SearchResult(
                    name: record.variantID,
                    chromosome: record.chromosome,
                    start: record.position,
                    end: record.end,
                    trackId: handle.trackId,
                    type: record.variantType,
                    ref: record.ref,
                    alt: record.alt,
                    quality: record.quality,
                    filter: record.filter,
                    sampleCount: record.sampleCount,
                    variantRowId: record.id
                ))
            }
        }

        guard !bookmarkedResults.isEmpty else {
            guard let window = self.window else { return }
            let alert = NSAlert()
            alert.messageText = "No Bookmarks"
            alert.informativeText = "No variants have been bookmarked yet. Click the star icon next to a variant to bookmark it."
            alert.alertStyle = .informational
            alert.beginSheetModal(for: window)
            return
        }

        let panel = ViewerFilePanelFactory.bookmarkedVariantsExportPanel()

        guard let window = self.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }

            let startedAt = Date()
            var lines: [String] = []
            lines.append(["ID", "Type", "Chrom", "Pos", "Ref", "Alt", "Quality", "Filter"].joined(separator: "\t"))
            for v in bookmarkedResults {
                let pos = v.start + 1  // VCF is 1-based
                let qual = v.quality.map { $0 < 0 ? "." : String(format: "%.1f", $0) } ?? "."
                lines.append([
                    v.name, v.type, v.chromosome, "\(pos)",
                    v.ref ?? ".", v.alt ?? ".", qual, v.filter ?? ".",
                ].joined(separator: "\t"))
            }

            do {
                try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
                let sourceURLs = self.bookmarkedVariantExportSourceURLs(from: index)
                try ScientificFileExportProvenance.write(.init(
                    workflowName: "lungfish app bookmarked variant export",
                    sourceURLs: sourceURLs,
                    outputURL: url,
                    outputFormat: .text,
                    argv: self.bookmarkedVariantExportArgv(sourceURLs: sourceURLs, outputURL: url),
                    explicitOptions: [
                        "sourceVariantDatabasePaths": .array(sourceURLs.map { .file($0) }),
                        "outputPath": .file(url),
                    ],
                    defaults: [
                        "outputFormat": .string("tsv"),
                    ],
                    resolved: [
                        "variantCount": .integer(bookmarkedResults.count),
                    ],
                    startedAt: startedAt
                ))
                bookmarkLogger.info("Exported \(bookmarkedResults.count) bookmarked variants to \(url.lastPathComponent)")
            } catch {
                try? FileManager.default.removeItem(at: url)
                bookmarkLogger.error("Bookmark export failed: \(error)")
            }
        }
    }

    private func bookmarkedVariantExportSourceURLs(from index: AnnotationSearchIndex) -> [URL] {
        var seen = Set<String>()
        return index.variantDatabaseHandles.compactMap { handle in
            let url = handle.db.databaseURL.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    private func bookmarkedVariantExportArgv(sourceURLs: [URL], outputURL: URL) -> [String] {
        var argv = ["Lungfish Genome Explorer", "export-bookmarked-variants"]
        for sourceURL in sourceURLs {
            argv.append(contentsOf: ["--variant-database", sourceURL.path])
        }
        argv.append(contentsOf: ["--output", outputURL.path])
        return argv
    }

    // MARK: - Bookmark Smart Token

    /// Returns true if any bookmarks exist (for smart token availability).
    var hasBookmarks: Bool {
        !bookmarkedVariantKeys.isEmpty
    }

    // MARK: - Helpers

    /// Finds the variant database for a given track ID.
    /// Falls back to first database if no match (single-track common case).
    private func variantDatabase(forTrackId trackId: String) -> LungfishIO.VariantDatabase? {
        guard let index = searchIndex else { return nil }
        let handles = index.variantDatabaseHandles
        return handles.first(where: { $0.trackId == trackId })?.db ?? handles.first?.db
    }

    /// Stable in-memory key for bookmark membership checks across multiple variant tracks.
    func bookmarkKey(trackId: String, variantRowId: Int64) -> String {
        "\(trackId):\(variantRowId)"
    }
}
