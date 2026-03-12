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
    func fastqMetadataDrawerViewDidChangeDemuxPlan(
        _ drawer: FASTQMetadataDrawerView,
        plan: DemultiplexPlan
    )
    func fastqMetadataDrawerDidDragDivider(_ drawer: FASTQMetadataDrawerView, deltaY: CGFloat)
    func fastqMetadataDrawerDidFinishDraggingDivider(_ drawer: FASTQMetadataDrawerView)
}

// Default no-op implementations so existing conformers don't break.
public extension FASTQMetadataDrawerViewDelegate {
    func fastqMetadataDrawerViewDidRequestScout(
        _ drawer: FASTQMetadataDrawerView,
        step: DemultiplexStep
    ) {}
    func fastqMetadataDrawerViewDidChangeDemuxPlan(
        _ drawer: FASTQMetadataDrawerView,
        plan: DemultiplexPlan
    ) {}
    func fastqMetadataDrawerDidDragDivider(_ drawer: FASTQMetadataDrawerView, deltaY: CGFloat) {}
    func fastqMetadataDrawerDidFinishDraggingDivider(_ drawer: FASTQMetadataDrawerView) {}
}

// MARK: - FASTQDrawerDividerView

/// Drag-to-resize handle for the FASTQ metadata drawer, matching the annotation drawer divider.
@MainActor
final class FASTQDrawerDividerView: NSView {

    /// Called during mouse drag with the vertical delta (positive = dragging up = taller drawer).
    var onDrag: ((CGFloat) -> Void)?

    /// Called when the drag gesture ends.
    var onDragEnd: (() -> Void)?

    private var dragStartY: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 1px separator line at the bottom of the divider
        NSColor.separatorColor.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: bounds.width, height: 1))
        // Three subtle horizontal grip indicator lines
        let cx = bounds.midX
        let cy = bounds.midY
        NSColor.tertiaryLabelColor.setFill()
        for offset: CGFloat in [-2, 0, 2] {
            NSBezierPath.fill(NSRect(x: cx - 8, y: cy + offset, width: 16, height: 0.5))
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        let currentY = NSEvent.mouseLocation.y
        let delta = currentY - dragStartY  // screen Y increases upward; drag up = positive = taller
        dragStartY = currentY
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}

@MainActor
public final class FASTQMetadataDrawerView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private enum Tab: Int {
        case samples = 0
        case demuxSetup = 1
        case orient = 2
        case barcodeKits = 3
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
    private let drawerDivider = FASTQDrawerDividerView()

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
    private let stepOverlapLabel = NSTextField(labelWithString: "Min Overlap:")
    private let stepOverlapField = NSTextField(string: "3")
    private let stepIndelsCheckbox = NSButton(checkboxWithTitle: "Allow indels", target: nil, action: nil)
    private let stepTrimCheckbox = NSButton(checkboxWithTitle: "Trim barcodes", target: nil, action: nil)
    private let stepDistance5Label = NSTextField(labelWithString: "5' Window:")
    private let stepDistance5Field = NSTextField(string: "0")
    private let stepDistance3Label = NSTextField(labelWithString: "3' Window:")
    private let stepDistance3Field = NSTextField(string: "0")
    private let stepScoutButton = NSButton(title: "Detect", target: nil, action: nil)
    private let stepAddButton = NSButton(title: "+", target: nil, action: nil)
    private let stepRemoveButton = NSButton(title: "−", target: nil, action: nil)

    // Orient tab controls
    private let orientContainer = NSView()
    private let orientReferenceLabel = NSTextField(labelWithString: "Reference FASTA:")
    private let orientReferencePopup = NSPopUpButton()
    private let orientBrowseButton = NSButton(title: "Browse...", target: nil, action: nil)
    private let orientWordLengthLabel = NSTextField(labelWithString: "Word Length:")
    private let orientWordLengthField = NSTextField(string: "12")
    private let orientMaskLabel = NSTextField(labelWithString: "Masking:")
    private let orientMaskPopup = NSPopUpButton()
    private let orientSaveUnorientedCheckbox = NSButton(checkboxWithTitle: "Save unoriented reads as separate derivative", target: nil, action: nil)
    private let orientInfoLabel = NSTextField(labelWithString: "Results stored as lightweight derivative (orientation map). Oriented FASTQ materialized on demand using seqkit.")
    private let orientRunButton = NSButton(title: "Orient", target: nil, action: nil)
    private var orientReferenceURL: URL?
    private var orientProjectReferences: [(url: URL, manifest: ReferenceSequenceManifest)] = []

    // Constraint groups toggled per-tab
    private var samplesConstraints: [NSLayoutConstraint] = []
    private var demuxSetupConstraints: [NSLayoutConstraint] = []
    private var orientConstraints: [NSLayoutConstraint] = []
    private var barcodeKitsConstraints: [NSLayoutConstraint] = []

    public init(delegate: FASTQMetadataDrawerViewDelegate? = nil) {
        self.delegate = delegate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
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
            if let planJSON = metadata.demuxPlanJSON {
                if let plan = decodeDemuxPlan(from: planJSON) {
                    demuxSteps = plan.steps
                    compositeSampleNames = plan.compositeSampleNames
                } else {
                    demuxSteps = []
                    compositeSampleNames = [:]
                }
            } else {
                demuxSteps = []
                compositeSampleNames = [:]
            }
        } else {
            sampleAssignments = []
            customBarcodeSets = []
            preferredBarcodeSetID = nil
            demuxSteps = []
            compositeSampleNames = [:]
        }
        allKits = BarcodeKitRegistry.builtinKits() + customBarcodeSets
        selectedStepIndex = min(max(0, selectedStepIndex), max(-1, demuxSteps.count - 1))
        rebuildPreferredSetPopup()
        stepTable.reloadData()
        refreshStepDetail()
        tableView.reloadData()
        statusLabel.stringValue = sampleAssignments.isEmpty
            ? "No FASTQ sample metadata loaded."
            : "Loaded \(sampleAssignments.count) sample assignment(s)."
    }

    public func currentMetadata() -> FASTQDemultiplexMetadata {
        let demuxPlanJSON = encodeDemuxPlanToJSON(currentDemuxPlan())
        return FASTQDemultiplexMetadata(
            sampleAssignments: sampleAssignments,
            customBarcodeSets: customBarcodeSets,
            preferredBarcodeSetID: preferredBarcodeSetID,
            demuxPlanJSON: demuxPlanJSON
        )
    }

    /// Returns the current demux plan built from the Demux Setup tab.
    public func currentDemuxPlan() -> DemultiplexPlan {
        DemultiplexPlan(steps: demuxSteps, compositeSampleNames: compositeSampleNames)
    }

    /// Updates the status label with scout progress messages.
    public func updateScoutStatus(_ message: String) {
        statusLabel.stringValue = message
    }

    /// Updates sample assignments from scout results and refreshes the table.
    public func updateSampleAssignments(_ assignments: [FASTQSampleBarcodeAssignment]) {
        sampleAssignments = assignments
        tableView.reloadData()
        statusLabel.stringValue = "\(assignments.count) sample(s) assigned from barcode scout."
    }

    /// Applies scout-derived assignments to the currently selected demux step.
    /// Falls back to step 0 when no step is selected.
    public func applySampleAssignmentsToCurrentStep(_ assignments: [FASTQSampleBarcodeAssignment]) {
        let targetIndex: Int
        if selectedStepIndex >= 0 && selectedStepIndex < demuxSteps.count {
            targetIndex = selectedStepIndex
        } else {
            targetIndex = 0
        }
        guard targetIndex >= 0 && targetIndex < demuxSteps.count else { return }
        demuxSteps[targetIndex].sampleAssignments = assignments
        statusLabel.stringValue = "Applied \(assignments.count) assignment(s) to step '\(demuxSteps[targetIndex].label)'."
        stepTable.reloadData()
        refreshStepDetail()
        notifyDemuxPlanChanged()
    }

    /// Programmatically selects the Demux Setup tab.
    public func selectDemuxSetupTab() {
        tabControl.selectedSegment = Tab.demuxSetup.rawValue
        activeTab = .demuxSetup
        rebuildColumns()
    }

    // MARK: - Setup UI

    private func setupUI() {
        drawerDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(drawerDivider)
        drawerDivider.onDrag = { [weak self] deltaY in
            guard let self else { return }
            self.delegate?.fastqMetadataDrawerDidDragDivider(self, deltaY: deltaY)
        }
        drawerDivider.onDragEnd = { [weak self] in
            guard let self else { return }
            self.delegate?.fastqMetadataDrawerDidFinishDraggingDivider(self)
        }

        headerBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBar)

        // 4-segment tab control
        tabControl.segmentCount = 4
        tabControl.setLabel("Samples", forSegment: 0)
        tabControl.setLabel("Demux Setup", forSegment: 1)
        tabControl.setLabel("Orient", forSegment: 2)
        tabControl.setLabel("Barcode Kits", forSegment: 3)
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
        kitDetailTable.allowsMultipleSelection = true
        kitDetailTable.dataSource = self
        kitDetailTable.delegate = self
        kitDetailTable.menu = buildKitDetailContextMenu()
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

        // Orient tab container + controls
        setupOrientTab()

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

        let labels: [NSTextField] = [stepKitLabel, stepLocationLabel, stepSymmetryLabel, stepErrorLabel,
                                      stepOverlapLabel, stepDistance5Label, stepDistance3Label]
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

        stepOverlapField.controlSize = .small
        stepOverlapField.translatesAutoresizingMaskIntoConstraints = false
        stepOverlapField.alignment = .right
        stepOverlapField.target = self
        stepOverlapField.action = #selector(stepDetailChanged(_:))
        let overlapFormatter = NumberFormatter()
        overlapFormatter.numberStyle = .none
        overlapFormatter.minimum = 1
        overlapFormatter.maximum = 50
        overlapFormatter.allowsFloats = false
        stepOverlapField.formatter = overlapFormatter
        stepDetailContainer.addSubview(stepOverlapField)

        stepIndelsCheckbox.controlSize = .small
        stepIndelsCheckbox.translatesAutoresizingMaskIntoConstraints = false
        stepIndelsCheckbox.state = .on
        stepIndelsCheckbox.target = self
        stepIndelsCheckbox.action = #selector(stepDetailChanged(_:))
        stepDetailContainer.addSubview(stepIndelsCheckbox)

        stepTrimCheckbox.controlSize = .small
        stepTrimCheckbox.translatesAutoresizingMaskIntoConstraints = false
        stepTrimCheckbox.state = .on
        stepTrimCheckbox.target = self
        stepTrimCheckbox.action = #selector(stepDetailChanged(_:))
        stepDetailContainer.addSubview(stepTrimCheckbox)

        let distanceFormatter = NumberFormatter()
        distanceFormatter.numberStyle = .none
        distanceFormatter.minimum = 0
        distanceFormatter.maximum = 500
        distanceFormatter.allowsFloats = false

        for field in [stepDistance5Field, stepDistance3Field] {
            field.controlSize = .small
            field.translatesAutoresizingMaskIntoConstraints = false
            field.alignment = .right
            field.target = self
            field.action = #selector(stepDetailChanged(_:))
            field.formatter = distanceFormatter.copy() as? NumberFormatter
            stepDetailContainer.addSubview(field)
        }

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
        stepOverlapField.setAccessibilityLabel("Minimum overlap")
        stepIndelsCheckbox.setAccessibilityLabel("Allow indels in barcode matching")
        stepTrimCheckbox.setAccessibilityLabel("Trim barcodes from reads")
        stepDistance5Field.setAccessibilityLabel("Maximum search distance from 5-prime end")
        stepDistance3Field.setAccessibilityLabel("Maximum search distance from 3-prime end")
        stepScoutButton.setAccessibilityLabel("Detect barcode matches")
        stepTable.setAccessibilityLabel("Demultiplexing steps")
        stepAddButton.setAccessibilityLabel("Add demux step")
        stepRemoveButton.setAccessibilityLabel("Remove demux step")
        kitDetailTable.setAccessibilityLabel("Barcode sequences")

        // Layout within detail panel — two-column grid that stays within container bounds
        // Row 1: Kit
        // Row 2: Location
        // Row 3: Error Rate + Min Overlap + Symmetry
        // Row 4: Allow Indels + Trim + Scout
        // Row 5: 5' Window + 3' Window

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

            // Row 2: Location + Symmetry
            stepLocationLabel.topAnchor.constraint(equalTo: stepKitLabel.bottomAnchor, constant: 8),
            stepLocationLabel.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),
            stepLocationControl.centerYAnchor.constraint(equalTo: stepLocationLabel.centerYAnchor),
            stepLocationControl.leadingAnchor.constraint(equalTo: stepLocationLabel.trailingAnchor, constant: 4),

            stepSymmetryLabel.centerYAnchor.constraint(equalTo: stepLocationLabel.centerYAnchor),
            stepSymmetryLabel.leadingAnchor.constraint(equalTo: stepLocationControl.trailingAnchor, constant: 16),
            stepSymmetryPopup.centerYAnchor.constraint(equalTo: stepSymmetryLabel.centerYAnchor),
            stepSymmetryPopup.leadingAnchor.constraint(equalTo: stepSymmetryLabel.trailingAnchor, constant: 4),
            symMinWidth,
            stepSymmetryPopup.trailingAnchor.constraint(lessThanOrEqualTo: stepDetailContainer.trailingAnchor, constant: -8),

            // Row 3: Error Rate + Min Overlap
            stepErrorLabel.topAnchor.constraint(equalTo: stepLocationLabel.bottomAnchor, constant: 8),
            stepErrorLabel.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),
            stepErrorRateField.centerYAnchor.constraint(equalTo: stepErrorLabel.centerYAnchor),
            stepErrorRateField.leadingAnchor.constraint(equalTo: stepErrorLabel.trailingAnchor, constant: 4),
            stepErrorRateField.widthAnchor.constraint(equalToConstant: 50),

            stepOverlapLabel.centerYAnchor.constraint(equalTo: stepErrorLabel.centerYAnchor),
            stepOverlapLabel.leadingAnchor.constraint(equalTo: stepErrorRateField.trailingAnchor, constant: 16),
            stepOverlapField.centerYAnchor.constraint(equalTo: stepOverlapLabel.centerYAnchor),
            stepOverlapField.leadingAnchor.constraint(equalTo: stepOverlapLabel.trailingAnchor, constant: 4),
            stepOverlapField.widthAnchor.constraint(equalToConstant: 40),
            stepOverlapField.trailingAnchor.constraint(lessThanOrEqualTo: stepDetailContainer.trailingAnchor, constant: -8),

            // Row 4: Allow Indels + Trim + Scout
            stepIndelsCheckbox.topAnchor.constraint(equalTo: stepErrorLabel.bottomAnchor, constant: 8),
            stepIndelsCheckbox.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),

            stepTrimCheckbox.centerYAnchor.constraint(equalTo: stepIndelsCheckbox.centerYAnchor),
            stepTrimCheckbox.leadingAnchor.constraint(equalTo: stepIndelsCheckbox.trailingAnchor, constant: 16),

            stepScoutButton.centerYAnchor.constraint(equalTo: stepIndelsCheckbox.centerYAnchor),
            stepScoutButton.trailingAnchor.constraint(equalTo: stepDetailContainer.trailingAnchor, constant: -8),

            // Row 5: 5' Window + 3' Window
            stepDistance5Label.topAnchor.constraint(equalTo: stepIndelsCheckbox.bottomAnchor, constant: 8),
            stepDistance5Label.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),
            stepDistance5Field.centerYAnchor.constraint(equalTo: stepDistance5Label.centerYAnchor),
            stepDistance5Field.leadingAnchor.constraint(equalTo: stepDistance5Label.trailingAnchor, constant: 4),
            stepDistance5Field.widthAnchor.constraint(equalToConstant: 44),

            stepDistance3Label.centerYAnchor.constraint(equalTo: stepDistance5Label.centerYAnchor),
            stepDistance3Label.leadingAnchor.constraint(equalTo: stepDistance5Field.trailingAnchor, constant: 16),
            stepDistance3Field.centerYAnchor.constraint(equalTo: stepDistance3Label.centerYAnchor),
            stepDistance3Field.leadingAnchor.constraint(equalTo: stepDistance3Label.trailingAnchor, constant: 4),
            stepDistance3Field.widthAnchor.constraint(equalToConstant: 44),
            stepDistance3Field.trailingAnchor.constraint(lessThanOrEqualTo: stepDetailContainer.trailingAnchor, constant: -8),
        ])
    }

    private func setupOrientTab() {
        orientContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(orientContainer)

        let labels: [NSTextField] = [orientReferenceLabel, orientWordLengthLabel, orientMaskLabel]
        for label in labels {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            orientContainer.addSubview(label)
        }

        orientReferencePopup.controlSize = .small
        orientReferencePopup.translatesAutoresizingMaskIntoConstraints = false
        orientReferencePopup.target = self
        orientReferencePopup.action = #selector(orientReferenceChanged(_:))
        orientContainer.addSubview(orientReferencePopup)

        orientBrowseButton.bezelStyle = .rounded
        orientBrowseButton.controlSize = .small
        orientBrowseButton.translatesAutoresizingMaskIntoConstraints = false
        orientBrowseButton.target = self
        orientBrowseButton.action = #selector(orientBrowseClicked(_:))
        orientContainer.addSubview(orientBrowseButton)

        orientWordLengthField.controlSize = .small
        orientWordLengthField.translatesAutoresizingMaskIntoConstraints = false
        orientWordLengthField.alignment = .right
        let wlFormatter = NumberFormatter()
        wlFormatter.numberStyle = .none
        wlFormatter.minimum = 3
        wlFormatter.maximum = 15
        wlFormatter.allowsFloats = false
        orientWordLengthField.formatter = wlFormatter
        orientContainer.addSubview(orientWordLengthField)

        orientMaskPopup.controlSize = .small
        orientMaskPopup.translatesAutoresizingMaskIntoConstraints = false
        orientMaskPopup.addItems(withTitles: ["dust", "none"])
        orientContainer.addSubview(orientMaskPopup)

        orientSaveUnorientedCheckbox.controlSize = .small
        orientSaveUnorientedCheckbox.translatesAutoresizingMaskIntoConstraints = false
        orientSaveUnorientedCheckbox.state = .on
        orientContainer.addSubview(orientSaveUnorientedCheckbox)

        orientInfoLabel.font = .systemFont(ofSize: 10)
        orientInfoLabel.textColor = .tertiaryLabelColor
        orientInfoLabel.lineBreakMode = .byWordWrapping
        orientInfoLabel.maximumNumberOfLines = 2
        orientInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        orientContainer.addSubview(orientInfoLabel)

        orientRunButton.bezelStyle = .rounded
        orientRunButton.controlSize = .regular
        orientRunButton.translatesAutoresizingMaskIntoConstraints = false
        orientRunButton.target = self
        orientRunButton.action = #selector(orientRunClicked(_:))
        orientContainer.addSubview(orientRunButton)

        // Accessibility
        orientReferencePopup.setAccessibilityLabel("Reference FASTA file")
        orientBrowseButton.setAccessibilityLabel("Browse for reference FASTA")
        orientWordLengthField.setAccessibilityLabel("Word length for k-mer matching")
        orientMaskPopup.setAccessibilityLabel("Low-complexity masking mode")
        orientSaveUnorientedCheckbox.setAccessibilityLabel("Save unoriented reads")
        orientRunButton.setAccessibilityLabel("Run orient pipeline")

        // Layout within orient container
        NSLayoutConstraint.activate([
            // Row 1: Reference FASTA
            orientReferenceLabel.topAnchor.constraint(equalTo: orientContainer.topAnchor, constant: 8),
            orientReferenceLabel.leadingAnchor.constraint(equalTo: orientContainer.leadingAnchor, constant: 8),
            orientReferencePopup.centerYAnchor.constraint(equalTo: orientReferenceLabel.centerYAnchor),
            orientReferencePopup.leadingAnchor.constraint(equalTo: orientReferenceLabel.trailingAnchor, constant: 4),
            orientReferencePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            orientBrowseButton.centerYAnchor.constraint(equalTo: orientReferenceLabel.centerYAnchor),
            orientBrowseButton.leadingAnchor.constraint(equalTo: orientReferencePopup.trailingAnchor, constant: 6),
            orientBrowseButton.trailingAnchor.constraint(lessThanOrEqualTo: orientContainer.trailingAnchor, constant: -8),

            // Row 2: Word Length + Masking
            orientWordLengthLabel.topAnchor.constraint(equalTo: orientReferenceLabel.bottomAnchor, constant: 8),
            orientWordLengthLabel.leadingAnchor.constraint(equalTo: orientContainer.leadingAnchor, constant: 8),
            orientWordLengthField.centerYAnchor.constraint(equalTo: orientWordLengthLabel.centerYAnchor),
            orientWordLengthField.leadingAnchor.constraint(equalTo: orientWordLengthLabel.trailingAnchor, constant: 4),
            orientWordLengthField.widthAnchor.constraint(equalToConstant: 40),

            orientMaskLabel.centerYAnchor.constraint(equalTo: orientWordLengthLabel.centerYAnchor),
            orientMaskLabel.leadingAnchor.constraint(equalTo: orientWordLengthField.trailingAnchor, constant: 16),
            orientMaskPopup.centerYAnchor.constraint(equalTo: orientMaskLabel.centerYAnchor),
            orientMaskPopup.leadingAnchor.constraint(equalTo: orientMaskLabel.trailingAnchor, constant: 4),

            // Row 3: Save unoriented checkbox
            orientSaveUnorientedCheckbox.topAnchor.constraint(equalTo: orientWordLengthLabel.bottomAnchor, constant: 8),
            orientSaveUnorientedCheckbox.leadingAnchor.constraint(equalTo: orientContainer.leadingAnchor, constant: 8),

            // Row 4: Info label
            orientInfoLabel.topAnchor.constraint(equalTo: orientSaveUnorientedCheckbox.bottomAnchor, constant: 6),
            orientInfoLabel.leadingAnchor.constraint(equalTo: orientContainer.leadingAnchor, constant: 8),
            orientInfoLabel.trailingAnchor.constraint(lessThanOrEqualTo: orientContainer.trailingAnchor, constant: -8),

            // Row 5: Run button
            orientRunButton.topAnchor.constraint(equalTo: orientInfoLabel.bottomAnchor, constant: 10),
            orientRunButton.leadingAnchor.constraint(equalTo: orientContainer.leadingAnchor, constant: 8),
        ])

        rebuildOrientReferencePopup()
    }

    private func setupConstraints() {
        // Common/fixed constraints
        NSLayoutConstraint.activate([
            drawerDivider.topAnchor.constraint(equalTo: topAnchor),
            drawerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            drawerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            drawerDivider.heightAnchor.constraint(equalToConstant: 8),

            headerBar.topAnchor.constraint(equalTo: drawerDivider.bottomAnchor, constant: 2),
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

        // Orient tab constraints (orient container fills content area)
        orientConstraints = [
            orientContainer.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 6),
            orientContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            orientContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            orientContainer.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
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
        NSLayoutConstraint.deactivate(orientConstraints)

        // Hide everything first
        scrollView.isHidden = true
        kitDetailScrollView.isHidden = true
        kitDetailLabel.isHidden = true
        stepScrollView.isHidden = true
        stepDetailContainer.isHidden = true
        orientContainer.isHidden = true

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

        case .orient:
            orientContainer.isHidden = false
            NSLayoutConstraint.activate(orientConstraints)
            rebuildOrientReferencePopup()

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

        case .orient:
            break // Orient controls are static, no table columns needed

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
            case .demuxSetup, .orient: return 0
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
        case .demuxSetup, .orient:
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

        case .barcodeKits, .demuxSetup, .orient:
            break
        }
    }

    private func setStepTableValue(column: String, row: Int, value: String) {
        guard row >= 0, row < demuxSteps.count, column == "stepLabel" else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        demuxSteps[row].label = trimmed
        statusLabel.stringValue = "Renamed step to '\(trimmed)'."
        notifyDemuxPlanChanged()
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
            stepOverlapLabel, stepOverlapField,
            stepIndelsCheckbox, stepTrimCheckbox, stepScoutButton,
            stepDistance5Label, stepDistance5Field,
            stepDistance3Label, stepDistance3Field,
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
        stepOverlapField.stringValue = "\(step.minimumOverlap)"
        stepIndelsCheckbox.state = step.allowIndels ? .on : .off
        stepTrimCheckbox.state = step.trimBarcodes ? .on : .off
        stepDistance5Field.stringValue = "\(step.maxSearchDistance5Prime)"
        stepDistance3Field.stringValue = "\(step.maxSearchDistance3Prime)"
        updateLocationControlState()
    }

    @objc private func stepKitChanged(_ sender: NSPopUpButton) {
        guard selectedStepIndex >= 0, selectedStepIndex < demuxSteps.count else { return }
        let kitIndex = sender.indexOfSelectedItem
        guard kitIndex >= 0, kitIndex < allKits.count else { return }
        let kit = allKits[kitIndex]
        demuxSteps[selectedStepIndex].barcodeKitID = kit.id

        // Auto-set symmetry and location from kit's pairing mode
        let symmetry: BarcodeSymmetryMode
        switch kit.pairingMode {
        case .singleEnd: symmetry = .singleEnd
        case .symmetric: symmetry = .symmetric
        case .fixedDual, .combinatorialDual: symmetry = .asymmetric
        }
        demuxSteps[selectedStepIndex].symmetryMode = symmetry

        // Symmetric and asymmetric always search both ends; single-end defaults to 5'
        switch symmetry {
        case .symmetric, .asymmetric:
            demuxSteps[selectedStepIndex].barcodeLocation = .bothEnds
        case .singleEnd:
            break // keep current location
        }

        // Auto-set error rate, overlap, and revcomp from platform
        demuxSteps[selectedStepIndex].errorRate = kit.platform.recommendedErrorRate
        demuxSteps[selectedStepIndex].minimumOverlap = kit.platform.recommendedMinimumOverlap
        demuxSteps[selectedStepIndex].searchReverseComplement = kit.platform.readsCanBeReverseComplemented

        refreshStepDetail()
        updateLocationControlState()
        stepTable.reloadData()
        statusLabel.stringValue = "Step kit changed to '\(kit.displayName)'."
        notifyDemuxPlanChanged()
    }

    /// Enables/disables the location control based on symmetry mode.
    /// For symmetric/asymmetric, location is always "Both" and not user-editable.
    private func updateLocationControlState() {
        guard selectedStepIndex >= 0, selectedStepIndex < demuxSteps.count else { return }
        let symmetry = demuxSteps[selectedStepIndex].symmetryMode
        switch symmetry {
        case .symmetric, .asymmetric:
            stepLocationControl.isEnabled = false
            stepLocationControl.selectedSegment = 2 // Both
        case .singleEnd:
            stepLocationControl.isEnabled = true
        }
    }

    @objc private func stepDetailChanged(_ sender: Any) {
        guard selectedStepIndex >= 0, selectedStepIndex < demuxSteps.count else { return }

        let symmetry: BarcodeSymmetryMode
        switch stepSymmetryPopup.indexOfSelectedItem {
        case 1: symmetry = .asymmetric
        case 2: symmetry = .singleEnd
        default: symmetry = .symmetric
        }
        demuxSteps[selectedStepIndex].symmetryMode = symmetry

        // Symmetry determines location: symmetric/asymmetric always use both ends
        switch symmetry {
        case .symmetric, .asymmetric:
            demuxSteps[selectedStepIndex].barcodeLocation = .bothEnds
        case .singleEnd:
            let location: BarcodeLocation
            switch stepLocationControl.selectedSegment {
            case 0: location = .fivePrime
            case 1: location = .threePrime
            default: location = .bothEnds
            }
            demuxSteps[selectedStepIndex].barcodeLocation = location
        }

        updateLocationControlState()

        if let rate = Double(stepErrorRateField.stringValue) {
            demuxSteps[selectedStepIndex].errorRate = max(0.01, min(0.50, rate))
        }

        demuxSteps[selectedStepIndex].trimBarcodes = stepTrimCheckbox.state == .on
        demuxSteps[selectedStepIndex].allowIndels = stepIndelsCheckbox.state == .on

        if let overlap = Int(stepOverlapField.stringValue) {
            demuxSteps[selectedStepIndex].minimumOverlap = max(1, min(30, overlap))
        }
        if let dist5 = Int(stepDistance5Field.stringValue) {
            demuxSteps[selectedStepIndex].maxSearchDistance5Prime = max(0, dist5)
        }
        if let dist3 = Int(stepDistance3Field.stringValue) {
            demuxSteps[selectedStepIndex].maxSearchDistance3Prime = max(0, dist3)
        }

        stepTable.reloadData()
        notifyDemuxPlanChanged()
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
        notifyDemuxPlanChanged()
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
        notifyDemuxPlanChanged()
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

        case .demuxSetup, .orient:
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

                case .demuxSetup, .orient:
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
        case .barcodeKits, .demuxSetup, .orient:
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

    private func notifyDemuxPlanChanged() {
        delegate?.fastqMetadataDrawerViewDidChangeDemuxPlan(self, plan: currentDemuxPlan())
    }

    private func encodeDemuxPlanToJSON(_ plan: DemultiplexPlan) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(plan) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeDemuxPlan(from json: String) -> DemultiplexPlan? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(DemultiplexPlan.self, from: data)
    }

    // MARK: - Orient Tab

    private func rebuildOrientReferencePopup() {
        orientReferencePopup.removeAllItems()
        orientProjectReferences = []

        // Populate from project's Reference Sequences folder if a FASTQ URL is available
        if let fastqURL {
            let projectURL = fastqURL.deletingLastPathComponent()
            orientProjectReferences = ReferenceSequenceFolder.listReferences(in: projectURL)
            for ref in orientProjectReferences {
                orientReferencePopup.addItem(withTitle: ref.manifest.name)
            }
        }

        if orientProjectReferences.isEmpty {
            orientReferencePopup.addItem(withTitle: "No project references")
            orientReferencePopup.isEnabled = false
        } else {
            orientReferencePopup.isEnabled = true
        }

        // If an external reference was previously selected, show it
        if let orientReferenceURL, !ReferenceSequenceFolder.isProjectReference(orientReferenceURL, in: fastqURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")) {
            orientReferencePopup.addItem(withTitle: orientReferenceURL.lastPathComponent)
            orientReferencePopup.selectItem(at: orientReferencePopup.numberOfItems - 1)
            orientReferencePopup.isEnabled = true
        }
    }

    @objc private func orientReferenceChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if index >= 0, index < orientProjectReferences.count {
            let ref = orientProjectReferences[index]
            orientReferenceURL = ReferenceSequenceFolder.fastaURL(in: ref.url)
            statusLabel.stringValue = "Selected reference: \(ref.manifest.name)"
        }
    }

    @objc private func orientBrowseClicked(_ sender: NSButton) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Select a reference FASTA file (.fasta, .fa, .fna)"
        panel.prompt = "Select"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self.orientReferenceURL = url
                self.rebuildOrientReferencePopup()
                // Select the browsed file (added as last item)
                if !self.orientProjectReferences.isEmpty || self.orientReferencePopup.numberOfItems > 0 {
                    self.orientReferencePopup.selectItem(at: self.orientReferencePopup.numberOfItems - 1)
                }
                self.orientReferencePopup.isEnabled = true
                self.statusLabel.stringValue = "Selected external reference: \(url.lastPathComponent)"
            }
        }
    }

    @objc private func orientRunClicked(_ sender: NSButton) {
        guard let orientReferenceURL else {
            statusLabel.stringValue = "Select a reference FASTA before running orient."
            return
        }
        guard let fastqURL else {
            statusLabel.stringValue = "No FASTQ file loaded."
            return
        }

        let wordLength = Int(orientWordLengthField.stringValue) ?? 12
        let dbMask = orientMaskPopup.titleOfSelectedItem ?? "dust"
        let saveUnoriented = orientSaveUnorientedCheckbox.state == .on

        // Import external reference into project if needed
        let projectURL = fastqURL.deletingLastPathComponent()
        var refURL = orientReferenceURL
        if !ReferenceSequenceFolder.isProjectReference(orientReferenceURL, in: projectURL) {
            do {
                let bundle = try ReferenceSequenceFolder.importReference(from: orientReferenceURL, into: projectURL)
                if let fastaInBundle = ReferenceSequenceFolder.fastaURL(in: bundle) {
                    refURL = fastaInBundle
                }
                statusLabel.stringValue = "Imported reference into project. Starting orient..."
            } catch {
                statusLabel.stringValue = "Failed to import reference: \(error.localizedDescription)"
                return
            }
        }

        // Post notification for the dataset view controller to pick up and execute
        NotificationCenter.default.post(
            name: .fastqOrientRequested,
            object: self,
            userInfo: [
                "fastqURL": fastqURL,
                "referenceURL": refURL,
                "wordLength": wordLength,
                "dbMask": dbMask,
                "saveUnoriented": saveUnoriented,
            ]
        )
        statusLabel.stringValue = "Orient pipeline started..."
        orientRunButton.isEnabled = false
    }

    /// Re-enables the orient button after pipeline completes.
    public func orientPipelineDidFinish(message: String) {
        orientRunButton.isEnabled = true
        statusLabel.stringValue = message
        rebuildOrientReferencePopup()
    }

    // MARK: - Barcode Detail Copy Support

    private func buildKitDetailContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Selected Barcodes", action: #selector(copySelectedBarcodes(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Barcode IDs", action: #selector(copyBarcodeIDs(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Sequences", action: #selector(copyBarcodeSequences(_:)), keyEquivalent: "")
        return menu
    }

    /// Standard copy: responder for Cmd+C.
    @objc func copy(_ sender: Any?) {
        guard window?.firstResponder === kitDetailTable else { return }
        copySelectedBarcodes(sender)
    }

    @objc private func copySelectedBarcodes(_ sender: Any?) {
        let rows = kitDetailTable.selectedRowIndexes
        guard !rows.isEmpty else { return }
        var lines: [String] = ["ID\tSequence\tSecondary"]
        for row in rows {
            guard row < selectedKitBarcodes.count else { continue }
            let bc = selectedKitBarcodes[row]
            lines.append("\(bc.id)\t\(bc.i7Sequence)\t\(bc.i5Sequence ?? "")")
        }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLabel.stringValue = "Copied \(rows.count) barcode(s) to clipboard."
    }

    @objc private func copyBarcodeIDs(_ sender: Any?) {
        let rows = kitDetailTable.selectedRowIndexes
        guard !rows.isEmpty else { return }
        let ids = rows.compactMap { row -> String? in
            guard row < selectedKitBarcodes.count else { return nil }
            return selectedKitBarcodes[row].id
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ids.joined(separator: "\n"), forType: .string)
        statusLabel.stringValue = "Copied \(ids.count) barcode ID(s) to clipboard."
    }

    @objc private func copyBarcodeSequences(_ sender: Any?) {
        let rows = kitDetailTable.selectedRowIndexes
        guard !rows.isEmpty else { return }
        var lines: [String] = []
        for row in rows {
            guard row < selectedKitBarcodes.count else { continue }
            lines.append(selectedKitBarcodes[row].i7Sequence)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        statusLabel.stringValue = "Copied \(lines.count) sequence(s) to clipboard."
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copySelectedBarcodes(_:))
            || menuItem.action == #selector(copyBarcodeIDs(_:))
            || menuItem.action == #selector(copyBarcodeSequences(_:)) {
            return !kitDetailTable.selectedRowIndexes.isEmpty
        }
        return true
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
