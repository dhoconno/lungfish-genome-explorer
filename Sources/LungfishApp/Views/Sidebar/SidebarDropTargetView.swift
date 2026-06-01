// SidebarDropTargetView.swift - Fallback drag destination for the sidebar
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

// MARK: - Sidebar Drop Target View

/// Custom NSView subclass that acts as a fallback drag destination for the sidebar.
/// This ensures file drops are accepted even when the outline view doesn't handle them
/// (e.g., when dropping onto empty space or when the sidebar is empty).
@MainActor
class SidebarDropTargetView: NSView {

    /// Weak reference to the sidebar controller to forward drop events
    weak var sidebarController: SidebarViewController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    /// Check if the pasteboard contains valid file URLs.
    ///
    /// Accepts all files since non-genomics files use QuickLook preview.
    private func hasValidFiles(in pasteboard: NSPasteboard) -> Bool {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }
        // Accept any file with a non-empty extension (exclude hidden files)
        return urls.contains { url in
            !url.pathExtension.isEmpty
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasValidFiles(in: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasValidFiles(in: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // No action needed
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }

        // Post a single notification with all dropped URLs
        NotificationCenter.default.post(
            name: .sidebarFileDropped,
            object: self.sidebarController,
            userInfo: ["urls": urls, "destination": NSNull()]
        )

        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        // No action needed
    }
}
