// AnnotationTableDrawerView+SampleMetadata.swift - Sample metadata import, groups, custom fields, inline editing and drag reordering of the annotation drawer
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

    // MARK: - Import Metadata

    /// Writes the sample metadata template through `lungfish-cli variants export sample-template` behind an
    /// Operations row (Phase 2.12 lane 12.39, B11). A drawer with no sample opens no save panel.
    @objc func downloadSampleTemplateAction(_ sender: Any?) {
        guard let searchIndex, let bundleURL = variantDatabaseBundleURL(from: searchIndex),
              !VariantSampleTemplateExport.sampleRows(databases: searchIndex.variantDatabaseHandles.map(\.db)).isEmpty
        else { return }

        let uniqueSourceFiles = Set(
            searchIndex.variantDatabaseHandles
                .flatMap { Array($0.db.allSourceFiles().values) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let defaultTemplateStem: String
        if uniqueSourceFiles.count == 1, let onlySource = uniqueSourceFiles.first {
            let sourceBase = URL(fileURLWithPath: onlySource).deletingPathExtension().lastPathComponent
            let safeSource = sourceBase
                .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
            if safeSource.isEmpty {
                defaultTemplateStem = "sample-metadata-source-template"
            } else {
                defaultTemplateStem = "sample-metadata-\(safeSource)-template"
            }
        } else if uniqueSourceFiles.count > 1 {
            defaultTemplateStem = "sample-metadata-multi-source-template"
        } else {
            defaultTemplateStem = "sample-metadata-template"
        }

        let panel = ViewerFilePanelFactory.sampleMetadataTemplatePanel(
            suggestedName: "\(defaultTemplateStem).tsv"
        )

        guard let window = self.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let invocation = self.variantSampleTemplateExportInvocation(bundleURL: bundleURL, outputURL: url)
            Self.beginVariantSampleTemplateExportOperation(invocation: invocation) { failure in
                annotationDrawerLogger.error("downloadSampleTemplateAction: \(failure.message)")
                Self.presentVariantExportFailure(title: "Template Export Failed", message: failure.message, in: window)
            }
        }
    }

    @objc func importMetadataAction(_ sender: Any?) {
        guard let searchIndex else { return }
        guard canWriteVariantDatabaseOutputs(workflowName: "Sample metadata import") else { return }
        let panel = ViewerFilePanelFactory.variantSampleMetadataImportPanel()

        guard let window = self.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let fileURL = panel.url, self.searchIndex === searchIndex else { return }
            guard self.canWriteVariantDatabaseOutputs(workflowName: "Sample metadata import") else { return }
            let ext = fileURL.pathExtension.lowercased()
            let format: MetadataFormat = ext == "csv" ? .csv : .tsv

            guard let bundleURL = self.variantDatabaseBundleURL(from: searchIndex) else {
                annotationDrawerLogger.warning("importSampleMetadata: Could not resolve enclosing bundle for variant databases")
                return
            }
            // `variants import-sample-metadata` reads the file and stores the samples (decision C3).
            self.importSampleMetadata(fileURL: fileURL, format: format, bundleURL: bundleURL)
        }
    }

    // MARK: - Sample Groups

    @objc func showSampleGroupsSheet(_ sender: Any?) {
        guard let hostWindow = self.window else { return }

        let sheetView = SampleGroupSheet(
            groups: currentSampleDisplayState.sampleGroups,
            allSampleNames: allSampleNames,
            onApply: { [weak self] groups in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        hostWindow.endSheet(hostWindow.sheets.last ?? hostWindow)
                        self.currentSampleDisplayState.sampleGroups = groups
                        if let selected = self.selectedSampleGroupId,
                           !groups.contains(where: { $0.id == selected }) {
                            self.selectedSampleGroupId = nil
                        }
                        self.postSampleDisplayStateChange()
                        self.rebuildSampleGroupPresetMenu()
                        self.updateDisplayedSamples()
                    }
                }
            },
            onCancel: {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        hostWindow.endSheet(hostWindow.sheets.last ?? hostWindow)
                    }
                }
            }
        )

        let hostingController = NSHostingController(rootView: sheetView)
        let sheetWindow = NSPanel(contentViewController: hostingController)
        sheetWindow.styleMask = [.titled, .closable, .resizable]
        sheetWindow.title = "Sample Groups"
        hostWindow.beginSheet(sheetWindow)
    }

    // MARK: - Add Custom Field

    @objc func addCustomFieldAction(_ sender: Any) {
        let alert = NSAlert()
        alert.messageText = "Add Custom Field"
        alert.informativeText = "Enter a name for the new metadata field:"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "Field name"
        alert.accessoryView = textField

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let fieldName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fieldName.isEmpty else { return }
            guard !self.sampleMetadataFields.contains(fieldName) else { return }

            self.sampleMetadataFields.append(fieldName)
            self.sampleMetadataFields.sort()
            self.configureColumnsForTab(.samples)
            self.updateDisplayedSamples()
        }
    }

    // MARK: - Inline Metadata Editing

    public func controlTextDidEndEditing(_ notification: Notification) {
        guard activeTab == .samples,
              let tf = notification.object as? NSTextField,
              let cellView = tf.superview as? NSTableCellView else { return }

        let column = tableView.column(for: cellView)
        guard column >= 0, column < tableView.tableColumns.count else { return }

        let row = tf.tag
        guard row >= 0, row < displayedSamples.count else { return }

        let columnId = tableView.tableColumns[column].identifier
        let newValue = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sampleName = displayedSamples[row].name
        let sampleSourceFile = displayedSamples[row].sourceFile
        let sampleRowKey = displayedSamples[row].rowKey

        // Handle Display Name column edits
        if columnId == Self.sampleDisplayNameColumn {
            guard canWriteVariantDatabaseOutputs(workflowName: "Sample display name edit") else {
                tableView.reloadData()
                return
            }
            let displayName = newValue.isEmpty ? nil : newValue
            displayedSamples[row].displayName = displayName
            if let displayName {
                sampleDisplayNamesCache[sampleRowKey] = displayName
            } else {
                sampleDisplayNamesCache.removeValue(forKey: sampleRowKey)
            }
            // Persist to DB
            if let searchIndex {
                for handle in searchIndex.variantDatabaseHandles {
                    do {
                        let rwDB = try VariantDatabase(url: handle.db.databaseURL, readWrite: true)
                        let dbSourceBySample = rwDB.allSourceFiles()
                        guard let dbSource = dbSourceBySample[sampleName],
                              Self.sourceFileMatches(dbSource, sampleSourceFile) else { continue }
                        rwDB.setDisplayName(forSample: sampleName, displayName: displayName)
                    } catch {
                        annotationDrawerLogger.warning("Display name edit failed: \(error.localizedDescription)")
                    }
                }
            }
            // Update state and notify viewport
            if let displayName {
                currentSampleDisplayState.sampleDisplayNameOverrides[sampleName] = displayName
            } else {
                currentSampleDisplayState.sampleDisplayNameOverrides.removeValue(forKey: sampleName)
            }
            postSampleDisplayStateChange()
            return
        }

        // Handle metadata column edits
        guard columnId.rawValue.hasPrefix("meta_") else { return }
        guard canWriteVariantDatabaseOutputs(workflowName: "Sample metadata edit") else {
            tableView.reloadData()
            return
        }

        let metaKey = String(columnId.rawValue.dropFirst(5))

        // Update local model
        if newValue.isEmpty {
            displayedSamples[row].metadata.removeValue(forKey: metaKey)
        } else {
            displayedSamples[row].metadata[metaKey] = newValue
        }
        // Keep backing metadata cache in sync so refresh/sort/filter preserves edits.
        sampleMetadata[sampleRowKey] = displayedSamples[row].metadata

        // Persist to database
        guard let searchIndex else { return }
        let fullMetadata = displayedSamples[row].metadata

        guard let bundleURL = variantDatabaseBundleURL(from: searchIndex) else {
            annotationDrawerLogger.warning("Inline metadata edit failed: could not resolve enclosing bundle")
            return
        }
        do {
            let targets = searchIndex.variantDatabaseHandles.map {
                VariantSampleMetadataImportTarget(databaseURL: $0.db.databaseURL, trackName: $0.trackId)
            }
            _ = try VariantSampleMetadataMutationService().updateSampleMetadata(
                sampleName: sampleName,
                sourceFile: sampleSourceFile,
                metadata: fullMetadata,
                bundleURL: bundleURL,
                targets: targets
            )
        } catch {
            annotationDrawerLogger.warning("Inline metadata edit failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Sample Drag-and-Drop Reordering

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard activeTab == .samples, row < displayedSamples.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .string)
        return item
    }

    public func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard activeTab == .samples else { return [] }
        if dropOperation == .above {
            return .move
        }
        return []
    }

    public func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard activeTab == .samples else { return false }

        // Collect dragged row indices
        var draggedRows = IndexSet()
        info.enumerateDraggingItems(
            options: [],
            for: tableView,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { item, _, _ in
            if let pbItem = item.item as? NSPasteboardItem,
               let rowStr = pbItem.string(forType: .string),
               let sourceRow = Int(rowStr) {
                draggedRows.insert(sourceRow)
            }
        }

        guard !draggedRows.isEmpty else { return false }

        // Collect the dragged items in order
        let draggedItems = draggedRows.sorted().compactMap { idx -> SampleDisplayRow? in
            guard idx < displayedSamples.count else { return nil }
            return displayedSamples[idx]
        }
        let draggedKeys = draggedItems.map(\.rowKey)
        let draggedKeySet = Set(draggedKeys)

        let fullOrder = resolvedSampleOrder()
        var reordered = fullOrder.filter { !draggedKeySet.contains($0) }

        // Insert relative to visible rows, but apply to full ordering.
        let insertionIndex: Int
        if row >= displayedSamples.count {
            insertionIndex = reordered.count
        } else {
            let anchorKey = displayedSamples[row].rowKey
            insertionIndex = reordered.firstIndex(of: anchorKey) ?? reordered.count
        }
        reordered.insert(contentsOf: draggedKeys, at: insertionIndex)

        // Update display state with new order
        currentSampleDisplayState.sampleOrder = reordered
        postSampleDisplayStateChange()
        updateDisplayedSamples()
        return true
    }
}
