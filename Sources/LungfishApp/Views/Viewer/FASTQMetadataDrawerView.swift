// FASTQMetadataDrawerView.swift - Bottom drawer for FASTQ sample/barcode metadata
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow

@MainActor
public protocol FASTQMetadataDrawerViewDelegate: AnyObject {
    func fastqMetadataDrawerViewDidSave(
        _ drawer: FASTQMetadataDrawerView,
        fastqURL: URL?,
        metadata: FASTQDemultiplexMetadata
    )
    func fastqMetadataDrawerViewDidRequestScout(
        _ drawer: FASTQMetadataDrawerView,
        step: DemultiplexStep
    )
}

// Default no-op for scout so existing conformers don't break.
public extension FASTQMetadataDrawerViewDelegate {
    func fastqMetadataDrawerViewDidRequestScout(
        _ drawer: FASTQMetadataDrawerView,
        step: DemultiplexStep
    ) {}
}

@MainActor
public final class FASTQMetadataDrawerView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private enum Tab: Int {
        case samples = 0
        case demuxSetup = 1
        case barcodeKits = 2
    }

    // Tag constants for distinguishing table views in data source/delegate
    private static let mainTableTag = 100
    private static let kitDetailTableTag = 101
    private static let stepTableTag = 102

    private var isSuppressingDelegateCallbacks = false

    private weak var delegate: FASTQMetadataDrawerViewDelegate?

    private var fastqURL: URL?
    private var activeTab: Tab = .samples
    private var sampleAssignments: [FASTQSampleBarcodeAssignment] = []
    private var customBarcodeSets: [BarcodeKitDefinition] = []
    private var preferredBarcodeSetID: String?
    private var preferredSetIDByPopupIndex: [Int: String] = [:]

    // Demux Setup state
    private var demuxSteps: [DemultiplexStep] = []
    private var compositeSampleNames: [String: String] = [:]
    private var selectedStepIndex: Int = -1

    // Barcode Kits detail state
    private var allKits: [BarcodeKitDefinition] = []
    private var selectedKitBarcodes: [BarcodeEntry] = []
    private var selectedKitName: String = ""

    private let headerBar = NSView()
    private let tabControl = NSSegmentedControl()
    private let preferredSetLabel = NSTextField(labelWithString: "Preferred Set:")
    private let preferredSetPopup = NSPopUpButton()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let importButton = NSButton(title: "Import CSV", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export CSV", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    // Shared content area
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let topDivider = NSBox()

    // Barcode Kits detail split
    private let kitDetailScrollView = NSScrollView()
    private let kitDetailTable = NSTableView()
    private let kitDetailLabel = NSTextField(labelWithString: "Select a kit to view its barcodes.")

    // Demux Setup: step list (top) + detail panel (bottom)
    private let stepScrollView = NSScrollView()
    private let stepTable = NSTableView()
    private let stepDetailContainer = NSView()
    private let stepDetailSeparator = NSBox()
    private let stepEmptyLabel = NSTextField(labelWithString: "Add a step with + to configure demultiplexing.")
    private let stepKitLabel = NSTextField(labelWithString: "Kit:")
    private let stepKitPopup = NSPopUpButton()
    private let stepLocationLabel = NSTextField(labelWithString: "Location:")
    private let stepLocationControl = NSSegmentedControl()
    private let stepSymmetryLabel = NSTextField(labelWithString: "Symmetry:")
    private let stepSymmetryPopup = NSPopUpButton()
    private let stepErrorLabel = NSTextField(labelWithString: "Error Rate:")
    private let stepErrorRateField = NSTextField(string: "0.15")
    private let stepTrimCheckbox = NSButton(checkboxWithTitle: "Trim barcodes", target: nil, action: nil)
    private let stepScoutButton = NSButton(title: "Detect", target: nil, action: nil)
    private let stepAddButton = NSButton(title: "+", target: nil, action: nil)
    private let stepRemoveButton = NSButton(title: "−", target: nil, action: nil)

    // Constraint groups toggled per-tab
    private var samplesConstraints: [NSLayoutConstraint] = []
    private var demuxSetupConstraints: [NSLayoutConstraint] = []
    private var barcodeKitsConstraints: [NSLayoutConstraint] = []

    public init(delegate: FASTQMetadataDrawerViewDelegate? = nil) {
        self.delegate = delegate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        allKits = BarcodeKitRegistry.builtinKits()
        setupUI()
        rebuildColumns()
    }

    public override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func setDelegate(_ delegate: FASTQMetadataDrawerViewDelegate?) {
        self.delegate = delegate
    }

    public func configure(fastqURL: URL?, metadata: FASTQDemultiplexMetadata?) {
        self.fastqURL = fastqURL
        if let metadata {
            sampleAssignments = metadata.sampleAssignments
            customBarcodeSets = metadata.customBarcodeSets
            preferredBarcodeSetID = metadata.preferredBarcodeSetID
        } else {
            sampleAssignments = []
            customBarcodeSets = []
            preferredBarcodeSetID = nil
        }
        allKits = BarcodeKitRegistry.builtinKits() + customBarcodeSets
        rebuildPreferredSetPopup()
        tableView.reloadData()
        statusLabel.stringValue = sampleAssignments.isEmpty
            ? "No FASTQ sample metadata loaded."
            : "Loaded \(sampleAssignments.count) sample assignment(s)."
    }

    public func currentMetadata() -> FASTQDemultiplexMetadata {
        FASTQDemultiplexMetadata(
            sampleAssignments: sampleAssignments,
            customBarcodeSets: customBarcodeSets,
            preferredBarcodeSetID: preferredBarcodeSetID
        )
    }

    /// Returns the current demux plan built from the Demux Setup tab.
    public func currentDemuxPlan() -> DemultiplexPlan {
        DemultiplexPlan(steps: demuxSteps, compositeSampleNames: compositeSampleNames)
    }

    /// Programmatically selects the Demux Setup tab.
    public func selectDemuxSetupTab() {
        tabControl.selectedSegment = Tab.demuxSetup.rawValue
        activeTab = .demuxSetup
        rebuildColumns()
    }

    // MARK: - Setup UI

    private func setupUI() {
        topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topDivider)

        headerBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBar)

        // 3-segment tab control
        tabControl.segmentCount = 3
        tabControl.setLabel("Samples", forSegment: 0)
        tabControl.setLabel("Demux Setup", forSegment: 1)
        tabControl.setLabel("Barcode Kits", forSegment: 2)
        tabControl.selectedSegment = 0
        tabControl.segmentStyle = .texturedRounded
        tabControl.controlSize = .small
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        headerBar.addSubview(tabControl)

        preferredSetLabel.font = .systemFont(ofSize: 11, weight: .medium)
        preferredSetLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(preferredSetLabel)

        preferredSetPopup.controlSize = .small
        preferredSetPopup.translatesAutoresizingMaskIntoConstraints = false
        preferredSetPopup.target = self
        preferredSetPopup.action = #selector(preferredSetChanged(_:))
        headerBar.addSubview(preferredSetPopup)

        for button in [addButton, removeButton, importButton, exportButton, saveButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
            headerBar.addSubview(button)
        }
        addButton.target = self
        addButton.action = #selector(addClicked(_:))
        removeButton.target = self
        removeButton.action = #selector(removeClicked(_:))
        importButton.target = self
        importButton.action = #selector(importClicked(_:))
        exportButton.target = self
        exportButton.action = #selector(exportClicked(_:))
        saveButton.target = self
        saveButton.action = #selector(saveClicked(_:))

        // Accessibility
        tabControl.setAccessibilityLabel("Metadata tab selector")
        addButton.setAccessibilityLabel("Add sample")
        removeButton.setAccessibilityLabel("Remove selected")
        importButton.setAccessibilityLabel("Import CSV file")
        exportButton.setAccessibilityLabel("Export CSV file")
        saveButton.setAccessibilityLabel("Save metadata")
        preferredSetPopup.setAccessibilityLabel("Preferred barcode set")
        tableView.setAccessibilityLabel("Sample assignments")

        // Main table (Samples tab + Barcode Kits list)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        addSubview(scrollView)

        tableView.tag = Self.mainTableTag
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView

        // Kit detail table (Barcode Kits tab bottom half)
        kitDetailScrollView.translatesAutoresizingMaskIntoConstraints = false
        kitDetailScrollView.hasVerticalScroller = true
        kitDetailScrollView.autohidesScrollers = true
        addSubview(kitDetailScrollView)

        kitDetailTable.tag = Self.kitDetailTableTag
        kitDetailTable.headerView = NSTableHeaderView()
        kitDetailTable.usesAlternatingRowBackgroundColors = true
        kitDetailTable.rowHeight = 22
        kitDetailTable.dataSource = self
        kitDetailTable.delegate = self
        kitDetailScrollView.documentView = kitDetailTable

        kitDetailLabel.font = .systemFont(ofSize: 11)
        kitDetailLabel.textColor = .secondaryLabelColor
        kitDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(kitDetailLabel)

        // Demux Setup: step list table
        stepScrollView.translatesAutoresizingMaskIntoConstraints = false
        stepScrollView.hasVerticalScroller = true
        stepScrollView.autohidesScrollers = true
        addSubview(stepScrollView)

        stepTable.tag = Self.stepTableTag
        stepTable.headerView = NSTableHeaderView()
        stepTable.usesAlternatingRowBackgroundColors = true
        stepTable.rowHeight = 24
        stepTable.dataSource = self
        stepTable.delegate = self
        stepScrollView.documentView = stepTable

        setupStepTableColumns()

        // Step detail panel
        stepDetailContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stepDetailContainer)
        setupStepDetailPanel()

        // Step list buttons
        for btn in [stepAddButton, stepRemoveButton] {
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            btn.translatesAutoresizingMaskIntoConstraints = false
            headerBar.addSubview(btn)
        }
        stepAddButton.target = self
        stepAddButton.action = #selector(addStepClicked(_:))
        stepRemoveButton.target = self
        stepRemoveButton.action = #selector(removeStepClicked(_:))

        // Status bar
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        setupConstraints()
        rebuildPreferredSetPopup()
    }

    private func setupStepTableColumns() {
        addColumn(to: stepTable, id: "stepOrdinal", title: "#", width: 30, editable: false)
        addColumn(to: stepTable, id: "stepLabel", title: "Label", width: 120, editable: true)
        addColumn(to: stepTable, id: "stepKit", title: "Kit", width: 180, editable: false)
        addColumn(to: stepTable, id: "stepSymmetry", title: "Symmetry", width: 90, editable: false)
    }

    private func setupStepDetailPanel() {
        // Visual separator between step list and detail panel
        stepDetailSeparator.boxType = .separator
        stepDetailSeparator.translatesAutoresizingMaskIntoConstraints = false
        stepDetailContainer.addSubview(stepDetailSeparator)

        // Empty state label (shown when no step selected)
        stepEmptyLabel.font = .systemFont(ofSize: 12)
        stepEmptyLabel.textColor = .tertiaryLabelColor
        stepEmptyLabel.alignment = .center
        stepEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        stepDetailContainer.addSubview(stepEmptyLabel)
        NSLayoutConstraint.activate([
            stepDetailSeparator.topAnchor.constraint(equalTo: stepDetailContainer.topAnchor),
            stepDetailSeparator.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor),
            stepDetailSeparator.trailingAnchor.constraint(equalTo: stepDetailContainer.trailingAnchor),
            stepDetailSeparator.heightAnchor.constraint(equalToConstant: 1),

            stepEmptyLabel.centerXAnchor.constraint(equalTo: stepDetailContainer.centerXAnchor),
            stepEmptyLabel.centerYAnchor.constraint(equalTo: stepDetailContainer.centerYAnchor),
        ])

        let labels: [NSTextField] = [stepKitLabel, stepLocationLabel, stepSymmetryLabel, stepErrorLabel]
        for label in labels {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            stepDetailContainer.addSubview(label)
        }

        stepKitPopup.controlSize = .small
        stepKitPopup.translatesAutoresizingMaskIntoConstraints = false
        stepKitPopup.target = self
        stepKitPopup.action = #selector(stepKitChanged(_:))
        stepDetailContainer.addSubview(stepKitPopup)
        rebuildStepKitPopup()

        stepLocationControl.segmentCount = 3
        stepLocationControl.setLabel("5'", forSegment: 0)
        stepLocationControl.setLabel("3'", forSegment: 1)
        stepLocationControl.setLabel("Both", forSegment: 2)
        stepLocationControl.selectedSegment = 2
        stepLocationControl.controlSize = .small
        stepLocationControl.translatesAutoresizingMaskIntoConstraints = false
        stepLocationControl.target = self
        stepLocationControl.action = #selector(stepDetailChanged(_:))
        stepDetailContainer.addSubview(stepLocationControl)

        stepSymmetryPopup.controlSize = .small
        stepSymmetryPopup.translatesAutoresizingMaskIntoConstraints = false
        stepSymmetryPopup.addItems(withTitles: ["Symmetric", "Asymmetric", "Single End"])
        stepSymmetryPopup.target = self
        stepSymmetryPopup.action = #selector(stepDetailChanged(_:))
        stepDetailContainer.addSubview(stepSymmetryPopup)

        stepErrorRateField.controlSize = .small
        stepErrorRateField.translatesAutoresizingMaskIntoConstraints = false
        stepErrorRateField.alignment = .right
        stepErrorRateField.target = self
        stepErrorRateField.action = #selector(stepDetailChanged(_:))
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0.01
        formatter.maximum = 0.50
        formatter.maximumFractionDigits = 2
        stepErrorRateField.formatter = formatter
        stepDetailContainer.addSubview(stepErrorRateField)

        stepTrimCheckbox.controlSize = .small
        stepTrimCheckbox.translatesAutoresizingMaskIntoConstraints = false
        stepTrimCheckbox.state = .on
        stepTrimCheckbox.target = self
        stepTrimCheckbox.action = #selector(stepDetailChanged(_:))
        stepDetailContainer.addSubview(stepTrimCheckbox)

        stepScoutButton.bezelStyle = .rounded
        stepScoutButton.controlSize = .small
        stepScoutButton.translatesAutoresizingMaskIntoConstraints = false
        stepScoutButton.target = self
        stepScoutButton.action = #selector(stepScoutClicked(_:))
        stepDetailContainer.addSubview(stepScoutButton)

        // Accessibility labels for step detail controls
        stepKitPopup.setAccessibilityLabel("Step barcode kit")
        stepLocationControl.setAccessibilityLabel("Barcode location")
        stepSymmetryPopup.setAccessibilityLabel("Barcode symmetry mode")
        stepErrorRateField.setAccessibilityLabel("Error rate")
        stepTrimCheckbox.setAccessibilityLabel("Trim barcodes from reads")
        stepScoutButton.setAccessibilityLabel("Detect barcode matches")
        stepTable.setAccessibilityLabel("Demultiplexing steps")
        stepAddButton.setAccessibilityLabel("Add demux step")
        stepRemoveButton.setAccessibilityLabel("Remove demux step")
        kitDetailTable.setAccessibilityLabel("Barcode sequences")

        // Layout within detail panel — two-column grid that stays within container bounds
        // Row 1: Kit label + popup
        // Row 2: Location label + segmented control
        // Row 3: Symmetry label + popup, Error rate label + field
        // Row 4: Trim checkbox + Scout button

        // Allow popups to compress below their preferred width when space is tight
        stepKitPopup.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        stepSymmetryPopup.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let kitMinWidth = stepKitPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140)
        kitMinWidth.priority = .defaultHigh
        let symMinWidth = stepSymmetryPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        symMinWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // Row 1: Kit
            stepKitLabel.topAnchor.constraint(equalTo: stepDetailSeparator.bottomAnchor, constant: 6),
            stepKitLabel.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),
            stepKitPopup.centerYAnchor.constraint(equalTo: stepKitLabel.centerYAnchor),
            stepKitPopup.leadingAnchor.constraint(equalTo: stepKitLabel.trailingAnchor, constant: 4),
            kitMinWidth,
            stepKitPopup.trailingAnchor.constraint(lessThanOrEqualTo: stepDetailContainer.trailingAnchor, constant: -8),

            // Row 2: Location
            stepLocationLabel.topAnchor.constraint(equalTo: stepKitLabel.bottomAnchor, constant: 8),
            stepLocationLabel.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),
            stepLocationControl.centerYAnchor.constraint(equalTo: stepLocationLabel.centerYAnchor),
            stepLocationControl.leadingAnchor.constraint(equalTo: stepLocationLabel.trailingAnchor, constant: 4),
            stepLocationControl.trailingAnchor.constraint(lessThanOrEqualTo: stepDetailContainer.trailingAnchor, constant: -8),

            // Row 3: Symmetry + Error Rate (below Location row)
            stepSymmetryLabel.topAnchor.constraint(equalTo: stepLocationLabel.bottomAnchor, constant: 8),
            stepSymmetryLabel.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),
            stepSymmetryPopup.centerYAnchor.constraint(equalTo: stepSymmetryLabel.centerYAnchor),
            stepSymmetryPopup.leadingAnchor.constraint(equalTo: stepSymmetryLabel.trailingAnchor, constant: 4),
            symMinWidth,

            stepErrorLabel.centerYAnchor.constraint(equalTo: stepSymmetryLabel.centerYAnchor),
            stepErrorLabel.leadingAnchor.constraint(equalTo: stepSymmetryPopup.trailingAnchor, constant: 16),
            stepErrorRateField.centerYAnchor.constraint(equalTo: stepErrorLabel.centerYAnchor),
            stepErrorRateField.leadingAnchor.constraint(equalTo: stepErrorLabel.trailingAnchor, constant: 4),
            stepErrorRateField.widthAnchor.constraint(equalToConstant: 50),
            stepErrorRateField.trailingAnchor.constraint(lessThanOrEqualTo: stepDetailContainer.trailingAnchor, constant: -8),

            // Row 4: Trim + Scout
            stepTrimCheckbox.topAnchor.constraint(equalTo: stepSymmetryLabel.bottomAnchor, constant: 8),
            stepTrimCheckbox.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),

            stepScoutButton.centerYAnchor.constraint(equalTo: stepTrimCheckbox.centerYAnchor),
            stepScoutButton.leadingAnchor.constraint(equalTo: stepTrimCheckbox.trailingAnchor, constant: 16),
            stepScoutButton.trailingAnchor.constraint(lessThanOrEqualTo: stepDetailContainer.trailingAnchor, constant: -8),
        ])
    }

    private func setupConstraints() {
        // Common/fixed constraints
        NSLayoutConstraint.activate([
            topDivider.topAnchor.constraint(equalTo: topAnchor),
            topDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),

            headerBar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            headerBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            headerBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            headerBar.heightAnchor.constraint(equalToConstant: 28),

            tabControl.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            tabControl.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            preferredSetLabel.leadingAnchor.constraint(equalTo: tabControl.trailingAnchor, constant: 10),
            preferredSetLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            preferredSetPopup.leadingAnchor.constraint(equalTo: preferredSetLabel.trailingAnchor, constant: 6),
            preferredSetPopup.widthAnchor.constraint(equalToConstant: 230),
            preferredSetPopup.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            saveButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            saveButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            exportButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -6),
            exportButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            importButton.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -6),
            importButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            removeButton.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -6),
            removeButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            addButton.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -6),
            addButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            // Step list buttons (used only on Demux Setup tab)
            stepAddButton.leadingAnchor.constraint(equalTo: tabControl.trailingAnchor, constant: 10),
            stepAddButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            stepRemoveButton.leadingAnchor.constraint(equalTo: stepAddButton.trailingAnchor, constant: 4),
            stepRemoveButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        // Samples tab constraints (main table fills content area)
        samplesConstraints = [
            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
        ]

        // Barcode Kits tab constraints (kit list top half, detail table bottom half)
        let kitHeightConstraint = scrollView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.35)
        kitHeightConstraint.priority = NSLayoutConstraint.Priority(749) // Below minimum height
        let kitMinHeightConstraint = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
        kitMinHeightConstraint.priority = .defaultHigh // 750 — wins over multiplier
        let kitDetailMinHeightConstraint = kitDetailScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
        kitDetailMinHeightConstraint.priority = .defaultHigh
        barcodeKitsConstraints = [
            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            kitHeightConstraint,
            kitMinHeightConstraint,

            kitDetailLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            kitDetailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),

            kitDetailScrollView.topAnchor.constraint(equalTo: kitDetailLabel.bottomAnchor, constant: 2),
            kitDetailScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            kitDetailScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            kitDetailScrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            kitDetailMinHeightConstraint,
        ]

        // Demux Setup tab constraints (step list top, detail panel bottom)
        let stepHeightConstraint = stepScrollView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.3)
        stepHeightConstraint.priority = NSLayoutConstraint.Priority(749) // Below minimum height
        let stepMinHeight = stepScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
        stepMinHeight.priority = .defaultHigh // 750 — wins over multiplier
        demuxSetupConstraints = [
            stepScrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 6),
            stepScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stepScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stepMinHeight,
            stepHeightConstraint,

            stepDetailContainer.topAnchor.constraint(equalTo: stepScrollView.bottomAnchor, constant: 4),
            stepDetailContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stepDetailContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stepDetailContainer.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
        ]

        // Start with samples tab active
        NSLayoutConstraint.activate(samplesConstraints)
    }

    // MARK: - Tab Switching

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let newTab = Tab(rawValue: sender.selectedSegment) ?? .samples
        guard newTab != activeTab else { return }
        activeTab = newTab
        rebuildColumns()
    }

    private func updateTabVisibility() {
        // Deactivate all constraint groups
        NSLayoutConstraint.deactivate(samplesConstraints)
        NSLayoutConstraint.deactivate(barcodeKitsConstraints)
        NSLayoutConstraint.deactivate(demuxSetupConstraints)

        // Hide everything first
        scrollView.isHidden = true
        kitDetailScrollView.isHidden = true
        kitDetailLabel.isHidden = true
        stepScrollView.isHidden = true
        stepDetailContainer.isHidden = true

        // Header bar button visibility
        preferredSetLabel.isHidden = true
        preferredSetPopup.isHidden = true
        addButton.isHidden = true
        removeButton.isHidden = true
        importButton.isHidden = true
        exportButton.isHidden = true
        stepAddButton.isHidden = true
        stepRemoveButton.isHidden = true

        switch activeTab {
        case .samples:
            scrollView.isHidden = false
            preferredSetLabel.isHidden = false
            preferredSetPopup.isHidden = false
            addButton.isHidden = false
            removeButton.isHidden = false
            importButton.isHidden = false
            exportButton.isHidden = false
            NSLayoutConstraint.activate(samplesConstraints)

        case .demuxSetup:
            stepScrollView.isHidden = false
            stepDetailContainer.isHidden = false
            stepAddButton.isHidden = false
            stepRemoveButton.isHidden = false
            NSLayoutConstraint.activate(demuxSetupConstraints)
            stepTable.reloadData()
            refreshStepDetail()

        case .barcodeKits:
            scrollView.isHidden = false
            kitDetailScrollView.isHidden = false
            kitDetailLabel.isHidden = false
            importButton.isHidden = false
            removeButton.isHidden = false
            // Reset kit detail to avoid stale state from prior selection
            selectedKitBarcodes = []
            selectedKitName = ""
            kitDetailLabel.stringValue = "Select a kit to view its barcodes."
            kitDetailTable.reloadData()
            NSLayoutConstraint.activate(barcodeKitsConstraints)
        }
    }

    // MARK: - Column Rebuild

    private func rebuildColumns() {
        for column in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(column)
        }
        for column in kitDetailTable.tableColumns.reversed() {
            kitDetailTable.removeTableColumn(column)
        }

        switch activeTab {
        case .samples:
            addColumn(to: tableView, id: "sampleID", title: "Sample ID", width: 140, editable: true)
            addColumn(to: tableView, id: "sampleName", title: "Sample Name", width: 140, editable: true)
            addColumn(to: tableView, id: "forwardBarcodeID", title: "5' Barcode ID", width: 120, editable: true)
            addColumn(to: tableView, id: "forwardSequence", title: "5' Sequence", width: 190, editable: true)
            addColumn(to: tableView, id: "reverseBarcodeID", title: "3' Barcode ID", width: 120, editable: true)
            addColumn(to: tableView, id: "reverseSequence", title: "3' Sequence", width: 190, editable: true)
            addColumn(to: tableView, id: "metadataCount", title: "Metadata", width: 80, editable: false)

        case .demuxSetup:
            break // Step table columns are set up once in setupStepTableColumns()

        case .barcodeKits:
            addColumn(to: tableView, id: "kitDisplayName", title: "Kit", width: 220, editable: false)
            addColumn(to: tableView, id: "kitVendor", title: "Platform", width: 110, editable: false)
            addColumn(to: tableView, id: "kitBarcodeCount", title: "Barcodes", width: 70, editable: false)
            addColumn(to: tableView, id: "kitPairing", title: "Pairing", width: 100, editable: false)

            // Detail table columns
            addColumn(to: kitDetailTable, id: "bcID", title: "ID", width: 80, editable: false)
            addColumn(to: kitDetailTable, id: "bcSequence", title: "Sequence", width: 260, editable: false)
            addColumn(to: kitDetailTable, id: "bcSecondary", title: "Secondary", width: 260, editable: false)
        }

        tableView.reloadData()
        kitDetailTable.reloadData()
        updateTabVisibility()
    }

    private func addColumn(to table: NSTableView, id: String, title: String, width: CGFloat, editable: Bool) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = min(width, 50)
        column.maxWidth = max(width, 800)
        if let cell = column.dataCell as? NSTextFieldCell {
            cell.isEditable = editable
            cell.lineBreakMode = .byTruncatingTail
        }
        table.addTableColumn(column)
    }

    // MARK: - Preferred Set Popup

    private func rebuildPreferredSetPopup() {
        preferredSetPopup.removeAllItems()
        preferredSetIDByPopupIndex.removeAll(keepingCapacity: true)

        let allSets = BarcodeKitRegistry.builtinKits() + customBarcodeSets
        for (index, set) in allSets.enumerated() {
            preferredSetPopup.addItem(withTitle: set.displayName)
            preferredSetIDByPopupIndex[index] = set.id
        }

        if let preferredBarcodeSetID,
           let selectionIndex = preferredSetIDByPopupIndex.first(where: { $0.value == preferredBarcodeSetID })?.key {
            preferredSetPopup.selectItem(at: selectionIndex)
        } else if !allSets.isEmpty {
            preferredSetPopup.selectItem(at: 0)
            preferredBarcodeSetID = preferredSetIDByPopupIndex[0]
        }
    }

    // MARK: - Step Kit Popup

    private func rebuildStepKitPopup() {
        stepKitPopup.removeAllItems()
        for kit in allKits {
            stepKitPopup.addItem(withTitle: kit.displayName)
        }
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView.tag {
        case Self.mainTableTag:
            switch activeTab {
            case .samples: return sampleAssignments.count
            case .barcodeKits: return allKits.count
            case .demuxSetup: return 0
            }
        case Self.kitDetailTableTag:
            return selectedKitBarcodes.count
        case Self.stepTableTag:
            return demuxSteps.count
        default:
            return 0
        }
    }

    public func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let colID = tableColumn?.identifier.rawValue else { return nil }

        switch tableView.tag {
        case Self.mainTableTag:
            return mainTableValue(column: colID, row: row)
        case Self.kitDetailTableTag:
            return kitDetailValue(column: colID, row: row)
        case Self.stepTableTag:
            return stepTableValue(column: colID, row: row)
        default:
            return nil
        }
    }

    private func mainTableValue(column: String, row: Int) -> Any? {
        switch activeTab {
        case .samples:
            guard row >= 0, row < sampleAssignments.count else { return nil }
            let a = sampleAssignments[row]
            switch column {
            case "sampleID": return a.sampleID
            case "sampleName": return a.sampleName ?? ""
            case "forwardBarcodeID": return a.forwardBarcodeID ?? ""
            case "forwardSequence": return a.forwardSequence ?? ""
            case "reverseBarcodeID": return a.reverseBarcodeID ?? ""
            case "reverseSequence": return a.reverseSequence ?? ""
            case "metadataCount": return a.metadata.isEmpty ? "" : "\(a.metadata.count) field(s)"
            default: return nil
            }
        case .barcodeKits:
            guard row >= 0, row < allKits.count else { return nil }
            let kit = allKits[row]
            switch column {
            case "kitDisplayName": return kit.displayName
            case "kitVendor": return kit.platform.displayName
            case "kitBarcodeCount": return "\(kit.barcodes.count)"
            case "kitPairing": return kit.pairingMode.rawValue
            default: return nil
            }
        case .demuxSetup:
            return nil
        }
    }

    private func kitDetailValue(column: String, row: Int) -> Any? {
        guard row >= 0, row < selectedKitBarcodes.count else { return nil }
        let bc = selectedKitBarcodes[row]
        switch column {
        case "bcID": return bc.id
        case "bcSequence": return bc.i7Sequence
        case "bcSecondary": return bc.i5Sequence ?? ""
        default: return nil
        }
    }

    private func stepTableValue(column: String, row: Int) -> Any? {
        guard row >= 0, row < demuxSteps.count else { return nil }
        let step = demuxSteps[row]
        switch column {
        case "stepOrdinal": return "\(step.ordinal + 1)"
        case "stepLabel": return step.label
        case "stepKit": return BarcodeKitRegistry.kit(byID: step.barcodeKitID)?.displayName ?? step.barcodeKitID
        case "stepSymmetry": return step.symmetryMode.rawValue
        default: return nil
        }
    }

    // MARK: - NSTableViewDelegate

    public func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let tableColumn, let value = object as? String else { return }

        switch tableView.tag {
        case Self.mainTableTag:
            setMainTableValue(column: tableColumn.identifier.rawValue, row: row, value: value)
        case Self.stepTableTag:
            setStepTableValue(column: tableColumn.identifier.rawValue, row: row, value: value)
        default:
            break
        }
    }

    private func setMainTableValue(column: String, row: Int, value: String) {
        switch activeTab {
        case .samples:
            guard row >= 0, row < sampleAssignments.count else { return }
            let current = sampleAssignments[row]
            var sampleID = current.sampleID
            var sampleName = current.sampleName
            var forwardBarcodeID = current.forwardBarcodeID
            var forwardSequence = current.forwardSequence
            var reverseBarcodeID = current.reverseBarcodeID
            var reverseSequence = current.reverseSequence

            switch column {
            case "sampleID":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sampleID = trimmed }
            case "sampleName":
                sampleName = value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            case "forwardBarcodeID":
                forwardBarcodeID = value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            case "forwardSequence":
                forwardSequence = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().nilIfEmpty
            case "reverseBarcodeID":
                reverseBarcodeID = value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            case "reverseSequence":
                reverseSequence = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().nilIfEmpty
            default:
                return
            }

            sampleAssignments[row] = FASTQSampleBarcodeAssignment(
                sampleID: sampleID,
                sampleName: sampleName,
                forwardBarcodeID: forwardBarcodeID,
                forwardSequence: forwardSequence,
                reverseBarcodeID: reverseBarcodeID,
                reverseSequence: reverseSequence,
                metadata: current.metadata
            )
            statusLabel.stringValue = "Updated sample '\(sampleID)'."

        case .barcodeKits, .demuxSetup:
            break
        }
    }

    private func setStepTableValue(column: String, row: Int, value: String) {
        guard row >= 0, row < demuxSteps.count, column == "stepLabel" else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        demuxSteps[row].label = trimmed
        statusLabel.stringValue = "Renamed step to '\(trimmed)'."
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSuppressingDelegateCallbacks,
              let table = notification.object as? NSTableView else { return }
        switch table.tag {
        case Self.mainTableTag:
            if activeTab == .barcodeKits {
                let row = tableView.selectedRow
                if row >= 0, row < allKits.count {
                    let kit = allKits[row]
                    selectedKitBarcodes = kit.barcodes
                    selectedKitName = kit.displayName
                    kitDetailLabel.stringValue = "\(kit.displayName) — \(kit.barcodes.count) barcode(s)"
                } else {
                    selectedKitBarcodes = []
                    selectedKitName = ""
                    kitDetailLabel.stringValue = "Select a kit to view its barcodes."
                }
                kitDetailTable.reloadData()
            }
        case Self.stepTableTag:
            selectedStepIndex = stepTable.selectedRow
            refreshStepDetail()
        default:
            break
        }
    }

    // MARK: - Step Detail

    private func refreshStepDetail() {
        let hasSelection = selectedStepIndex >= 0 && selectedStepIndex < demuxSteps.count

        // Show empty state or detail controls
        stepEmptyLabel.isHidden = hasSelection
        let detailControls: [NSView] = [
            stepKitLabel, stepKitPopup,
            stepLocationLabel, stepLocationControl,
            stepSymmetryLabel, stepSymmetryPopup,
            stepErrorLabel, stepErrorRateField,
            stepTrimCheckbox, stepScoutButton,
        ]
        for control in detailControls {
            control.isHidden = !hasSelection
        }

        if demuxSteps.isEmpty {
            stepEmptyLabel.stringValue = "Add a step with + to configure demultiplexing."
        } else if !hasSelection {
            stepEmptyLabel.stringValue = "Select a step to edit its settings."
        }

        guard hasSelection else { return }
        let step = demuxSteps[selectedStepIndex]

        // Kit popup
        if let kitIndex = allKits.firstIndex(where: { $0.id == step.barcodeKitID }) {
            stepKitPopup.selectItem(at: kitIndex)
        }

        // Location
        switch step.barcodeLocation {
        case .fivePrime: stepLocationControl.selectedSegment = 0
        case .threePrime: stepLocationControl.selectedSegment = 1
        case .bothEnds: stepLocationControl.selectedSegment = 2
        }

        // Symmetry
        switch step.symmetryMode {
        case .symmetric: stepSymmetryPopup.selectItem(at: 0)
        case .asymmetric: stepSymmetryPopup.selectItem(at: 1)
        case .singleEnd: stepSymmetryPopup.selectItem(at: 2)
        }

        stepErrorRateField.stringValue = String(format: "%.2f", step.errorRate)
        stepTrimCheckbox.state = step.trimBarcodes ? .on : .off
    }

    @objc private func stepKitChanged(_ sender: NSPopUpButton) {
        guard selectedStepIndex >= 0, selectedStepIndex < demuxSteps.count else { return }
        let kitIndex = sender.indexOfSelectedItem
        guard kitIndex >= 0, kitIndex < allKits.count else { return }
        demuxSteps[selectedStepIndex].barcodeKitID = allKits[kitIndex].id
        stepTable.reloadData()
        statusLabel.stringValue = "Step kit changed to '\(allKits[kitIndex].displayName)'."
    }

    @objc private func stepDetailChanged(_ sender: Any) {
        guard selectedStepIndex >= 0, selectedStepIndex < demuxSteps.count else { return }

        let location: BarcodeLocation
        switch stepLocationControl.selectedSegment {
        case 0: location = .fivePrime
        case 1: location = .threePrime
        default: location = .bothEnds
        }
        demuxSteps[selectedStepIndex].barcodeLocation = location

        let symmetry: BarcodeSymmetryMode
        switch stepSymmetryPopup.indexOfSelectedItem {
        case 1: symmetry = .asymmetric
        case 2: symmetry = .singleEnd
        default: symmetry = .symmetric
        }
        demuxSteps[selectedStepIndex].symmetryMode = symmetry

        if let rate = Double(stepErrorRateField.stringValue) {
            demuxSteps[selectedStepIndex].errorRate = max(0.01, min(0.50, rate))
        }

        demuxSteps[selectedStepIndex].trimBarcodes = stepTrimCheckbox.state == .on

        stepTable.reloadData()
    }

    @objc private func stepScoutClicked(_ sender: NSButton) {
        guard selectedStepIndex >= 0, selectedStepIndex < demuxSteps.count else { return }
        delegate?.fastqMetadataDrawerViewDidRequestScout(self, step: demuxSteps[selectedStepIndex])
    }

    // MARK: - Button Actions

    @objc private func preferredSetChanged(_ sender: NSPopUpButton) {
        preferredBarcodeSetID = preferredSetIDByPopupIndex[sender.indexOfSelectedItem]
    }

    @objc private func addClicked(_ sender: NSButton) {
        guard activeTab == .samples else { return }

        let nextNumber = sampleAssignments.count + 1
        let sampleID = String(format: "sample-%03d", nextNumber)
        sampleAssignments.append(
            FASTQSampleBarcodeAssignment(
                sampleID: sampleID,
                sampleName: nil,
                forwardBarcodeID: nil,
                forwardSequence: nil,
                reverseBarcodeID: nil,
                reverseSequence: nil,
                metadata: [:]
            )
        )
        tableView.reloadData()
        let newRow = sampleAssignments.count - 1
        if newRow >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(newRow)
        }
        statusLabel.stringValue = "Added \(sampleID)."
    }

    @objc private func addStepClicked(_ sender: NSButton) {
        let ordinal = demuxSteps.count
        let label = ordinal == 0 ? "Outer" : "Inner \(ordinal)"
        let defaultKit = allKits.first?.id ?? ""
        let step = DemultiplexStep(
            label: label,
            barcodeKitID: defaultKit,
            ordinal: ordinal
        )
        demuxSteps.append(step)
        stepTable.reloadData()
        stepTable.selectRowIndexes(IndexSet(integer: ordinal), byExtendingSelection: false)
        selectedStepIndex = ordinal
        refreshStepDetail()
        statusLabel.stringValue = "Added step '\(label)'."
    }

    @objc private func removeStepClicked(_ sender: NSButton) {
        guard selectedStepIndex >= 0, selectedStepIndex < demuxSteps.count else { return }
        let removed = demuxSteps.remove(at: selectedStepIndex)
        // Re-number ordinals
        for i in demuxSteps.indices {
            demuxSteps[i].ordinal = i
        }
        selectedStepIndex = min(selectedStepIndex, demuxSteps.count - 1)
        isSuppressingDelegateCallbacks = true
        stepTable.reloadData()
        if selectedStepIndex >= 0 {
            stepTable.selectRowIndexes(IndexSet(integer: selectedStepIndex), byExtendingSelection: false)
        }
        isSuppressingDelegateCallbacks = false
        refreshStepDetail()
        statusLabel.stringValue = "Removed step '\(removed.label)'."
    }

    @objc private func removeClicked(_ sender: NSButton) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }

        switch activeTab {
        case .samples:
            guard row < sampleAssignments.count else { return }
            let removed = sampleAssignments.remove(at: row)
            tableView.reloadData()
            statusLabel.stringValue = "Removed sample '\(removed.sampleID)'."

        case .barcodeKits:
            // Only allow removing custom kits (those beyond builtin count)
            let builtinCount = BarcodeKitRegistry.builtinKits().count
            guard row >= builtinCount else {
                statusLabel.stringValue = "Built-in kits cannot be removed."
                return
            }
            let customIndex = row - builtinCount
            guard customIndex < customBarcodeSets.count else { return }
            let removed = customBarcodeSets.remove(at: customIndex)
            if preferredBarcodeSetID == removed.id {
                preferredBarcodeSetID = nil
            }
            allKits = BarcodeKitRegistry.builtinKits() + customBarcodeSets
            rebuildPreferredSetPopup()
            rebuildStepKitPopup()
            tableView.reloadData()
            selectedKitBarcodes = []
            kitDetailTable.reloadData()
            kitDetailLabel.stringValue = "Select a kit to view its barcodes."
            statusLabel.stringValue = "Removed custom kit '\(removed.displayName)'."

        case .demuxSetup:
            break
        }
    }

    @objc private func importClicked(_ sender: NSButton) {
        guard let window else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                switch self.activeTab {
                case .samples:
                    do {
                        self.sampleAssignments = try FASTQSampleBarcodeCSV.load(from: url)
                        self.tableView.reloadData()
                        self.statusLabel.stringValue = "Imported \(self.sampleAssignments.count) sample assignment(s)."
                    } catch {
                        self.statusLabel.stringValue = "Import failed: \(error.localizedDescription)"
                    }

                case .barcodeKits:
                    do {
                        let name = url.deletingPathExtension().lastPathComponent
                        let set = try BarcodeKitRegistry.loadCustomKit(from: url, name: name)
                        if let idx = self.customBarcodeSets.firstIndex(where: { $0.id == set.id }) {
                            self.customBarcodeSets[idx] = set
                        } else {
                            self.customBarcodeSets.append(set)
                        }
                        self.allKits = BarcodeKitRegistry.builtinKits() + self.customBarcodeSets
                        self.rebuildPreferredSetPopup()
                        self.rebuildStepKitPopup()
                        self.tableView.reloadData()
                        self.statusLabel.stringValue = "Imported custom barcode kit '\(set.displayName)'."
                    } catch {
                        self.statusLabel.stringValue = "Import failed: \(error.localizedDescription)"
                    }

                case .demuxSetup:
                    break
                }
            }
        }
    }

    @objc private func exportClicked(_ sender: NSButton) {
        guard let window else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.prompt = "Export"

        switch activeTab {
        case .samples:
            panel.nameFieldStringValue = "fastq-sample-metadata.csv"
        case .barcodeKits, .demuxSetup:
            statusLabel.stringValue = "Export is only available on the Samples tab."
            return
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let outputURL = panel.url else { return }
                do {
                    let content = FASTQSampleBarcodeCSV.exportCSV(self.sampleAssignments)
                    try content.write(to: outputURL, atomically: true, encoding: .utf8)
                    self.statusLabel.stringValue = "Exported \(outputURL.lastPathComponent)."
                } catch {
                    self.statusLabel.stringValue = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func saveClicked(_ sender: NSButton) {
        delegate?.fastqMetadataDrawerViewDidSave(self, fastqURL: fastqURL, metadata: currentMetadata())
        statusLabel.stringValue = "Saved FASTQ metadata."
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
