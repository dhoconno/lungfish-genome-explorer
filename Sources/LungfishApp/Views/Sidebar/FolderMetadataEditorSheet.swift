// FolderMetadataEditorSheet.swift - Folder-level sample metadata table editor
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.app", category: "FolderMetadataEditor")

// MARK: - FolderMetadataEditorSheet

/// Sheet presenting a table editor for folder-level sample metadata.
///
/// Displays one row per `.lungfishfastq` bundle in the folder, with
/// editable columns for PHA4GE-aligned metadata fields. Supports
/// CSV import/export and syncs changes to both `samples.csv` and
/// per-bundle `metadata.csv` files.
@MainActor
final class FolderMetadataEditorSheet: NSViewController {

    // MARK: - Properties

    let folderURL: URL

    private var sampleNames: [String] = []
    private var metadata: [String: FASTQSampleMetadata] = [:]

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /// Columns to display (in order).
    private static let displayColumns: [(id: String, title: String, width: CGFloat)] = [
        ("sample_name", "Sample Name", 140),
        ("sample_role", "Role", 120),
        ("sample_type", "Sample Type", 130),
        ("collection_date", "Collection Date", 110),
        ("geo_loc_name", "Location", 130),
        ("host", "Host", 100),
        ("patient_id", "Patient ID", 90),
        ("run_id", "Run ID", 90),
        ("organism", "Organism", 110),
    ]

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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))

        // Title label
        let titleLabel = NSTextField(labelWithString: "Sample Metadata: \(folderURL.lastPathComponent)")
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Table setup
        setupTableView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Buttons
        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let importButton = NSButton(title: "Import CSV\u{2026}", target: self, action: #selector(importCSV(_:)))
        importButton.controlSize = .regular
        let exportButton = NSButton(title: "Export CSV\u{2026}", target: self, action: #selector(exportCSV(_:)))
        exportButton.controlSize = .regular
        let spacer = NSView()
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.controlSize = .regular
        cancelButton.keyEquivalent = "\u{1b}" // Escape key
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        saveButton.controlSize = .regular
        saveButton.keyEquivalent = "\r" // Return key
        saveButton.bezelStyle = .push

        buttonStack.addArrangedSubview(importButton)
        buttonStack.addArrangedSubview(exportButton)
        buttonStack.addArrangedSubview(spacer)
        buttonStack.addArrangedSubview(cancelButton)
        buttonStack.addArrangedSubview(saveButton)
        container.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
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
        loadMetadata()
    }

    // MARK: - Table Setup

    private func setupTableView() {
        for colDef in Self.displayColumns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colDef.id))
            column.title = colDef.title
            column.width = colDef.width
            column.minWidth = 60
            column.isEditable = true
            tableView.addTableColumn(column)
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 22
        tableView.headerView = NSTableHeaderView()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
    }

    // MARK: - Data Loading

    private func loadMetadata() {
        let resolved = FASTQFolderMetadata.loadResolved(from: folderURL)
        sampleNames = resolved.sampleOrder
        metadata = resolved.samples
        tableView.reloadData()
        logger.info("Loaded metadata for \(self.sampleNames.count) samples from \(self.folderURL.lastPathComponent)")
    }

    // MARK: - Actions

    @objc private func save(_ sender: Any?) {
        let orderedSamples = sampleNames.compactMap { metadata[$0] }
        let folderMeta = FASTQFolderMetadata(orderedSamples: orderedSamples)

        do {
            try FASTQFolderMetadata.saveWithPerBundleSync(folderMeta, to: folderURL)
            logger.info("Saved folder metadata for \(self.sampleNames.count) samples")

            // Post notification for open viewers to refresh
            NotificationCenter.default.post(
                name: .sampleMetadataDidChange,
                object: self,
                userInfo: ["folderURL": folderURL]
            )
        } catch {
            logger.error("Failed to save folder metadata: \(error.localizedDescription)")
        }

        dismiss(nil)
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(nil)
    }

    @objc private func importCSV(_ sender: Any?) {
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
                    self.performImport(from: url)
                }
            }
        }
    }

    private func performImport(from csvURL: URL) {
        do {
            let content = try String(contentsOf: csvURL, encoding: .utf8)
            guard let imported = FASTQFolderMetadata.parse(csv: content) else {
                logger.warning("Failed to parse imported CSV")
                return
            }

            // Merge: update existing samples, add new ones
            for (name, meta) in imported.samples {
                metadata[name] = meta
                if !sampleNames.contains(name) {
                    sampleNames.append(name)
                }
            }

            tableView.reloadData()
            logger.info("Imported metadata for \(imported.samples.count) samples from CSV")
        } catch {
            logger.error("Failed to import CSV: \(error.localizedDescription)")
        }
    }

    @objc private func exportCSV(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "samples.csv"

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let orderedSamples = self.sampleNames.compactMap { self.metadata[$0] }
                    let csv = FASTQSampleMetadata.serializeMultiSampleCSV(orderedSamples)
                    do {
                        try csv.write(to: url, atomically: true, encoding: .utf8)
                        logger.info("Exported metadata to \(url.lastPathComponent)")
                    } catch {
                        logger.error("Failed to export CSV: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

// MARK: - NSTableViewDataSource

extension FolderMetadataEditorSheet: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        sampleNames.count
    }
}

// MARK: - NSTableViewDelegate

extension FolderMetadataEditorSheet: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnID = tableColumn?.identifier.rawValue,
              row < sampleNames.count else { return nil }

        let sampleName = sampleNames[row]
        guard let meta = metadata[sampleName] else { return nil }

        let cellID = NSUserInterfaceItemIdentifier("MetadataCell_\(columnID)")
        let cellView: NSTableCellView

        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = cellID
            let textField = NSTextField()
            textField.isBordered = false
            textField.backgroundColor = .clear
            textField.isEditable = true
            textField.font = .systemFont(ofSize: 12)
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.delegate = self
            cellView.addSubview(textField)
            cellView.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        let value = meta.value(forCSVHeader: columnID) ?? ""
        cellView.textField?.stringValue = value
        cellView.textField?.tag = row

        return cellView
    }
}

// MARK: - NSTextFieldDelegate

extension FolderMetadataEditorSheet: NSTextFieldDelegate {

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let textField = notification.object as? NSTextField else { return }
        let row = textField.tag
        guard row < sampleNames.count else { return }

        // Find which column this textfield belongs to
        let column = tableView.column(for: textField)
        guard column >= 0, column < Self.displayColumns.count else { return }

        let columnID = Self.displayColumns[column].id
        let sampleName = sampleNames[row]

        guard var meta = metadata[sampleName] else { return }
        meta.setValue(textField.stringValue, forCSVHeader: columnID)

        // If sample_name changed, update the key
        if columnID == "sample_name" && textField.stringValue != sampleName {
            let newName = textField.stringValue
            metadata.removeValue(forKey: sampleName)
            meta.sampleName = newName
            metadata[newName] = meta
            if let index = sampleNames.firstIndex(of: sampleName) {
                sampleNames[index] = newName
            }
        } else {
            metadata[sampleName] = meta
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when sample metadata has been edited at the folder level.
    static let sampleMetadataDidChange = Notification.Name("sampleMetadataDidChange")
}
