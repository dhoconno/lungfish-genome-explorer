// ProjectMetadataExportImport.swift - Project-level FASTQ metadata CSV export/import
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.lungfish.app", category: "ProjectMetadataExportImport")

// MARK: - MetadataExportSheet

/// Sheet presenting a sample picker for CSV metadata export.
///
/// Shows all `.lungfishfastq` bundles discovered under a project folder
/// with checkboxes. The user selects which samples to include, then
/// saves to a CSV file via `NSSavePanel`.
@MainActor
final class MetadataExportSheet: NSViewController {

    // MARK: - Properties

    private let folderURL: URL
    private var discoveredSamples: [(name: String, url: URL, metadata: FASTQSampleMetadata)] = []
    private var selectedIndices: Set<Int> = []

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")

    // MARK: - Init

    init(folderURL: URL) {
        self.folderURL = folderURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 450))

        // Title
        let titleLabel = NSTextField(labelWithString: "Export Sample Metadata")
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Subtitle
        let subtitleLabel = NSTextField(wrappingLabelWithString: "Select which FASTQ samples to include in the exported CSV. Metadata from all selected samples will be merged into a single file.")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        // Select All / Deselect All buttons
        let selectAllButton = NSButton(title: "Select All", target: self, action: #selector(selectAllSamples(_:)))
        selectAllButton.controlSize = .small
        selectAllButton.bezelStyle = .accessoryBarAction
        let deselectAllButton = NSButton(title: "Deselect All", target: self, action: #selector(deselectAllSamples(_:)))
        deselectAllButton.controlSize = .small
        deselectAllButton.bezelStyle = .accessoryBarAction

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        let topBar = NSStackView(views: [selectAllButton, deselectAllButton, countLabel])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topBar)

        // Table
        setupTableView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Buttons
        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.controlSize = .regular
        cancelButton.keyEquivalent = "\u{1b}"
        let exportButton = NSButton(title: "Export CSV\u{2026}", target: self, action: #selector(exportCSV(_:)))
        exportButton.controlSize = .regular
        exportButton.keyEquivalent = "\r"
        exportButton.bezelStyle = .push

        buttonStack.addArrangedSubview(spacer)
        buttonStack.addArrangedSubview(cancelButton)
        buttonStack.addArrangedSubview(exportButton)
        container.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            topBar.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),

            buttonStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            buttonStack.heightAnchor.constraint(equalToConstant: 30),

            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 10),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        discoverSamples()
    }

    // MARK: - Table Setup

    private func setupTableView() {
        // Checkbox column
        let checkCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("check"))
        checkCol.title = ""
        checkCol.width = 30
        checkCol.minWidth = 30
        checkCol.maxWidth = 30
        tableView.addTableColumn(checkCol)

        // Sample name column
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sample_name"))
        nameCol.title = "Sample Name"
        nameCol.width = 200
        nameCol.minWidth = 100
        tableView.addTableColumn(nameCol)

        // Template column
        let templateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("template"))
        templateCol.title = "Template"
        templateCol.width = 120
        templateCol.minWidth = 60
        tableView.addTableColumn(templateCol)

        // Collection date column
        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("collection_date"))
        dateCol.title = "Collection Date"
        dateCol.width = 110
        dateCol.minWidth = 60
        tableView.addTableColumn(dateCol)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 22
        tableView.headerView = NSTableHeaderView()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
    }

    // MARK: - Sample Discovery

    private func discoverSamples() {
        discoveredSamples = discoverFASTQSamples(under: folderURL)

        // Select all by default
        selectedIndices = Set(0..<discoveredSamples.count)

        tableView.reloadData()
        updateCountLabel()
        logger.info("Discovered \(self.discoveredSamples.count) FASTQ samples under \(self.folderURL.lastPathComponent)")
    }

    private func updateCountLabel() {
        countLabel.stringValue = "\(selectedIndices.count) of \(discoveredSamples.count) selected"
    }

    // MARK: - Actions

    @objc private func selectAllSamples(_ sender: Any?) {
        selectedIndices = Set(0..<discoveredSamples.count)
        tableView.reloadData()
        updateCountLabel()
    }

    @objc private func deselectAllSamples(_ sender: Any?) {
        selectedIndices.removeAll()
        tableView.reloadData()
        updateCountLabel()
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(nil)
    }

    @objc private func exportCSV(_ sender: Any?) {
        guard !selectedIndices.isEmpty else {
            NSSound.beep()
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(folderURL.lastPathComponent)_metadata.csv"

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.performExport(to: url)
                }
            }
        }
    }

    private func performExport(to url: URL) {
        let samples = selectedIndices.sorted().compactMap { idx -> FASTQSampleMetadata? in
            guard idx < discoveredSamples.count else { return nil }
            return discoveredSamples[idx].metadata
        }

        let csv = FASTQSampleMetadata.serializeMultiSampleCSV(samples)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            logger.info("Exported metadata for \(samples.count) samples to \(url.lastPathComponent)")
            dismiss(nil)
        } catch {
            logger.error("Failed to export metadata CSV: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window = view.window {
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func toggleCheckbox(_ sender: NSButton) {
        let row = sender.tag
        if sender.state == .on {
            selectedIndices.insert(row)
        } else {
            selectedIndices.remove(row)
        }
        updateCountLabel()
    }
}

// MARK: - NSTableViewDataSource

extension MetadataExportSheet: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        discoveredSamples.count
    }
}

// MARK: - NSTableViewDelegate

extension MetadataExportSheet: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnID = tableColumn?.identifier.rawValue,
              row < discoveredSamples.count else { return nil }

        let sample = discoveredSamples[row]

        if columnID == "check" {
            let cellID = NSUserInterfaceItemIdentifier("CheckboxCell")
            let cellView: NSView

            if let existing = tableView.makeView(withIdentifier: cellID, owner: self) {
                cellView = existing
                if let checkbox = cellView.subviews.first as? NSButton {
                    checkbox.state = selectedIndices.contains(row) ? .on : .off
                    checkbox.tag = row
                }
            } else {
                let container = NSView()
                container.identifier = cellID
                let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCheckbox(_:)))
                checkbox.translatesAutoresizingMaskIntoConstraints = false
                checkbox.tag = row
                checkbox.state = selectedIndices.contains(row) ? .on : .off
                container.addSubview(checkbox)
                NSLayoutConstraint.activate([
                    checkbox.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                    checkbox.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                ])
                cellView = container
            }
            return cellView
        }

        let cellID = NSUserInterfaceItemIdentifier("ExportCell_\(columnID)")
        let cellView: NSTableCellView

        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = cellID
            let textField = NSTextField(labelWithString: "")
            textField.font = .systemFont(ofSize: 12)
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(textField)
            cellView.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        let value: String
        switch columnID {
        case "sample_name":
            value = sample.metadata.sampleName
        case "template":
            value = sample.metadata.metadataTemplate?.displayLabel ?? ""
        case "collection_date":
            value = sample.metadata.collectionDate ?? ""
        default:
            value = sample.metadata.value(forCSVHeader: columnID) ?? ""
        }
        cellView.textField?.stringValue = value

        return cellView
    }
}

// MARK: - MetadataImportSheet

/// Sheet presenting a preview of CSV metadata import results.
///
/// Parses an imported CSV, matches rows to existing FASTQ bundles by
/// `sample_name` (case-insensitive), and shows a summary of what will
/// be updated before the user confirms.
@MainActor
final class MetadataImportSheet: NSViewController {

    // MARK: - Properties

    private let folderURL: URL
    private var existingSamples: [String: FASTQSampleMetadata] = [:]
    private var existingOrder: [String] = []

    /// Rows parsed from the imported CSV.
    private var importedRows: [FASTQSampleMetadata] = []
    /// Match results: (imported row, matching existing name or nil, status description).
    private var matchResults: [(imported: FASTQSampleMetadata, existingKey: String?, status: String)] = []

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let summaryLabel = NSTextField(labelWithString: "")

    private var csvURL: URL?

    // MARK: - Init

    init(folderURL: URL) {
        self.folderURL = folderURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 450))

        // Title
        let titleLabel = NSTextField(labelWithString: "Import Sample Metadata")
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Summary
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(summaryLabel)

        // Table
        setupTableView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Buttons
        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let chooseFileButton = NSButton(title: "Choose CSV\u{2026}", target: self, action: #selector(chooseFile(_:)))
        chooseFileButton.controlSize = .regular
        let spacer = NSView()
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.controlSize = .regular
        cancelButton.keyEquivalent = "\u{1b}"
        let importButton = NSButton(title: "Import", target: self, action: #selector(performImport(_:)))
        importButton.controlSize = .regular
        importButton.keyEquivalent = "\r"
        importButton.bezelStyle = .push

        buttonStack.addArrangedSubview(chooseFileButton)
        buttonStack.addArrangedSubview(spacer)
        buttonStack.addArrangedSubview(cancelButton)
        buttonStack.addArrangedSubview(importButton)
        container.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            summaryLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),

            buttonStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            buttonStack.heightAnchor.constraint(equalToConstant: 30),

            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 10),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadExistingSamples()
        summaryLabel.stringValue = "Choose a CSV file to preview the import."
    }

    // MARK: - Table Setup

    private func setupTableView() {
        let statusCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusCol.title = "Status"
        statusCol.width = 100
        statusCol.minWidth = 60
        tableView.addTableColumn(statusCol)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sample_name"))
        nameCol.title = "Sample Name"
        nameCol.width = 180
        nameCol.minWidth = 100
        tableView.addTableColumn(nameCol)

        let templateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("template"))
        templateCol.title = "Template"
        templateCol.width = 120
        templateCol.minWidth = 60
        tableView.addTableColumn(templateCol)

        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("collection_date"))
        dateCol.title = "Collection Date"
        dateCol.width = 110
        dateCol.minWidth = 60
        tableView.addTableColumn(dateCol)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 22
        tableView.headerView = NSTableHeaderView()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
    }

    // MARK: - Data Loading

    private func loadExistingSamples() {
        let resolved = FASTQFolderMetadata.loadResolved(from: folderURL)
        existingSamples = resolved.samples
        existingOrder = resolved.sampleOrder
    }

    private func parseAndPreview(csvURL: URL) {
        do {
            let content = try String(contentsOf: csvURL, encoding: .utf8)
            guard let parsed = FASTQSampleMetadata.parseMultiSampleCSV(content) else {
                summaryLabel.stringValue = "Failed to parse CSV file. Ensure it has a header row."
                matchResults = []
                tableView.reloadData()
                return
            }

            importedRows = parsed
            matchResults = []

            // Build case-insensitive lookup of existing names
            var lowerToKey: [String: String] = [:]
            for key in existingSamples.keys {
                lowerToKey[key.lowercased()] = key
            }

            var updateCount = 0
            var newCount = 0

            for row in parsed {
                let lowerName = row.sampleName.lowercased()
                if let existingKey = lowerToKey[lowerName] {
                    matchResults.append((imported: row, existingKey: existingKey, status: "Update"))
                    updateCount += 1
                } else {
                    matchResults.append((imported: row, existingKey: nil, status: "Not found"))
                    newCount += 1
                }
            }

            let skippedCount = existingSamples.count - updateCount
            summaryLabel.stringValue = "\(updateCount) sample(s) will be updated, \(newCount) not found in project, \(skippedCount) existing sample(s) unchanged."

            tableView.reloadData()
            logger.info("Import preview: \(updateCount) updates, \(newCount) not found, \(skippedCount) unchanged")

        } catch {
            summaryLabel.stringValue = "Error reading file: \(error.localizedDescription)"
            matchResults = []
            tableView.reloadData()
        }
    }

    // MARK: - Actions

    @objc private func chooseFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a CSV file with sample metadata"

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.csvURL = url
                    self.parseAndPreview(csvURL: url)
                }
            }
        }
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(nil)
    }

    @objc private func performImport(_ sender: Any?) {
        let updatable = matchResults.filter { $0.existingKey != nil }
        guard !updatable.isEmpty else {
            NSSound.beep()
            return
        }

        // Apply updates: only overwrite fields that have values in the CSV
        var updatedMeta = existingSamples

        for match in updatable {
            guard let existingKey = match.existingKey,
                  var existing = updatedMeta[existingKey] else { continue }

            let imported = match.imported

            // Update each canonical field only if the imported value is non-empty
            for mapping in FASTQSampleMetadata.columnMapping {
                let header = mapping.csvHeaders[0]
                if let importedValue = imported.value(forCSVHeader: header),
                   !importedValue.isEmpty {
                    existing.setValue(importedValue, forCSVHeader: header)
                }
            }

            // Merge custom fields (only non-empty values)
            for (key, value) in imported.customFields where !value.isEmpty {
                existing.customFields[key] = value
            }

            updatedMeta[existingKey] = existing
        }

        // Save
        let orderedSamples = existingOrder.compactMap { updatedMeta[$0] }
        let folderMeta = FASTQFolderMetadata(orderedSamples: orderedSamples)

        do {
            try FASTQFolderMetadata.saveWithPerBundleSync(folderMeta, to: folderURL)
            logger.info("Imported metadata updates for \(updatable.count) samples")

            NotificationCenter.default.post(
                name: .sampleMetadataDidChange,
                object: self,
                userInfo: ["folderURL": folderURL]
            )

            dismiss(nil)
        } catch {
            logger.error("Failed to save imported metadata: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Import Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window = view.window {
                alert.beginSheetModal(for: window)
            }
        }
    }
}

// MARK: - NSTableViewDataSource

extension MetadataImportSheet: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        matchResults.count
    }
}

// MARK: - NSTableViewDelegate

extension MetadataImportSheet: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnID = tableColumn?.identifier.rawValue,
              row < matchResults.count else { return nil }

        let match = matchResults[row]
        let cellID = NSUserInterfaceItemIdentifier("ImportCell_\(columnID)")
        let cellView: NSTableCellView

        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = cellID
            let textField = NSTextField(labelWithString: "")
            textField.font = .systemFont(ofSize: 12)
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(textField)
            cellView.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        let value: String
        switch columnID {
        case "status":
            value = match.status
            cellView.textField?.textColor = match.existingKey != nil ? .systemGreen : .secondaryLabelColor
        case "sample_name":
            value = match.imported.sampleName
            cellView.textField?.textColor = .labelColor
        case "template":
            value = match.imported.metadataTemplate?.displayLabel ?? ""
            cellView.textField?.textColor = .labelColor
        case "collection_date":
            value = match.imported.collectionDate ?? ""
            cellView.textField?.textColor = .labelColor
        default:
            value = ""
            cellView.textField?.textColor = .labelColor
        }
        cellView.textField?.stringValue = value

        return cellView
    }
}

// MARK: - FASTQ Sample Discovery Helper

/// Recursively discovers all `.lungfishfastq` bundles under a folder and loads
/// their metadata (per-bundle or folder-level, with resolution).
@MainActor
func discoverFASTQSamples(under folderURL: URL) -> [(name: String, url: URL, metadata: FASTQSampleMetadata)] {
    let fm = FileManager.default
    var results: [(name: String, url: URL, metadata: FASTQSampleMetadata)] = []

    // First, load resolved metadata at this folder level
    let resolved = FASTQFolderMetadata.loadResolved(from: folderURL)
    for name in resolved.sampleOrder {
        let bundleName = name.hasSuffix(".lungfishfastq") ? name : "\(name).lungfishfastq"
        let bundleURL = folderURL.appendingPathComponent(bundleName)
        if let meta = resolved.samples[name] {
            results.append((name: name, url: bundleURL, metadata: meta))
        }
    }

    // Recurse into subfolders
    guard let contents = try? fm.contentsOfDirectory(atPath: folderURL.path) else {
        return results
    }
    let existingNames = Set(results.map { $0.name })

    for item in contents.sorted() {
        if item.hasSuffix(".lungfishfastq") { continue } // Already handled
        if item.hasPrefix(".") { continue }

        let itemURL = folderURL.appendingPathComponent(item)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: itemURL.path, isDirectory: &isDir), isDir.boolValue {
            let subResults = discoverFASTQSamples(under: itemURL)
            for sub in subResults where !existingNames.contains(sub.name) {
                results.append(sub)
            }
        }
    }

    return results
}
