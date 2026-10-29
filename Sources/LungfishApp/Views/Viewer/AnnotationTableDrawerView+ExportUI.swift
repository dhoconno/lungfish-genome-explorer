import AppKit
import LungfishKit
import LungfishWorkflow
import UniformTypeIdentifiers

private struct ScientificTableExportMenuRequest {
    let scope: AnnotationTableExportScope
    let format: ScientificTableFormat
}

enum AnnotationTableExportMenuModel {
    static let formats: [(ScientificTableFormat, String)] = [
        (.xlsx, "Excel Workbook (.xlsx)"), (.csv, "CSV"), (.tsv, "TSV"), (.json, "JSON"),
    ]

    static func scopeTitle(_ scope: AnnotationTableExportScope, selectedCount: Int) -> String {
        switch scope {
        case .allMatching: return "All Matching Rows…"
        case .selected: return "Selected Rows (\(selectedCount))…"
        }
    }

    static func suggestedFilename(tab: String, scope: AnnotationTableExportScope, format: ScientificTableFormat) -> String {
        "\(tab)-\(scope == .selected ? "selected" : "all-matching").\(format.rawValue)"
    }
}

@MainActor
private enum ScientificTableExportUIState {
    static var cancellationByDrawer: [ObjectIdentifier: VariantQueryCancellationToken] = [:]
    static var windowCloseObserverByDrawer: [ObjectIdentifier: NSObjectProtocol] = [:]
}

extension AnnotationTableDrawerView {
    func showScientificTableExportMenu(_ sender: Any?) {
        let menu = makeScientificTableExportMenu()
        let anchor = (sender as? NSView) ?? exportButton
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 2), in: anchor)
    }

    /// The export menu for the current tab and selection: a scope item per
    /// row set, each with a format submenu. Also what the export button's
    /// accessibility actions mirror.
    func makeScientificTableExportMenu() -> NSMenu {
        let menu = NSMenu(title: "Export")
        menu.addItem(exportScopeMenuItem(
            title: AnnotationTableExportMenuModel.scopeTitle(.allMatching, selectedCount: tableView.selectedRowIndexes.count),
            scope: .allMatching, enabled: true
        ))
        menu.addItem(exportScopeMenuItem(
            title: AnnotationTableExportMenuModel.scopeTitle(.selected, selectedCount: tableView.selectedRowIndexes.count),
            scope: .selected,
            enabled: !tableView.selectedRowIndexes.isEmpty
        ))
        menu.addItem(.separator())
        let help = NSMenuItem(title: "All matching rows includes results beyond the table display limit. Current filters and column order are used.", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
        return menu
    }

    private func exportScopeMenuItem(
        title: String, scope: AnnotationTableExportScope, enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = enabled
        let submenu = NSMenu(title: title)
        for (format, label) in AnnotationTableExportMenuModel.formats {
            let child = NSMenuItem(title: label, action: #selector(performScientificTableExport(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = ScientificTableExportMenuRequest(scope: scope, format: format)
            child.isEnabled = enabled && ScientificTableExportUIState.cancellationByDrawer[ObjectIdentifier(self)] == nil
            submenu.addItem(child)
        }
        item.submenu = submenu
        return item
    }

    @objc private func performScientificTableExport(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ScientificTableExportMenuRequest else { return }
        let captured: AnnotationTablePendingExport
        do {
            captured = try captureAnnotationTableExport(scope: request.scope)
        } catch {
            presentScientificExportError(error)
            return
        }
        let tab = captured.tab
        let suggestedName = AnnotationTableExportMenuModel.suggestedFilename(
            tab: tab, scope: request.scope, format: request.format
        )
        let type: UTType = {
            switch request.format {
            case .xlsx: return UTType(filenameExtension: "xlsx") ?? .data
            case .csv: return .commaSeparatedText
            case .tsv: return .tabSeparatedText
            case .json: return .json
            }
        }()
        let panel = ViewerFilePanelFactory.tableExportPanel(
            title: "Export \(tab.capitalized)", suggestedName: suggestedName, contentType: type
        )
        panel.prompt = "Export"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let outputURL = panel.url, let self else { return }
            self.runScientificTableExport(captured, format: request.format, outputURL: outputURL)
        }
    }

    private func runScientificTableExport(
        _ captured: AnnotationTablePendingExport,
        format: ScientificTableFormat,
        outputURL: URL
    ) {
        guard let window else { return }
        let identity = ObjectIdentifier(self)
        guard ScientificTableExportUIState.cancellationByDrawer[identity] == nil else { return }
        let token = VariantQueryCancellationToken()
        ScientificTableExportUIState.cancellationByDrawer[identity] = token
        ScientificTableExportUIState.windowCloseObserverByDrawer[identity] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in token.cancel() }
        exportButton.isEnabled = false

        let progress = NSAlert()
        progress.messageText = "Exporting \(captured.tab.capitalized)…"
        progress.informativeText = "Collecting all matching records and writing \(format.rawValue.uppercased())."
        progress.alertStyle = .informational
        progress.addButton(withTitle: "Cancel")
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 280, height: 20))
        indicator.style = .spinning
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        progress.accessoryView = indicator
        progress.beginSheetModal(for: window) { _ in token.cancel() }

        // ARCH ruling on 12.39 R1 item 1. The rows are resolved under this sheet and its Cancel, then the selection
        // is written and the row begins. A cancel before the row writes and begins nothing.
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<(Int, ViewerExportInvocation), Error>
            do {
                let snapshot = try captured.collect { token.isCancelled }
                if token.isCancelled { throw CancellationError() }
                let invocation = try AnnotationTableDrawerView.annotationTableExportInvocation(
                    snapshot: snapshot, bundleURL: captured.bundleURL, tableSelection: captured.tableSelection,
                    editedValues: captured.editedValues, format: format, outputURL: outputURL
                )
                result = .success((snapshot.table.rows.count, invocation))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                ScientificTableExportUIState.cancellationByDrawer[identity] = nil
                if let observer = ScientificTableExportUIState.windowCloseObserverByDrawer.removeValue(forKey: identity) {
                    NotificationCenter.default.removeObserver(observer)
                }
                // `endSheet` runs the progress sheet's handler, which cancels the token, so the user's cancel is read
                // before the sheet ends and a finished export is not read as cancelled (review of 12.39 B2, Fix 1).
                let cancelledByUser = token.isCancelled
                let progressWindow = progress.window
                if window.attachedSheet === progressWindow {
                    window.endSheet(progressWindow)
                }
                guard let self else { return }
                self.exportButton.isEnabled = true
                switch result {
                case .success(let value):
                    if cancelledByUser {
                        if let selection = value.1.selection {
                            try? FileManager.default.removeItem(at: URL(fileURLWithPath: selection).deletingLastPathComponent())
                        }
                        return
                    }
                    self.startAnnotationTableExport(invocation: value.1, rowCount: value.0)
                case .failure(let error):
                    if error is CancellationError || cancelledByUser { return }
                    self.presentScientificExportError(error)
                }
            }
        }
    }

    /// Begins the export's row. Its end shows the base's words, "Exported N rows to <file>" on the drawer's label,
    /// or "Could not export the table", with the leaf's message behind Show Details.
    private func startAnnotationTableExport(invocation: ViewerExportInvocation, rowCount: Int) {
        let fileName = URL(fileURLWithPath: invocation.output).lastPathComponent
        guard let begun = Self.beginAnnotationTableExportOperation(
            invocation: invocation, rowCount: rowCount,
            onFailure: { [weak self] failure in
                self?.presentScientificExportError(AnnotationTableExportLeafFailure(message: failure.message))
            }
        ) else { return }
        Task { @MainActor [weak self] in
            if case .completed = await begun.task.value {
                self?.queryProgressLabel.stringValue = "Exported \(rowCount) rows to \(fileName)"
            }
        }
    }

    private func presentScientificExportError(_ error: Error) {
        guard let window else { return }
        FailurePresenter.present(ViewerFailureReports.exportTable(error), in: window)
    }
}
