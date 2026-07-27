// SidebarViewController+OutlineDelegate.swift - NSOutlineViewDelegate conformance
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }

        let hasSubtitle = sidebarItem.subtitle != nil
        let identifier = NSUserInterfaceItemIdentifier(hasSubtitle ? "SidebarCellWithSubtitle" : "SidebarCell")
        var cellView = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView

        if cellView == nil {
            cellView = NSTableCellView()
            cellView?.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cellView?.addSubview(imageView)
            cellView?.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            cellView?.addSubview(textField)
            cellView?.textField = textField

            if hasSubtitle {
                let subtitleField = NSTextField(labelWithString: "")
                subtitleField.translatesAutoresizingMaskIntoConstraints = false
                subtitleField.lineBreakMode = .byTruncatingTail
                subtitleField.font = NSFont.systemFont(ofSize: 10)
                subtitleField.textColor = .secondaryLabelColor
                subtitleField.tag = 999
                cellView?.addSubview(subtitleField)

                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cellView!.leadingAnchor, constant: 2),
                    imageView.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),

                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cellView!.trailingAnchor, constant: -2),
                    textField.topAnchor.constraint(equalTo: cellView!.topAnchor, constant: 2),

                    subtitleField.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
                    subtitleField.trailingAnchor.constraint(equalTo: textField.trailingAnchor),
                    subtitleField.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 0),
                    subtitleField.bottomAnchor.constraint(lessThanOrEqualTo: cellView!.bottomAnchor, constant: -2),
                ])
            } else {
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cellView!.leadingAnchor, constant: 2),
                    imageView.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),

                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cellView!.trailingAnchor, constant: -2),
                    textField.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor),
                ])
            }
        }

        // Configure cell
        cellView?.textField?.stringValue = sidebarItem.title

        if let accessibilityIdentifier = sidebarItem.userInfo["accessibilityIdentifier"] {
            cellView?.setAccessibilityIdentifier(accessibilityIdentifier)
            cellView?.textField?.setAccessibilityIdentifier(accessibilityIdentifier)
        }

        // Update subtitle field if present
        if let subtitleField = cellView?.viewWithTag(999) as? NSTextField {
            subtitleField.stringValue = sidebarItem.subtitle ?? ""
        }

        if sidebarItem.type == .group {
            cellView?.textField?.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            cellView?.textField?.textColor = .secondaryLabelColor
            cellView?.imageView?.image = nil
            cellView?.toolTip = nil
            cellView?.textField?.toolTip = nil
        } else {
            cellView?.textField?.font = NSFont.systemFont(ofSize: 13)
            cellView?.textField?.textColor = .labelColor

            if let customImage = sidebarItem.customImage {
                cellView?.imageView?.image = customImage
                cellView?.imageView?.contentTintColor = nil  // custom image has its own colors
            } else if let iconName = sidebarItem.icon {
                cellView?.imageView?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: sidebarItem.title)
                cellView?.imageView?.contentTintColor = sidebarItem.type.tintColor
            }

            let detail = sidebarItem.url?.path ?? sidebarItem.title
            cellView?.toolTip = detail
            cellView?.textField?.toolTip = detail
        }

        return cellView
    }

    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let sidebarItem = item as? SidebarItem, sidebarItem.subtitle != nil {
            return 36
        }
        return 24
    }

    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if let sidebarItem = item as? SidebarItem {
            return sidebarItem.type == .group
        }
        return false
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if let sidebarItem = item as? SidebarItem {
            return sidebarItem.type != .group
        }
        return true
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        if suppressSelectionCallbacks {
            sidebarLogger.debug("outlineViewSelectionDidChange: Suppressed during programmatic update")
            return
        }

        // Get ALL selected items for multi-selection support
        let items = selectedItems()
        handleSelectionChange(items, source: "outlineViewSelectionDidChange")
    }

    func handleSelectionChange(_ items: [SidebarItem], source: String) {
        let requestedItems = items
        let commit: @MainActor () -> Void = {
            [weak self] in
            guard let self else { return }
            self.commitSelectionChange(
                requestedItems,
                source: source
            )
        }
        if selectionDelegate?.sidebarShouldDeferSelectionTransition(
            .selection,
            commit: commit
        ) == true {
            restoreCommittedSelection()
            return
        }
        commitSelectionChange(items, source: source)
    }

    func handleSelectionRefresh(
        _ items: [SidebarItem],
        source: String
    ) {
        let resolvedItems = resolveVisibleSelectionItems(items)
        committedSelectionItems = resolvedItems
        let commit = { @MainActor [weak self] in
            guard let self else { return }
            sidebarLogger.debug(
                "\(source, privacy: .public): Refreshing \(resolvedItems.count) committed sidebar item(s)"
            )
            selectionDelegate?.sidebarDidRefreshSelectedItems(
                resolvedItems
            )
        }
        if selectionDelegate?.sidebarShouldDeferSelectionTransition(
            .refresh,
            commit: commit
        ) == true {
            return
        }
        commit()
    }

    private func commitSelectionChange(
        _ requestedItems: [SidebarItem],
        source: String
    ) {
        let items = resolveVisibleSelectionItems(requestedItems)
        applySidebarSelection(items)
        committedSelectionItems = items

        if items.isEmpty {
            sidebarLogger.debug("\(source, privacy: .public): Selection cleared")

            // Call delegate directly - synchronous, no Task needed
            selectionDelegate?.sidebarDidSelectItem(nil)

            // Keep notification for other observers (e.g., InspectorViewController)
            NotificationCenter.default.post(
                name: .sidebarSelectionChanged,
                object: self,
                userInfo: sidebarSelectionUserInfo(items: [])
            )
            return
        }

        // Log all selected items
        let itemNames = items.map { $0.title }.joined(separator: ", ")
        sidebarLogger.info("\(source, privacy: .public): Selected \(items.count) items: [\(itemNames, privacy: .public)]")

        // Call delegate directly - synchronous, reliable
        // This is the primary way to handle selection changes for content display
        if items.count == 1 {
            selectionDelegate?.sidebarDidSelectItem(items.first)
        } else {
            selectionDelegate?.sidebarDidSelectItems(items)
        }

        // Keep notification for other observers (e.g., InspectorViewController)
        // but document loading should NOT be triggered by this notification
        NotificationCenter.default.post(
            name: .sidebarSelectionChanged,
            object: self,
            userInfo: sidebarSelectionUserInfo(items: items)
        )
        sidebarLogger.debug("\(source, privacy: .public): Called delegate and posted notification with \(items.count) items")
    }

    private func restoreCommittedSelection() {
        let items = resolveVisibleSelectionItems(
            committedSelectionItems
        )
        committedSelectionItems = items
        applySidebarSelection(items)
    }

    private func applySidebarSelection(_ items: [SidebarItem]) {
        let rows = IndexSet(
            items.compactMap { item in
                let row = outlineView.row(forItem: item)
                return row >= 0 ? row : nil
            }
        )
        suppressSelectionCallbacks = true
        if rows.isEmpty {
            outlineView.deselectAll(nil)
        } else {
            outlineView.selectRowIndexes(
                rows,
                byExtendingSelection: false
            )
        }
        suppressSelectionCallbacks = false
    }

    private func resolveVisibleSelectionItems(
        _ items: [SidebarItem]
    ) -> [SidebarItem] {
        var resolved: [SidebarItem] = []
        var seen = Set<ObjectIdentifier>()
        for item in items {
            let candidate: SidebarItem?
            if outlineView.row(forItem: item) >= 0 {
                candidate = item
            } else if let url = item.url?.standardizedFileURL {
                candidate = visibleSidebarItem(matching: url)
            } else {
                candidate = nil
            }
            if let candidate,
               seen.insert(ObjectIdentifier(candidate)).inserted {
                resolved.append(candidate)
            }
        }
        return resolved
    }

    private func visibleSidebarItem(
        matching url: URL
    ) -> SidebarItem? {
        func search(_ items: [SidebarItem]) -> SidebarItem? {
            for item in items {
                if item.url?.standardizedFileURL == url {
                    return item
                }
                if let match = search(item.children) {
                    return match
                }
            }
            return nil
        }
        return search(rootItems)
    }

    func sidebarSelectionUserInfo(items: [SidebarItem]) -> [String: Any] {
        var userInfo: [String: Any] = ["items": items]
        if let first = items.first {
            userInfo["item"] = first
            if let scope = windowStateScope {
                userInfo[NotificationUserInfoKey.contentSelectionIdentity] = ContentSelectionIdentity(
                    url: first.url,
                    kind: first.type.description,
                    resultID: first.title,
                    windowID: scope.id
                )
            }
        }
        if let scope = windowStateScope {
            userInfo[NotificationUserInfoKey.windowStateScope] = scope
        }
        return userInfo
    }
}
