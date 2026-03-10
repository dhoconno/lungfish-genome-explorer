// BarcodeScoutSheet.swift - Modal sheet for reviewing barcode scout results
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

/// Callback invoked when the user clicks "Proceed" with accepted barcodes.
///
/// Parameters:
/// - Accepted detections (user may have edited sample names and dispositions).
/// - The full (possibly mutated) scout result for persistence.
public typealias BarcodeScoutSheetCompletion = @MainActor (
    _ acceptedDetections: [BarcodeDetection],
    _ result: BarcodeScoutResult
) -> Void

/// Modal sheet that displays barcode scout results for user review.
///
/// The user can:
/// - Toggle each barcode's disposition (accepted / rejected / undecided)
/// - Edit sample names inline
/// - Apply auto-accept/reject thresholds
/// - Proceed with only the accepted barcodes
@MainActor
public final class BarcodeScoutSheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - State

    private var scoutResult: BarcodeScoutResult
    private let kitDisplayName: String
    private let onProceed: BarcodeScoutSheetCompletion?
    private let onCancel: (() -> Void)?

    // MARK: - UI

    private let headerLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let acceptThresholdField = NSTextField(string: "10")
    private let rejectThresholdField = NSTextField(string: "3")
    private let applyThresholdsButton = NSButton(title: "Apply Thresholds", target: nil, action: nil)
    private let proceedButton = NSButton(title: "Proceed with Accepted Barcodes", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // Column identifiers
    private enum Column: String {
        case status = "status"
        case barcode = "barcode"
        case hits = "hits"
        case percentage = "percentage"
        case editDistance = "editDistance"
        case sampleName = "sampleName"
    }

    // MARK: - Init

    public init(
        scoutResult: BarcodeScoutResult,
        kitDisplayName: String,
        onProceed: BarcodeScoutSheetCompletion? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.scoutResult = scoutResult
        self.kitDisplayName = kitDisplayName
        self.onProceed = onProceed
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container
        setupUI()
        updateHeader()
    }

    // MARK: - Layout

    private func setupUI() {
        // Header
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerLabel)

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryLabel)

        // Table
        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // Bottom bar: threshold controls + action buttons
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        // Threshold controls
        let acceptLabel = NSTextField(labelWithString: "Auto-accept hits \u{2265}")
        acceptLabel.font = .systemFont(ofSize: 11)
        acceptLabel.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(acceptLabel)

        acceptThresholdField.font = .systemFont(ofSize: 11)
        acceptThresholdField.translatesAutoresizingMaskIntoConstraints = false
        acceptThresholdField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        bottomBar.addSubview(acceptThresholdField)

        let rejectLabel = NSTextField(labelWithString: "Auto-reject hits \u{2264}")
        rejectLabel.font = .systemFont(ofSize: 11)
        rejectLabel.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(rejectLabel)

        rejectThresholdField.font = .systemFont(ofSize: 11)
        rejectThresholdField.translatesAutoresizingMaskIntoConstraints = false
        rejectThresholdField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        bottomBar.addSubview(rejectThresholdField)

        applyThresholdsButton.bezelStyle = .rounded
        applyThresholdsButton.font = .systemFont(ofSize: 11)
        applyThresholdsButton.target = self
        applyThresholdsButton.action = #selector(applyThresholds)
        applyThresholdsButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(applyThresholdsButton)

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(cancelButton)

        proceedButton.bezelStyle = .rounded
        proceedButton.keyEquivalent = "\r"
        proceedButton.target = self
        proceedButton.action = #selector(proceedClicked)
        proceedButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(proceedButton)

        NSLayoutConstraint.activate([
            // Header
            headerLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            summaryLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            // Table
            scrollView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -8),

            // Bottom bar
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            bottomBar.heightAnchor.constraint(equalToConstant: 32),

            // Threshold controls (left-aligned)
            acceptLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            acceptLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            acceptThresholdField.leadingAnchor.constraint(equalTo: acceptLabel.trailingAnchor, constant: 4),
            acceptThresholdField.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            rejectLabel.leadingAnchor.constraint(equalTo: acceptThresholdField.trailingAnchor, constant: 12),
            rejectLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            rejectThresholdField.leadingAnchor.constraint(equalTo: rejectLabel.trailingAnchor, constant: 4),
            rejectThresholdField.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            applyThresholdsButton.leadingAnchor.constraint(equalTo: rejectThresholdField.trailingAnchor, constant: 8),
            applyThresholdsButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            // Action buttons (right-aligned)
            proceedButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            proceedButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: proceedButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            // Overall size
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 720),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
    }

    private func configureTable() {
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self

        let columns: [(Column, String, CGFloat)] = [
            (.status, "", 44),
            (.barcode, "Barcode", 80),
            (.hits, "Hits", 70),
            (.percentage, "%", 60),
            (.editDistance, "Edit Dist.", 70),
            (.sampleName, "Sample Name", 200),
        ]

        for (id, title, width) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
            col.title = title
            col.width = width
            col.minWidth = id == .sampleName ? 100 : 40
            if id == .sampleName {
                col.resizingMask = .autoresizingMask
            }
            tableView.addTableColumn(col)
        }
    }

    // MARK: - Header

    private func updateHeader() {
        let detected = scoutResult.detections.count
        let accepted = scoutResult.acceptedCount
        let rate = scoutResult.assignmentRate * 100
        let unassigned = 100.0 - rate

        headerLabel.stringValue = "Scanned \(formatCount(scoutResult.readsScanned)) reads in \(String(format: "%.1f", scoutResult.elapsedSeconds))s"
        summaryLabel.stringValue = "\(detected) barcodes detected | \(accepted) accepted | \(String(format: "%.1f", rate))% assigned | \(String(format: "%.1f", unassigned))% unassigned | Kit: \(kitDisplayName)"
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        scoutResult.detections.count
    }

    // MARK: - NSTableViewDelegate

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colID = tableColumn?.identifier.rawValue,
              let column = Column(rawValue: colID),
              row < scoutResult.detections.count else { return nil }

        let detection = scoutResult.detections[row]

        switch column {
        case .status:
            return makeStatusButton(for: detection, row: row)
        case .barcode:
            return makeLabel(detection.barcodeID, alignment: .left)
        case .hits:
            return makeLabel(formatCount(detection.hitCount), alignment: .right)
        case .percentage:
            return makeLabel(String(format: "%.1f%%", detection.hitPercentage), alignment: .right)
        case .editDistance:
            let text = detection.meanEditDistance.map { String(format: "%.1f", $0) } ?? "-"
            let label = makeLabel(text, alignment: .right)
            if let dist = detection.meanEditDistance, dist > 2.0 {
                label.textColor = .systemOrange
            }
            return label
        case .sampleName:
            return makeSampleNameField(for: detection, row: row)
        }
    }

    // MARK: - Cell Factories

    private func makeLabel(_ text: String, alignment: NSTextAlignment) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func makeStatusButton(for detection: BarcodeDetection, row: Int) -> NSView {
        let button = NSButton(frame: .zero)
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.tag = row
        button.target = self
        button.action = #selector(toggleDisposition(_:))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown

        switch detection.disposition {
        case .accepted:
            button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Accepted")
            button.contentTintColor = .systemGreen
        case .rejected:
            button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Rejected")
            button.contentTintColor = .systemRed
        case .undecided:
            button.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Undecided")
            button.contentTintColor = .secondaryLabelColor
        }

        return button
    }

    private func makeSampleNameField(for detection: BarcodeDetection, row: Int) -> NSTextField {
        let field = NSTextField(string: detection.sampleName ?? "")
        field.font = .systemFont(ofSize: 11)
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.placeholderString = "Sample name..."
        field.tag = row
        field.delegate = self
        return field
    }

    // MARK: - Actions

    @objc private func toggleDisposition(_ sender: NSButton) {
        let row = sender.tag
        guard row < scoutResult.detections.count else { return }

        // Cycle: undecided -> accepted -> rejected -> undecided
        let current = scoutResult.detections[row].disposition
        let next: DetectionDisposition
        switch current {
        case .undecided: next = .accepted
        case .accepted: next = .rejected
        case .rejected: next = .undecided
        }
        scoutResult.detections[row].disposition = next
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        updateHeader()
    }

    @objc private func applyThresholds() {
        let acceptMin = Int(acceptThresholdField.stringValue) ?? 10
        let rejectMax = Int(rejectThresholdField.stringValue) ?? 3

        for i in scoutResult.detections.indices {
            if scoutResult.detections[i].hitCount >= acceptMin {
                scoutResult.detections[i].disposition = .accepted
            } else if scoutResult.detections[i].hitCount <= rejectMax {
                scoutResult.detections[i].disposition = .rejected
            } else {
                scoutResult.detections[i].disposition = .undecided
            }
        }
        tableView.reloadData()
        updateHeader()
    }

    @objc private func cancelClicked() {
        onCancel?()
        dismissSheet()
    }

    @objc private func proceedClicked() {
        let accepted = scoutResult.acceptedDetections
        guard !accepted.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Barcodes Accepted"
            alert.informativeText = "Accept at least one barcode before proceeding."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        onProceed?(accepted, scoutResult)
        dismissSheet()
    }

    private func dismissSheet() {
        guard let window = view.window else { return }
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            window.close()
        }
    }

    // MARK: - Formatting

    private func formatCount(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Presentation

    /// Presents this sheet attached to the given window.
    public static func present(
        on window: NSWindow,
        scoutResult: BarcodeScoutResult,
        kitDisplayName: String,
        onProceed: BarcodeScoutSheetCompletion? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        let controller = BarcodeScoutSheet(
            scoutResult: scoutResult,
            kitDisplayName: kitDisplayName,
            onProceed: onProceed,
            onCancel: onCancel
        )

        let sheetWindow = NSWindow(contentViewController: controller)
        sheetWindow.title = "Barcode Scout Results"
        sheetWindow.styleMask = [.titled, .closable, .resizable]
        sheetWindow.isReleasedWhenClosed = false

        window.beginSheet(sheetWindow) { _ in }
    }
}

// MARK: - NSTextFieldDelegate (sample name editing)

extension BarcodeScoutSheet: NSTextFieldDelegate {
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = field.tag
        guard row < scoutResult.detections.count else { return }

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        scoutResult.detections[row].sampleName = text.isEmpty ? nil : text
    }
}
