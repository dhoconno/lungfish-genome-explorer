// AnnotationTableDrawerView+SampleVisibility.swift - Sample visibility, variant query progress, the sample context menu and multi-selection actions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow
import os.log
import LungfishKit

extension AnnotationTableDrawerView {

    // MARK: - Sample Visibility

    @objc func sampleVisibilityToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < displayedSamples.count else { return }
        let name = displayedSamples[row].name
        let isNowVisible = sender.state == .on

        displayedSamples[row].isVisible = isNowVisible

        if isNowVisible {
            currentSampleDisplayState.hiddenSamples.remove(name)
        } else {
            currentSampleDisplayState.hiddenSamples.insert(name)
        }

        // Refresh the row to update text dimming
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))

        postSampleDisplayStateChange()
        updateCountLabel()
    }

    func postSampleDisplayStateChange() {
        hasSampleDisplayStateSeed = true
        NotificationCenter.default.post(
            name: .sampleDisplayStateChanged,
            object: self,
            userInfo: windowScopedUserInfo([NotificationUserInfoKey.sampleDisplayState: currentSampleDisplayState])
        )
    }

    @objc func handleSampleDisplayStateChanged(_ notification: Notification) {
        guard ScopedEventFilter.accept(notification, for: windowEventScope) else { return }
        // Ignore if we are the source
        if notification.object as AnyObject? === self { return }
        guard let state = notification.userInfo?[NotificationUserInfoKey.sampleDisplayState] as? SampleDisplayState else { return }
        currentSampleDisplayState = state
        hasSampleDisplayStateSeed = true
        if activeTab == .samples {
            updateDisplayedSamples()
        } else if activeTab == .variants {
            markVariantFilterStateMutated()
            updateDisplayedAnnotations()
        }
    }

    @objc func variantColorThemeDidChange(_ note: Notification) {
        if activeTab == .variants { tableView.reloadData() }
    }

    // MARK: - Variant Query Progress

    func invalidateInFlightVariantQueries() {
        variantQueryWorkItem?.cancel()
        variantQueryWorkItem = nil
        activeVariantQueryCancelToken?.cancel()
        activeVariantQueryCancelToken = nil
        variantQueryGeneration += 1
    }

    func showVariantQueryProgress(_ message: String) {
        isVariantQuerying = true
        queryProgressLabel.stringValue = message
        queryProgressLabel.isHidden = false
        queryProgressBar.isHidden = false
        queryProgressBar.startAnimation(nil)
        scrollView.isHidden = true
        tooManyLabel.isHidden = true
        countLabel.stringValue = "Querying\u{2026}"
    }

    func hideVariantQueryProgress() {
        isVariantQuerying = false
        queryProgressLabel.isHidden = true
        queryProgressBar.isHidden = true
        queryProgressBar.stopAnimation(nil)
    }

    // MARK: - Sample Context Menu Actions

    @objc func showAllSamplesAction(_ sender: NSMenuItem) {
        currentSampleDisplayState.hiddenSamples.removeAll()
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc func hideAllSamplesAction(_ sender: NSMenuItem) {
        currentSampleDisplayState.hiddenSamples = Set(allSampleNames)
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc func toggleSampleVisibilityAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if currentSampleDisplayState.hiddenSamples.contains(name) {
            currentSampleDisplayState.hiddenSamples.remove(name)
        } else {
            currentSampleDisplayState.hiddenSamples.insert(name)
        }
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc func copySampleNameAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let pasteboard = copyPasteboard
        pasteboard.clearContents()
        pasteboard.setString(name, forType: .string)
    }

    func buildSampleContextMenu(_ menu: NSMenu, row: Int, clickedColumn: Int) {
        let sample = displayedSamples[row]
        let selectedRows = tableView.selectedRowIndexes
        let hasMultiSelection = selectedRows.count > 1

        // Visibility toggle for clicked row
        let visTitle = sample.isVisible ? "Hide \(sample.name)" : "Show \(sample.name)"
        let visItem = NSMenuItem(title: visTitle, action: #selector(toggleSampleVisibilityAction(_:)), keyEquivalent: "")
        visItem.target = self
        visItem.representedObject = sample.name
        menu.addItem(visItem)

        // Multi-selection visibility actions
        if hasMultiSelection {
            menu.addItem(NSMenuItem.separator())

            let hideSelectedItem = NSMenuItem(title: "Hide Selected (\(selectedRows.count))", action: #selector(hideSelectedSamplesAction(_:)), keyEquivalent: "")
            hideSelectedItem.target = self
            menu.addItem(hideSelectedItem)

            let showSelectedItem = NSMenuItem(title: "Show Selected (\(selectedRows.count))", action: #selector(showSelectedSamplesAction(_:)), keyEquivalent: "")
            showSelectedItem.target = self
            menu.addItem(showSelectedItem)

            let showOnlyItem = NSMenuItem(title: "Show Only Selected", action: #selector(showOnlySelectedSamplesAction(_:)), keyEquivalent: "")
            showOnlyItem.target = self
            menu.addItem(showOnlyItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Show All / Hide All
        let showAllItem = NSMenuItem(title: "Show All Samples", action: #selector(showAllSamplesAction(_:)), keyEquivalent: "")
        showAllItem.target = self
        menu.addItem(showAllItem)

        let hideAllItem = NSMenuItem(title: "Hide All Samples", action: #selector(hideAllSamplesAction(_:)), keyEquivalent: "")
        hideAllItem.target = self
        menu.addItem(hideAllItem)

        menu.addItem(NSMenuItem.separator())

        // Copy name
        let copyItem = NSMenuItem(title: "Copy Sample Name", action: #selector(copySampleNameAction(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = sample.name
        menu.addItem(copyItem)

        if clickedColumn >= 0, clickedColumn < tableView.tableColumns.count {
            let column = tableView.tableColumns[clickedColumn]
            let columnId = column.identifier.rawValue
            if let filterKey = sampleFilterKey(forColumnIdentifier: columnId) {
                let value = sampleFilterValue(sample: sample, columnIdentifier: columnId)
                menu.addItem(NSMenuItem.separator())

                let applyMenu = NSMenu(title: "Filter Column")
                let applyMenuItem = NSMenuItem(title: "Filter Column", action: nil, keyEquivalent: "")
                applyMenuItem.submenu = applyMenu
                menu.addItem(applyMenuItem)

                addSampleColumnFilterItem(
                    to: applyMenu,
                    title: "Equals",
                    key: filterKey,
                    op: "=",
                    value: value
                )
                addSampleColumnFilterItem(
                    to: applyMenu,
                    title: "Not Equals",
                    key: filterKey,
                    op: "!=",
                    value: value
                )
                if !value.isEmpty {
                    addSampleColumnFilterItem(
                        to: applyMenu,
                        title: "Contains",
                        key: filterKey,
                        op: "~",
                        value: value
                    )
                    addSampleColumnFilterItem(
                        to: applyMenu,
                        title: "Begins With",
                        key: filterKey,
                        op: "^=",
                        value: value
                    )
                    addSampleColumnFilterItem(
                        to: applyMenu,
                        title: "Ends With",
                        key: filterKey,
                        op: "$=",
                        value: value
                    )
                }
                addSampleColumnFilterItem(
                    to: applyMenu,
                    title: "Is Empty",
                    key: filterKey,
                    op: "=",
                    value: ""
                )
                addSampleColumnFilterItem(
                    to: applyMenu,
                    title: "Is Not Empty",
                    key: filterKey,
                    op: "!=",
                    value: ""
                )
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Import metadata
        let importItem = NSMenuItem(title: "Import Metadata\u{2026}", action: #selector(importMetadataAction(_:)), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        let templateItem = NSMenuItem(title: "Download Template\u{2026}", action: #selector(downloadSampleTemplateAction(_:)), keyEquivalent: "")
        templateItem.target = self
        menu.addItem(templateItem)

        // Add custom field
        let addFieldItem = NSMenuItem(title: "Add Field\u{2026}", action: #selector(addCustomFieldAction(_:)), keyEquivalent: "")
        addFieldItem.target = self
        menu.addItem(addFieldItem)

        menu.addItem(NSMenuItem.separator())
        let groupFromShown = NSMenuItem(title: "Create Group from Shown Results\u{2026}", action: #selector(createSampleGroupFromShownResults(_:)), keyEquivalent: "")
        groupFromShown.target = self
        menu.addItem(groupFromShown)
    }

    func sampleFilterKey(forColumnIdentifier columnId: String) -> String? {
        switch columnId {
        case Self.sampleNameColumn.rawValue:
            return "name"
        case Self.sampleDisplayNameColumn.rawValue:
            return "display_name"
        case Self.sampleSourceColumn.rawValue:
            return "source"
        case Self.sampleVisibleColumn.rawValue:
            return "visible"
        default:
            if columnId.hasPrefix("meta_") {
                return "meta.\(String(columnId.dropFirst(5)))"
            }
            return nil
        }
    }

    func sampleFilterValue(sample: SampleDisplayRow, columnIdentifier columnId: String) -> String {
        switch columnId {
        case Self.sampleNameColumn.rawValue:
            return sample.name
        case Self.sampleDisplayNameColumn.rawValue:
            return sample.displayName ?? ""
        case Self.sampleSourceColumn.rawValue:
            return sample.sourceFile
        case Self.sampleVisibleColumn.rawValue:
            return sample.isVisible ? "true" : "false"
        default:
            if columnId.hasPrefix("meta_") {
                let key = String(columnId.dropFirst(5))
                return sample.metadata[key] ?? ""
            }
            return ""
        }
    }

    func addSampleColumnFilterItem(
        to menu: NSMenu,
        title: String,
        key: String,
        op: String,
        value: String
    ) {
        let item = NSMenuItem(title: title, action: #selector(applySampleColumnFilterAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["key": key, "op": op, "value": value]
        menu.addItem(item)
    }

    @objc func applySampleColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let value = payload["value"] else { return }
        let clause = value.isEmpty ? "\(key)\(op)" : "\(key)\(op)\(value)"
        let current = sampleFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        sampleFilterText = current.isEmpty ? clause : "\(current); \(clause)"
        updateDisplayedSamples()
    }

    @objc func promptSampleColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Add Sample Filter"
        alert.informativeText = "Enter a value for \(key)."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Filter value"
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, let self else { return }
            let clause = "\(key)\(op)\(value)"
            let current = self.sampleFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.sampleFilterText = current.isEmpty ? clause : "\(current); \(clause)"
            self.updateDisplayedSamples()
        }
    }

    func buildSampleGlobalContextMenu(_ menu: NSMenu) {
        addColumnSizingMenuItems(menu, tableColumn: nil)
        menu.addItem(NSMenuItem.separator())

        let showAllItem = NSMenuItem(title: "Show All Samples", action: #selector(showAllSamplesAction(_:)), keyEquivalent: "")
        showAllItem.target = self
        menu.addItem(showAllItem)

        let hideAllItem = NSMenuItem(title: "Hide All Samples", action: #selector(hideAllSamplesAction(_:)), keyEquivalent: "")
        hideAllItem.target = self
        menu.addItem(hideAllItem)

        menu.addItem(NSMenuItem.separator())

        let importItem = NSMenuItem(title: "Import Metadata\u{2026}", action: #selector(importMetadataAction(_:)), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        let templateItem = NSMenuItem(title: "Download Template\u{2026}", action: #selector(downloadSampleTemplateAction(_:)), keyEquivalent: "")
        templateItem.target = self
        menu.addItem(templateItem)

        let addFieldItem = NSMenuItem(title: "Add Field\u{2026}", action: #selector(addCustomFieldAction(_:)), keyEquivalent: "")
        addFieldItem.target = self
        menu.addItem(addFieldItem)

        menu.addItem(NSMenuItem.separator())
        let groupFromShown = NSMenuItem(title: "Create Group from Shown Results\u{2026}", action: #selector(createSampleGroupFromShownResults(_:)), keyEquivalent: "")
        groupFromShown.target = self
        menu.addItem(groupFromShown)
    }

    func buildSampleColumnHeaderContextMenu(_ menu: NSMenu, column: Int) {
        guard column >= 0, column < tableView.tableColumns.count else {
            buildSampleGlobalContextMenu(menu)
            return
        }
        let tableColumn = tableView.tableColumns[column]
        guard let key = sampleFilterKey(forColumnIdentifier: tableColumn.identifier.rawValue) else {
            buildSampleGlobalContextMenu(menu)
            return
        }
        let displayName = tableColumn.title.isEmpty ? "Visible" : tableColumn.title

        addColumnSizingMenuItems(menu, tableColumn: tableColumn)
        menu.addItem(NSMenuItem.separator())

        let containsItem = NSMenuItem(
            title: "Filter \(displayName) Contains\u{2026}",
            action: #selector(promptSampleColumnFilterAction(_:)),
            keyEquivalent: ""
        )
        containsItem.target = self
        containsItem.representedObject = ["key": key, "op": "~"]
        menu.addItem(containsItem)

        let equalsItem = NSMenuItem(
            title: "Filter \(displayName) Equals\u{2026}",
            action: #selector(promptSampleColumnFilterAction(_:)),
            keyEquivalent: ""
        )
        equalsItem.target = self
        equalsItem.representedObject = ["key": key, "op": "="]
        menu.addItem(equalsItem)

        let beginsWithItem = NSMenuItem(
            title: "Filter \(displayName) Begins With\u{2026}",
            action: #selector(promptSampleColumnFilterAction(_:)),
            keyEquivalent: ""
        )
        beginsWithItem.target = self
        beginsWithItem.representedObject = ["key": key, "op": "^="]
        menu.addItem(beginsWithItem)

        let endsWithItem = NSMenuItem(
            title: "Filter \(displayName) Ends With\u{2026}",
            action: #selector(promptSampleColumnFilterAction(_:)),
            keyEquivalent: ""
        )
        endsWithItem.target = self
        endsWithItem.representedObject = ["key": key, "op": "$="]
        menu.addItem(endsWithItem)

        menu.addItem(NSMenuItem.separator())
        addSampleColumnFilterItem(to: menu, title: "Filter \(displayName) Is Empty", key: key, op: "=", value: "")
        addSampleColumnFilterItem(to: menu, title: "Filter \(displayName) Is Not Empty", key: key, op: "!=", value: "")
        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear Sample Filters", action: #selector(clearSampleFilter(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        if tableColumn.identifier.rawValue.hasPrefix("meta_") {
            let metaKey = String(tableColumn.identifier.rawValue.dropFirst(5))
            menu.addItem(NSMenuItem.separator())
            let removeItem = NSMenuItem(title: "Delete Column\u{2026}", action: #selector(deleteSampleMetadataFieldAction(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = metaKey
            menu.addItem(removeItem)
        }
    }

    // MARK: - Multi-Selection Visibility Actions

    @objc func hideSelectedSamplesAction(_ sender: NSMenuItem) {
        let selectedRows = tableView.selectedRowIndexes
        for row in selectedRows {
            guard row < displayedSamples.count else { continue }
            let name = displayedSamples[row].name
            currentSampleDisplayState.hiddenSamples.insert(name)
        }
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc func showSelectedSamplesAction(_ sender: NSMenuItem) {
        let selectedRows = tableView.selectedRowIndexes
        for row in selectedRows {
            guard row < displayedSamples.count else { continue }
            let name = displayedSamples[row].name
            currentSampleDisplayState.hiddenSamples.remove(name)
        }
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc func showOnlySelectedSamplesAction(_ sender: NSMenuItem) {
        let selectedRows = tableView.selectedRowIndexes
        var selectedNames = Set<String>()
        for row in selectedRows {
            guard row < displayedSamples.count else { continue }
            selectedNames.insert(displayedSamples[row].name)
        }
        currentSampleDisplayState.hiddenSamples = Set(allSampleNames.filter { !selectedNames.contains($0) })
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc func createSampleGroupFromShownResults(_ sender: NSMenuItem) {
        guard !displayedSamples.isEmpty, let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Create Sample Group"
        alert.informativeText = "Create a group from the currently shown \(displayedSamples.count) samples."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.placeholderString = "Group name"
        alert.accessoryView = nameField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let sampleNames = Set(self.displayedSamples.map(\.name))
            guard !sampleNames.isEmpty else { return }
            if let idx = self.currentSampleDisplayState.sampleGroups.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                self.currentSampleDisplayState.sampleGroups[idx].sampleNames = sampleNames
            } else {
                self.currentSampleDisplayState.sampleGroups.append(
                    SampleGroup(name: name, sampleNames: sampleNames)
                )
            }
            self.postSampleDisplayStateChange()
            self.rebuildSampleGroupPresetMenu()
        }
    }

    @objc private func deleteSampleMetadataFieldAction(_ sender: NSMenuItem) {
        guard let fieldName = sender.representedObject as? String,
              !fieldName.isEmpty,
              sampleMetadataFields.contains(fieldName),
              let window = self.window else { return }
        guard canWriteVariantDatabaseOutputs(workflowName: "Sample metadata column deletion") else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Metadata Column?"
        alert.informativeText = "Delete '\(fieldName)' from all samples and variant databases? This cannot be undone."
        alert.addButton(withTitle: "Delete Column")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.applyLungfishDestructiveStyle()

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard self.canWriteVariantDatabaseOutputs(workflowName: "Sample metadata column deletion") else { return }
            guard let searchIndex = self.searchIndex else { return }

            let fieldToRemove = fieldName
            let sampleRows = self.allSampleRowKeys.compactMap { rowKey -> (name: String, sourceFile: String, metadata: [String: String])? in
                guard let sampleName = self.sampleNameByRowKey[rowKey] else { return nil }
                return (sampleName, self.sampleSourceFiles[rowKey] ?? "", self.sampleMetadata[rowKey] ?? [:])
            }
            guard let bundleURL = self.variantDatabaseBundleURL(from: searchIndex) else {
                annotationDrawerLogger.warning("deleteSampleMetadataFieldAction: Could not resolve enclosing bundle for variant databases")
                return
            }
            let targets = searchIndex.variantDatabaseHandles.map {
                VariantSampleMetadataImportTarget(databaseURL: $0.db.databaseURL, trackName: $0.trackId)
            }
            let mutationRows = sampleRows.map {
                VariantSampleMetadataMutationRow(name: $0.name, sourceFile: $0.sourceFile, metadata: $0.metadata)
            }

            DispatchQueue.global(qos: .userInitiated).async {
                var firstError: Error?
                do {
                    _ = try VariantSampleMetadataMutationService().deleteMetadataField(
                        fieldName: fieldToRemove,
                        sampleRows: mutationRows,
                        bundleURL: bundleURL,
                        targets: targets
                    )
                } catch {
                    firstError = error
                }

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let error = firstError {
                            FailurePresenter.present(ViewerFailureReports.deleteSampleMetadataColumn(fieldToRemove, error), in: window)
                            return
                        }

                        self.sampleMetadataFields.removeAll { $0 == fieldToRemove }
                        self.populateSampleData(from: searchIndex)
                        self.configureColumnsForTab(.samples)
                        self.updateDisplayedSamples()
                        annotationDrawerLogger.info("deleteSampleMetadataFieldAction: Removed metadata field '\(fieldToRemove, privacy: .public)'")
                    }
                }
            }
        }
    }
}
