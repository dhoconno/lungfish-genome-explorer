// AnnotationTableDrawerView+Bookmarks.swift - Variant bookmarking and flagging
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishOperations
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

    /// Exports bookmarked variants to TSV through `lungfish-cli variants export bookmarked` behind an Operations row
    /// (Phase 2.12 lane 12.39, B6).
    @objc func exportBookmarkedVariants(_ sender: Any?) {
        guard searchIndex != nil else { return }
        guard let databaseURLs = bookmarkedVariantsExportDatabaseURLs() else {
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
            let invocation = BookmarkedVariantExport.invocation(
                databaseURLs: databaseURLs,
                outputURL: url,
                force: FileManager.default.fileExists(atPath: url.path)
            )
            Self.beginBookmarkedVariantsExportOperation(invocation: invocation) { failure in
                bookmarkLogger.error("Bookmark export failed: \(failure.message)")
                Self.presentVariantExportFailure(title: "Bookmark Export Failed", message: failure.message, in: window)
            }
        }
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
