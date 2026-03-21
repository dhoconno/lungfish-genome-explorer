// FASTQMetadataDrawerView.swift - Bottom drawer for FASTQ sample/barcode metadata
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow
import UniformTypeIdentifiers

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
        case demux = 1
        case primerTrim = 2
        case dedup = 3
    }

    // Tag constants for distinguishing table views in data source/delegate
    private static let mainTableTag = 100
    private static let kitDetailTableTag = 101
    private var isSuppressingDelegateCallbacks = false

    private weak var delegate: FASTQMetadataDrawerViewDelegate?

    private var fastqURL: URL?
    private var activeTab: Tab = .samples
    private var sampleAssignments: [FASTQSampleBarcodeAssignment] = []
    private var customBarcodeSets: [BarcodeKitDefinition] = []
    private var preferredBarcodeSetID: String?
    private var preferredSetIDByPopupIndex: [Int: String] = [:]

    // Demux state
    private var demuxSteps: [DemultiplexStep] = []
    private var compositeSampleNames: [String: String] = [:]
    private var primerTrimConfiguration: FASTQPrimerTrimConfiguration?

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

    // Inline kit reference split
    private let kitDetailScrollView = NSScrollView()
    private let kitDetailTable = NSTableView()
    private let kitDetailLabel = NSTextField(labelWithString: "Select a kit to view its barcodes.")

    // Demux: config panel + pattern table + inline kit reference
    private let stepDetailContainer = NSView()
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
    private let stepTrimCheckbox = NSButton(checkboxWithTitle: "Trim barcodes during demux", target: nil, action: nil)
    private let stepDistance5Label = NSTextField(labelWithString: "5' Window:")
    private let stepDistance5Field = NSTextField(string: "0")
    private let stepDistance3Label = NSTextField(labelWithString: "3' Window:")
    private let stepDistance3Field = NSTextField(string: "0")
    private let stepMinInsertLabel = NSTextField(labelWithString: "Min Insert:")
    private let stepMinInsertField = NSTextField(string: "2000")
    private let stepScoutButton = NSButton(title: "Detect", target: nil, action: nil)
    private let stepImportKitButton = NSButton(title: "Import Project Kit CSV", target: nil, action: nil)
    private let stepRemoveKitButton = NSButton(title: "Remove Custom Kit", target: nil, action: nil)
    private var patternLabelTopToCutadapt: NSLayoutConstraint!
    private var patternLabelTopToInsert: NSLayoutConstraint!
    private let demuxAdvancedDisclosure = NSButton(checkboxWithTitle: "Advanced", target: nil, action: nil)
    private let demuxSimpleSummaryLabel = NSTextField(labelWithString: "Outputs will be created per detected barcode.")
    private let demuxPatternLabel = NSTextField(labelWithString: "Pattern:")

    // Primer Trim tab
    private let primerTrimContainer = NSView()
    private let primerSourceLabel = NSTextField(labelWithString: "Source:")
    private let primerSourcePopup = NSPopUpButton()
    private let primerReadModeLabel = NSTextField(labelWithString: "Reads:")
    private let primerReadModePopup = NSPopUpButton()
    private let primerModeLabel = NSTextField(labelWithString: "Mode:")
    private let primerModePopup = NSPopUpButton()
    private let primerForwardLabel = NSTextField(labelWithString: "5'/R1 Primer:")
    private let primerForwardField = NSTextField(string: "")
    private let primerReverseLabel = NSTextField(labelWithString: "3'/R2 Primer:")
    private let primerReverseField = NSTextField(string: "")
    private let primerReferenceLabel = NSTextField(labelWithString: "Reference FASTA:")
    private let primerReferenceField = NSTextField(string: "")
    private let primerOverlapLabel = NSTextField(labelWithString: "Min Overlap:")
    private let primerOverlapField = NSTextField(string: "12")
    private let primerErrorLabel = NSTextField(labelWithString: "Error Rate:")
    private let primerErrorField = NSTextField(string: "0.12")
    private let primerAnchored5Checkbox = NSButton(checkboxWithTitle: "Anchor 5' primer", target: nil, action: nil)
    private let primerAnchored3Checkbox = NSButton(checkboxWithTitle: "Anchor 3' primer", target: nil, action: nil)
    private let primerAllowIndelsCheckbox = NSButton(checkboxWithTitle: "Allow indels", target: nil, action: nil)
    private let primerKeepUntrimmedCheckbox = NSButton(checkboxWithTitle: "Keep unmatched reads", target: nil, action: nil)
    private let primerRevcompCheckbox = NSButton(checkboxWithTitle: "Search reverse complement", target: nil, action: nil)
    private let primerPairFilterLabel = NSTextField(labelWithString: "Pair Filter:")
    private let primerPairFilterPopup = NSPopUpButton()
    private let primerToolLabel = NSTextField(labelWithString: "Tool:")
    private let primerToolPopup = NSPopUpButton()
    private let primerKtrimLabel = NSTextField(labelWithString: "Trim Direction:")
    private let primerKtrimPopup = NSPopUpButton()
    private let primerKmerLabel = NSTextField(labelWithString: "K-mer Size:")
    private let primerKmerField = NSTextField(string: "15")
    private let primerMinKmerLabel = NSTextField(labelWithString: "Min K-mer:")
    private let primerMinKmerField = NSTextField(string: "11")
    private let primerHdistLabel = NSTextField(labelWithString: "Hamming Dist:")
    private let primerHdistField = NSTextField(string: "1")

    // Dedup tab
    private let dedupContainer = NSView()
    private let dedupPresetLabel = NSTextField(labelWithString: "Preset:")
    private let dedupPresetPopup = NSPopUpButton()
    private let dedupSubsLabel = NSTextField(labelWithString: "Substitution Tolerance:")
    private let dedupSubsField = NSTextField(string: "0")
    private let dedupOpticalCheckbox = NSButton(checkboxWithTitle: "Optical duplicates only", target: nil, action: nil)
    private let dedupDistLabel = NSTextField(labelWithString: "Pixel Distance:")
    private let dedupDistField = NSTextField(string: "40")
    private let dedupDescriptionLabel = NSTextField(wrappingLabelWithString: "")

    /// Callback invoked when dedup configuration changes.
    public var onDedupConfigChanged: ((FASTQDeduplicatePreset, Int, Bool, Int) -> Void)?

    // Constraint groups toggled per-tab
    private var samplesConstraints: [NSLayoutConstraint] = []
    private var demuxSetupConstraints: [NSLayoutConstraint] = []
    private var primerTrimConstraints: [NSLayoutConstraint] = []
    private var dedupConstraints: [NSLayoutConstraint] = []
    private var isDemuxAdvancedEnabled = false

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
                    demuxSteps = Array(plan.steps.sorted(by: { $0.ordinal < $1.ordinal }).prefix(1))
                    for index in demuxSteps.indices {
                        demuxSteps[index].ordinal = index
                    }
                    compositeSampleNames = plan.compositeSampleNames
                } else {
                    demuxSteps = []
                    compositeSampleNames = [:]
                }
            } else {
                demuxSteps = []
                compositeSampleNames = [:]
            }
            if let primerJSON = metadata.primerTrimConfigJSON {
                primerTrimConfiguration = decodePrimerTrimConfiguration(from: primerJSON)
            } else {
                primerTrimConfiguration = nil
            }
        } else {
            sampleAssignments = []
            customBarcodeSets = []
            preferredBarcodeSetID = nil
            demuxSteps = []
            compositeSampleNames = [:]
            primerTrimConfiguration = nil
        }
        allKits = BarcodeKitRegistry.builtinKits() + customBarcodeSets
        ensureSingleDemuxStep()
        rebuildPreferredSetPopup()
        refreshSelectedKitReference()
        refreshStepDetail()
        refreshPrimerTrimControls()
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
            demuxPlanJSON: demuxPlanJSON,
            primerTrimConfigJSON: encodePrimerTrimConfigurationToJSON(primerTrimConfiguration)
        )
    }

    /// Returns the current demux plan built from the Demux tab.
    public func currentDemuxPlan() -> DemultiplexPlan {
        let singleStep = Array(demuxSteps.sorted(by: { $0.ordinal < $1.ordinal }).prefix(1))
        return DemultiplexPlan(steps: singleStep, compositeSampleNames: compositeSampleNames)
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
    public func applySampleAssignmentsToCurrentStep(_ assignments: [FASTQSampleBarcodeAssignment]) {
        ensureSingleDemuxStep()
        sampleAssignments = assignments
        demuxSteps[0].sampleAssignments = assignments
        statusLabel.stringValue = "Applied \(assignments.count) assignment(s) to the current demux pattern."
        tableView.reloadData()
        notifyDemuxPlanChanged()
    }

    /// Programmatically selects the Demux tab.
    public func selectDemuxTab() {
        tabControl.selectedSegment = Tab.demux.rawValue
        activeTab = .demux
        rebuildColumns()
    }

    public func selectPrimerTrimTab() {
        tabControl.selectedSegment = Tab.primerTrim.rawValue
        activeTab = .primerTrim
        rebuildColumns()
    }

    public func selectDedupTab() {
        tabControl.selectedSegment = Tab.dedup.rawValue
        activeTab = .dedup
        rebuildColumns()
    }

    public func currentPrimerTrimConfiguration() -> FASTQPrimerTrimConfiguration? {
        primerTrimConfiguration
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
        tabControl.setLabel("Demux", forSegment: 1)
        tabControl.setLabel("Primer Trim", forSegment: 2)
        tabControl.setLabel("Dedup", forSegment: 3)
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

        // Main table (Samples tab + Demux pattern editor)
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

        // Kit detail table (inline reference under Demux)
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

        // Demux detail panel
        stepDetailContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stepDetailContainer)
        setupStepDetailPanel()

        primerTrimContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(primerTrimContainer)
        setupPrimerTrimPanel()

        dedupContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dedupContainer)
        setupDedupPanel()

        // Status bar
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        setupConstraints()
        rebuildPreferredSetPopup()
    }

    private func setupStepDetailPanel() {
        let labels: [NSTextField] = [stepKitLabel, stepLocationLabel, stepSymmetryLabel, stepErrorLabel,
                                      stepOverlapLabel, stepDistance5Label, stepDistance3Label, demuxPatternLabel]
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

        stepMinInsertLabel.translatesAutoresizingMaskIntoConstraints = false
        stepDetailContainer.addSubview(stepMinInsertLabel)
        stepMinInsertField.controlSize = .small
        stepMinInsertField.translatesAutoresizingMaskIntoConstraints = false
        stepMinInsertField.alignment = .right
        stepMinInsertField.target = self
        stepMinInsertField.action = #selector(stepDetailChanged(_:))
        let insertFormatter = NumberFormatter()
        insertFormatter.numberStyle = .none
        insertFormatter.minimum = 0
        insertFormatter.maximum = 50000
        insertFormatter.allowsFloats = false
        stepMinInsertField.formatter = insertFormatter
        stepMinInsertField.setAccessibilityLabel("Minimum insert length between barcode hits")
        stepDetailContainer.addSubview(stepMinInsertField)

        stepScoutButton.bezelStyle = .rounded
        stepScoutButton.controlSize = .small
        stepScoutButton.translatesAutoresizingMaskIntoConstraints = false
        stepScoutButton.target = self
        stepScoutButton.action = #selector(stepScoutClicked(_:))
        stepDetailContainer.addSubview(stepScoutButton)

        for button in [stepImportKitButton, stepRemoveKitButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
            stepDetailContainer.addSubview(button)
        }
        stepImportKitButton.target = self
        stepImportKitButton.action = #selector(importCustomKitClicked(_:))
        stepRemoveKitButton.target = self
        stepRemoveKitButton.action = #selector(removeCurrentCustomKitClicked(_:))

        demuxAdvancedDisclosure.controlSize = .small
        demuxAdvancedDisclosure.translatesAutoresizingMaskIntoConstraints = false
        demuxAdvancedDisclosure.target = self
        demuxAdvancedDisclosure.action = #selector(demuxAdvancedToggled(_:))
        stepDetailContainer.addSubview(demuxAdvancedDisclosure)

        demuxSimpleSummaryLabel.font = .systemFont(ofSize: 11)
        demuxSimpleSummaryLabel.textColor = .secondaryLabelColor
        demuxSimpleSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        stepDetailContainer.addSubview(demuxSimpleSummaryLabel)

        // Accessibility labels for step detail controls
        stepKitPopup.setAccessibilityLabel("Step barcode kit")
        stepLocationControl.setAccessibilityLabel("Barcode location")
        stepSymmetryPopup.setAccessibilityLabel("Barcode symmetry mode")
        stepErrorRateField.setAccessibilityLabel("Error rate")
        stepOverlapField.setAccessibilityLabel("Minimum overlap")
        stepIndelsCheckbox.setAccessibilityLabel("Allow indels in barcode matching")
        stepTrimCheckbox.setAccessibilityLabel("Trim barcodes from reads during demux (off = classify only)")
        stepDistance5Field.setAccessibilityLabel("Maximum search distance from 5-prime end")
        stepDistance3Field.setAccessibilityLabel("Maximum search distance from 3-prime end")
        stepScoutButton.setAccessibilityLabel("Detect barcode matches")
        stepImportKitButton.setAccessibilityLabel("Import custom barcode kit CSV")
        stepRemoveKitButton.setAccessibilityLabel("Remove selected custom barcode kit")
        demuxAdvancedDisclosure.setAccessibilityLabel("Show advanced demultiplexing options")
        kitDetailTable.setAccessibilityLabel("Barcode sequences")

        demuxPatternLabel.stringValue = "Pattern: edit sample rows below."

        stepKitPopup.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        stepSymmetryPopup.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let kitMinWidth = stepKitPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140)
        kitMinWidth.priority = .defaultHigh
        let symMinWidth = stepSymmetryPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        symMinWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // Row 1: Kit
            stepKitLabel.topAnchor.constraint(equalTo: stepDetailContainer.topAnchor, constant: 6),
            stepKitLabel.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),
            stepKitPopup.centerYAnchor.constraint(equalTo: stepKitLabel.centerYAnchor),
            stepKitPopup.leadingAnchor.constraint(equalTo: stepKitLabel.trailingAnchor, constant: 4),
            kitMinWidth,
            stepImportKitButton.centerYAnchor.constraint(equalTo: stepKitLabel.centerYAnchor),
            stepImportKitButton.leadingAnchor.constraint(equalTo: stepKitPopup.trailingAnchor, constant: 8),
            stepRemoveKitButton.centerYAnchor.constraint(equalTo: stepKitLabel.centerYAnchor),
            stepRemoveKitButton.leadingAnchor.constraint(equalTo: stepImportKitButton.trailingAnchor, constant: 6),
            stepRemoveKitButton.trailingAnchor.constraint(lessThanOrEqualTo: stepDetailContainer.trailingAnchor, constant: -8),

            demuxAdvancedDisclosure.topAnchor.constraint(equalTo: stepKitLabel.bottomAnchor, constant: 8),
            demuxAdvancedDisclosure.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),
            demuxSimpleSummaryLabel.centerYAnchor.constraint(equalTo: demuxAdvancedDisclosure.centerYAnchor),
            demuxSimpleSummaryLabel.leadingAnchor.constraint(equalTo: demuxAdvancedDisclosure.trailingAnchor, constant: 12),
            demuxSimpleSummaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: stepDetailContainer.trailingAnchor, constant: -8),

            // Row 3: Location + Symmetry
            stepLocationLabel.topAnchor.constraint(equalTo: demuxAdvancedDisclosure.bottomAnchor, constant: 8),
            stepLocationLabel.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),
            stepLocationControl.centerYAnchor.constraint(equalTo: stepLocationLabel.centerYAnchor),
            stepLocationControl.leadingAnchor.constraint(equalTo: stepLocationLabel.trailingAnchor, constant: 4),

            stepSymmetryLabel.centerYAnchor.constraint(equalTo: stepLocationLabel.centerYAnchor),
            stepSymmetryLabel.leadingAnchor.constraint(equalTo: stepLocationControl.trailingAnchor, constant: 16),
            stepSymmetryPopup.centerYAnchor.constraint(equalTo: stepSymmetryLabel.centerYAnchor),
            stepSymmetryPopup.leadingAnchor.constraint(equalTo: stepSymmetryLabel.trailingAnchor, constant: 4),
            symMinWidth,
            stepSymmetryPopup.trailingAnchor.constraint(lessThanOrEqualTo: stepDetailContainer.trailingAnchor, constant: -8),

            // Row 4: Error Rate + Min Overlap
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

            // Row 5: Allow Indels + Trim + Scout
            stepIndelsCheckbox.topAnchor.constraint(equalTo: stepErrorLabel.bottomAnchor, constant: 8),
            stepIndelsCheckbox.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),

            stepTrimCheckbox.centerYAnchor.constraint(equalTo: stepIndelsCheckbox.centerYAnchor),
            stepTrimCheckbox.leadingAnchor.constraint(equalTo: stepIndelsCheckbox.trailingAnchor, constant: 16),

            stepScoutButton.centerYAnchor.constraint(equalTo: stepIndelsCheckbox.centerYAnchor),
            stepScoutButton.trailingAnchor.constraint(equalTo: stepDetailContainer.trailingAnchor, constant: -8),

            // Row 6: 5' Window + 3' Window
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

            // Row 4b: Min Insert (asymmetric mode only, same vertical position as Error Rate row)
            stepMinInsertLabel.topAnchor.constraint(equalTo: stepLocationLabel.bottomAnchor, constant: 8),
            stepMinInsertLabel.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),
            stepMinInsertField.centerYAnchor.constraint(equalTo: stepMinInsertLabel.centerYAnchor),
            stepMinInsertField.leadingAnchor.constraint(equalTo: stepMinInsertLabel.trailingAnchor, constant: 4),
            stepMinInsertField.widthAnchor.constraint(equalToConstant: 60),

            demuxPatternLabel.leadingAnchor.constraint(equalTo: stepDetailContainer.leadingAnchor, constant: 8),
            demuxPatternLabel.bottomAnchor.constraint(equalTo: stepDetailContainer.bottomAnchor, constant: -6),
        ])

        // Switchable top anchor for demuxPatternLabel:
        // - cutadapt mode: anchored below 5' Window row
        // - asymmetric mode: anchored below Min Insert row
        patternLabelTopToCutadapt = demuxPatternLabel.topAnchor.constraint(equalTo: stepDistance5Label.bottomAnchor, constant: 10)
        patternLabelTopToInsert = demuxPatternLabel.topAnchor.constraint(equalTo: stepMinInsertLabel.bottomAnchor, constant: 10)
        patternLabelTopToCutadapt.isActive = true
    }

    private func setupPrimerTrimPanel() {
        let labels: [NSTextField] = [
            primerSourceLabel, primerReadModeLabel, primerModeLabel,
            primerForwardLabel, primerReverseLabel, primerReferenceLabel,
            primerOverlapLabel, primerErrorLabel, primerPairFilterLabel,
            primerToolLabel, primerKtrimLabel, primerKmerLabel,
            primerMinKmerLabel, primerHdistLabel,
        ]
        for label in labels {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            primerTrimContainer.addSubview(label)
        }

        primerToolPopup.addItems(withTitles: ["cutadapt", "bbduk"])
        primerSourcePopup.addItems(withTitles: ["Literal Sequences", "Reference FASTA"])
        primerReadModePopup.addItems(withTitles: ["Single Reads", "Paired / Interleaved"])
        primerModePopup.addItems(withTitles: ["5' Primer", "3' Primer", "Linked 5'+3'", "Paired R1/R2"])
        primerPairFilterPopup.addItems(withTitles: ["Any", "Both", "First"])
        primerKtrimPopup.addItems(withTitles: ["5' (left)", "3' (right)"])

        let popups: [NSPopUpButton] = [primerToolPopup, primerSourcePopup, primerReadModePopup, primerModePopup, primerPairFilterPopup, primerKtrimPopup]
        for popup in popups {
            popup.controlSize = .small
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.target = self
            popup.action = #selector(primerTrimControlChanged(_:))
            primerTrimContainer.addSubview(popup)
        }

        let fields: [NSTextField] = [primerForwardField, primerReverseField, primerReferenceField, primerOverlapField, primerErrorField, primerKmerField, primerMinKmerField, primerHdistField]
        for field in fields {
            field.controlSize = .small
            field.translatesAutoresizingMaskIntoConstraints = false
            field.target = self
            field.action = #selector(primerTrimControlChanged(_:))
            primerTrimContainer.addSubview(field)
        }

        let checkboxes: [NSButton] = [
            primerAnchored5Checkbox, primerAnchored3Checkbox, primerAllowIndelsCheckbox,
            primerKeepUntrimmedCheckbox, primerRevcompCheckbox,
        ]
        for checkbox in checkboxes {
            checkbox.controlSize = .small
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            checkbox.target = self
            checkbox.action = #selector(primerTrimControlChanged(_:))
            primerTrimContainer.addSubview(checkbox)
        }

        primerAnchored5Checkbox.state = .on
        primerAnchored3Checkbox.state = .on
        primerAllowIndelsCheckbox.state = .on

        NSLayoutConstraint.activate([
            // Row 0: Tool selector
            primerToolLabel.topAnchor.constraint(equalTo: primerTrimContainer.topAnchor, constant: 10),
            primerToolLabel.leadingAnchor.constraint(equalTo: primerTrimContainer.leadingAnchor, constant: 8),
            primerToolPopup.centerYAnchor.constraint(equalTo: primerToolLabel.centerYAnchor),
            primerToolPopup.leadingAnchor.constraint(equalTo: primerToolLabel.trailingAnchor, constant: 6),

            // Row 1: Source + Read Mode (cutadapt) or Ktrim Direction (bbduk)
            primerSourceLabel.topAnchor.constraint(equalTo: primerToolLabel.bottomAnchor, constant: 10),
            primerSourceLabel.leadingAnchor.constraint(equalTo: primerTrimContainer.leadingAnchor, constant: 8),
            primerSourcePopup.centerYAnchor.constraint(equalTo: primerSourceLabel.centerYAnchor),
            primerSourcePopup.leadingAnchor.constraint(equalTo: primerSourceLabel.trailingAnchor, constant: 6),

            primerReadModeLabel.centerYAnchor.constraint(equalTo: primerSourceLabel.centerYAnchor),
            primerReadModeLabel.leadingAnchor.constraint(equalTo: primerSourcePopup.trailingAnchor, constant: 18),
            primerReadModePopup.centerYAnchor.constraint(equalTo: primerReadModeLabel.centerYAnchor),
            primerReadModePopup.leadingAnchor.constraint(equalTo: primerReadModeLabel.trailingAnchor, constant: 6),

            // BBDuk: ktrim direction on same row as source
            primerKtrimLabel.centerYAnchor.constraint(equalTo: primerSourceLabel.centerYAnchor),
            primerKtrimLabel.leadingAnchor.constraint(equalTo: primerSourcePopup.trailingAnchor, constant: 18),
            primerKtrimPopup.centerYAnchor.constraint(equalTo: primerKtrimLabel.centerYAnchor),
            primerKtrimPopup.leadingAnchor.constraint(equalTo: primerKtrimLabel.trailingAnchor, constant: 6),

            primerModeLabel.topAnchor.constraint(equalTo: primerSourceLabel.bottomAnchor, constant: 10),
            primerModeLabel.leadingAnchor.constraint(equalTo: primerTrimContainer.leadingAnchor, constant: 8),
            primerModePopup.centerYAnchor.constraint(equalTo: primerModeLabel.centerYAnchor),
            primerModePopup.leadingAnchor.constraint(equalTo: primerModeLabel.trailingAnchor, constant: 6),

            primerForwardLabel.topAnchor.constraint(equalTo: primerModeLabel.bottomAnchor, constant: 10),
            primerForwardLabel.leadingAnchor.constraint(equalTo: primerTrimContainer.leadingAnchor, constant: 8),
            primerForwardField.centerYAnchor.constraint(equalTo: primerForwardLabel.centerYAnchor),
            primerForwardField.leadingAnchor.constraint(equalTo: primerForwardLabel.trailingAnchor, constant: 6),
            primerForwardField.widthAnchor.constraint(equalToConstant: 250),

            primerReverseLabel.centerYAnchor.constraint(equalTo: primerForwardLabel.centerYAnchor),
            primerReverseLabel.leadingAnchor.constraint(equalTo: primerForwardField.trailingAnchor, constant: 16),
            primerReverseField.centerYAnchor.constraint(equalTo: primerReverseLabel.centerYAnchor),
            primerReverseField.leadingAnchor.constraint(equalTo: primerReverseLabel.trailingAnchor, constant: 6),
            primerReverseField.widthAnchor.constraint(equalToConstant: 250),

            primerReferenceLabel.topAnchor.constraint(equalTo: primerForwardLabel.bottomAnchor, constant: 10),
            primerReferenceLabel.leadingAnchor.constraint(equalTo: primerTrimContainer.leadingAnchor, constant: 8),
            primerReferenceField.centerYAnchor.constraint(equalTo: primerReferenceLabel.centerYAnchor),
            primerReferenceField.leadingAnchor.constraint(equalTo: primerReferenceLabel.trailingAnchor, constant: 6),
            primerReferenceField.widthAnchor.constraint(equalToConstant: 420),

            primerOverlapLabel.topAnchor.constraint(equalTo: primerReferenceLabel.bottomAnchor, constant: 10),
            primerOverlapLabel.leadingAnchor.constraint(equalTo: primerTrimContainer.leadingAnchor, constant: 8),
            primerOverlapField.centerYAnchor.constraint(equalTo: primerOverlapLabel.centerYAnchor),
            primerOverlapField.leadingAnchor.constraint(equalTo: primerOverlapLabel.trailingAnchor, constant: 6),
            primerOverlapField.widthAnchor.constraint(equalToConstant: 54),

            primerErrorLabel.centerYAnchor.constraint(equalTo: primerOverlapLabel.centerYAnchor),
            primerErrorLabel.leadingAnchor.constraint(equalTo: primerOverlapField.trailingAnchor, constant: 16),
            primerErrorField.centerYAnchor.constraint(equalTo: primerErrorLabel.centerYAnchor),
            primerErrorField.leadingAnchor.constraint(equalTo: primerErrorLabel.trailingAnchor, constant: 6),
            primerErrorField.widthAnchor.constraint(equalToConstant: 54),

            primerPairFilterLabel.centerYAnchor.constraint(equalTo: primerOverlapLabel.centerYAnchor),
            primerPairFilterLabel.leadingAnchor.constraint(equalTo: primerErrorField.trailingAnchor, constant: 16),
            primerPairFilterPopup.centerYAnchor.constraint(equalTo: primerPairFilterLabel.centerYAnchor),
            primerPairFilterPopup.leadingAnchor.constraint(equalTo: primerPairFilterLabel.trailingAnchor, constant: 6),

            primerAnchored5Checkbox.topAnchor.constraint(equalTo: primerOverlapLabel.bottomAnchor, constant: 10),
            primerAnchored5Checkbox.leadingAnchor.constraint(equalTo: primerTrimContainer.leadingAnchor, constant: 8),
            primerAnchored3Checkbox.centerYAnchor.constraint(equalTo: primerAnchored5Checkbox.centerYAnchor),
            primerAnchored3Checkbox.leadingAnchor.constraint(equalTo: primerAnchored5Checkbox.trailingAnchor, constant: 16),
            primerAllowIndelsCheckbox.centerYAnchor.constraint(equalTo: primerAnchored5Checkbox.centerYAnchor),
            primerAllowIndelsCheckbox.leadingAnchor.constraint(equalTo: primerAnchored3Checkbox.trailingAnchor, constant: 16),

            primerKeepUntrimmedCheckbox.topAnchor.constraint(equalTo: primerAnchored5Checkbox.bottomAnchor, constant: 10),
            primerKeepUntrimmedCheckbox.leadingAnchor.constraint(equalTo: primerTrimContainer.leadingAnchor, constant: 8),
            primerRevcompCheckbox.centerYAnchor.constraint(equalTo: primerKeepUntrimmedCheckbox.centerYAnchor),
            primerRevcompCheckbox.leadingAnchor.constraint(equalTo: primerKeepUntrimmedCheckbox.trailingAnchor, constant: 16),

            // BBDuk k-mer parameters row (below checkboxes, same row as overlap/error for cutadapt)
            primerKmerLabel.topAnchor.constraint(equalTo: primerKeepUntrimmedCheckbox.bottomAnchor, constant: 10),
            primerKmerLabel.leadingAnchor.constraint(equalTo: primerTrimContainer.leadingAnchor, constant: 8),
            primerKmerField.centerYAnchor.constraint(equalTo: primerKmerLabel.centerYAnchor),
            primerKmerField.leadingAnchor.constraint(equalTo: primerKmerLabel.trailingAnchor, constant: 6),
            primerKmerField.widthAnchor.constraint(equalToConstant: 44),

            primerMinKmerLabel.centerYAnchor.constraint(equalTo: primerKmerLabel.centerYAnchor),
            primerMinKmerLabel.leadingAnchor.constraint(equalTo: primerKmerField.trailingAnchor, constant: 16),
            primerMinKmerField.centerYAnchor.constraint(equalTo: primerMinKmerLabel.centerYAnchor),
            primerMinKmerField.leadingAnchor.constraint(equalTo: primerMinKmerLabel.trailingAnchor, constant: 6),
            primerMinKmerField.widthAnchor.constraint(equalToConstant: 44),

            primerHdistLabel.centerYAnchor.constraint(equalTo: primerKmerLabel.centerYAnchor),
            primerHdistLabel.leadingAnchor.constraint(equalTo: primerMinKmerField.trailingAnchor, constant: 16),
            primerHdistField.centerYAnchor.constraint(equalTo: primerHdistLabel.centerYAnchor),
            primerHdistField.leadingAnchor.constraint(equalTo: primerHdistLabel.trailingAnchor, constant: 6),
            primerHdistField.widthAnchor.constraint(equalToConstant: 44),
        ])
    }

    // Orient tab removed — orient is now a standalone operation in the FASTQ operations sidebar.

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

        // Demux tab constraints (config top, pattern editor middle, kit reference bottom)
        let patternHeightConstraint = scrollView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.32)
        patternHeightConstraint.priority = NSLayoutConstraint.Priority(749)
        let patternMinHeight = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 90)
        patternMinHeight.priority = .defaultHigh
        let kitDetailMinHeightConstraint = kitDetailScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        kitDetailMinHeightConstraint.priority = .defaultHigh
        demuxSetupConstraints = [
            stepDetailContainer.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 6),
            stepDetailContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stepDetailContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            
            scrollView.topAnchor.constraint(equalTo: stepDetailContainer.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            patternMinHeight,
            patternHeightConstraint,

            kitDetailLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            kitDetailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),

            kitDetailScrollView.topAnchor.constraint(equalTo: kitDetailLabel.bottomAnchor, constant: 2),
            kitDetailScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            kitDetailScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            kitDetailScrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            kitDetailMinHeightConstraint,
        ]

        primerTrimConstraints = [
            primerTrimContainer.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 6),
            primerTrimContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            primerTrimContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            primerTrimContainer.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
        ]

        dedupConstraints = [
            dedupContainer.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 6),
            dedupContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dedupContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dedupContainer.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
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
        NSLayoutConstraint.deactivate(demuxSetupConstraints)
        NSLayoutConstraint.deactivate(primerTrimConstraints)
        NSLayoutConstraint.deactivate(dedupConstraints)
        // Hide everything first
        scrollView.isHidden = true
        kitDetailScrollView.isHidden = true
        kitDetailLabel.isHidden = true
        stepDetailContainer.isHidden = true
        primerTrimContainer.isHidden = true
        dedupContainer.isHidden = true

        // Header bar button visibility
        preferredSetLabel.isHidden = true
        preferredSetPopup.isHidden = true
        addButton.isHidden = true
        removeButton.isHidden = true
        importButton.isHidden = true
        exportButton.isHidden = true
        saveButton.title = "Save to Project Dataset"
        saveButton.toolTip = "Save demux settings, custom kits, and primer-trim metadata with this project dataset only"
        importButton.title = "Import CSV"
        exportButton.title = "Export CSV"

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

        case .demux:
            stepDetailContainer.isHidden = false
            let showAdvanced = isDemuxAdvancedEnabled
            scrollView.isHidden = !showAdvanced
            kitDetailScrollView.isHidden = !showAdvanced
            kitDetailLabel.isHidden = !showAdvanced
            addButton.isHidden = !showAdvanced
            removeButton.isHidden = !showAdvanced
            importButton.isHidden = !showAdvanced
            exportButton.isHidden = !showAdvanced
            importButton.title = "Import Pattern"
            exportButton.title = "Export Pattern"
            NSLayoutConstraint.activate(demuxSetupConstraints)
            if showAdvanced {
                tableView.reloadData()
            }
            refreshSelectedKitReference()
            refreshStepDetail()
        case .primerTrim:
            primerTrimContainer.isHidden = false
            NSLayoutConstraint.activate(primerTrimConstraints)
            refreshPrimerTrimControls()
        case .dedup:
            dedupContainer.isHidden = false
            NSLayoutConstraint.activate(dedupConstraints)
            refreshDedupControls()
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

        case .demux:
            ensureSingleDemuxStep()
            let isAsymmetric = demuxSteps[0].symmetryMode == .asymmetric
            addColumn(to: tableView, id: "sampleID", title: "Sample", width: 140, editable: true)
            addColumn(to: tableView, id: "sampleName", title: "Name", width: 140, editable: true)
            if isAsymmetric {
                // Asymmetric mode: just barcode IDs (no 5'/3' — all orientations are searched)
                addColumn(to: tableView, id: "forwardBarcodeID", title: "Barcode 1", width: 120, editable: true)
                addColumn(to: tableView, id: "reverseBarcodeID", title: "Barcode 2", width: 120, editable: true)
            } else {
                addColumn(to: tableView, id: "forwardBarcodeID", title: "5' Barcode ID", width: 120, editable: true)
                addColumn(to: tableView, id: "forwardSequence", title: "5' Sequence", width: 190, editable: true)
                addColumn(to: tableView, id: "reverseBarcodeID", title: "3' Barcode ID", width: 120, editable: true)
                addColumn(to: tableView, id: "reverseSequence", title: "3' Sequence", width: 190, editable: true)
            }

            addColumn(to: kitDetailTable, id: "bcID", title: "ID", width: 80, editable: false)
            addColumn(to: kitDetailTable, id: "bcSequence", title: "Sequence", width: 260, editable: false)
            addColumn(to: kitDetailTable, id: "bcSecondary", title: "Secondary", width: 260, editable: false)
        case .primerTrim, .dedup:
            break
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
            case .samples, .demux: return sampleAssignments.count
            case .primerTrim, .dedup: return 0
            }
        case Self.kitDetailTableTag:
            return selectedKitBarcodes.count
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
        default:
            return nil
        }
    }

    private func mainTableValue(column: String, row: Int) -> Any? {
        switch activeTab {
        case .samples, .demux:
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
        case .primerTrim, .dedup:
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

    // MARK: - NSTableViewDelegate

    public func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let tableColumn, let value = object as? String else { return }

        switch tableView.tag {
        case Self.mainTableTag:
            setMainTableValue(column: tableColumn.identifier.rawValue, row: row, value: value)
        default:
            break
        }
    }

    private func setMainTableValue(column: String, row: Int, value: String) {
        switch activeTab {
        case .samples, .demux:
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
            if activeTab == .demux {
                demuxSteps[0].sampleAssignments = sampleAssignments
                notifyDemuxPlanChanged()
            }

        case .primerTrim, .dedup:
            break
        }
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSuppressingDelegateCallbacks,
              let table = notification.object as? NSTableView else { return }
        switch table.tag {
        case Self.mainTableTag:
            break
        default:
            break
        }
    }

    // MARK: - Step Detail

    private func refreshStepDetail() {
        ensureSingleDemuxStep()
        let step = demuxSteps[0]
        demuxAdvancedDisclosure.state = isDemuxAdvancedEnabled ? .on : .off

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
        stepMinInsertField.stringValue = "\(step.minimumInsert)"
        updateLocationControlState()

        let isAsymmetric = step.symmetryMode == .asymmetric

        // Cutadapt-specific controls: hidden when asymmetric or when advanced is off
        let cutadaptViews: [NSView] = [
            stepErrorLabel, stepErrorRateField,
            stepOverlapLabel, stepOverlapField,
            stepIndelsCheckbox, stepTrimCheckbox,
            stepDistance5Label, stepDistance5Field,
            stepDistance3Label, stepDistance3Field,
        ]
        for view in cutadaptViews {
            view.isHidden = !isDemuxAdvancedEnabled || isAsymmetric
        }

        // Min Insert controls: shown only in asymmetric + advanced mode
        stepMinInsertLabel.isHidden = !isDemuxAdvancedEnabled || !isAsymmetric
        stepMinInsertField.isHidden = !isDemuxAdvancedEnabled || !isAsymmetric

        // Detect (scout) button: hidden in asymmetric mode (not applicable)
        stepScoutButton.isHidden = isAsymmetric

        // Switch demuxPatternLabel anchor based on mode
        patternLabelTopToCutadapt.isActive = !isAsymmetric
        patternLabelTopToInsert.isActive = isAsymmetric

        // Always-visible advanced views (location, symmetry, pattern label)
        let alwaysAdvancedViews: [NSView] = [
            stepLocationLabel, stepLocationControl,
            stepSymmetryLabel, stepSymmetryPopup,
            demuxPatternLabel,
        ]
        for view in alwaysAdvancedViews {
            view.isHidden = !isDemuxAdvancedEnabled
        }
        demuxSimpleSummaryLabel.isHidden = isDemuxAdvancedEnabled
        if step.symmetryMode == .symmetric {
            demuxSimpleSummaryLabel.stringValue = "Outputs will be created per detected barcode ID from the selected kit."
        } else {
            demuxSimpleSummaryLabel.stringValue = "Enable Advanced to edit barcode mappings and demux parameters."
        }
        refreshSelectedKitReference()
    }

    private func refreshPrimerTrimControls() {
        let configuration = primerTrimConfiguration ?? FASTQPrimerTrimConfiguration(source: .literal)

        // Tool selector
        primerToolPopup.selectItem(at: configuration.tool == .bbduk ? 1 : 0)
        let isBBDuk = configuration.tool == .bbduk

        primerSourcePopup.selectItem(at: configuration.source == .reference ? 1 : 0)
        primerReadModePopup.selectItem(at: configuration.readMode == .paired ? 1 : 0)
        switch configuration.mode {
        case .fivePrime: primerModePopup.selectItem(at: 0)
        case .threePrime: primerModePopup.selectItem(at: 1)
        case .linked: primerModePopup.selectItem(at: 2)
        case .paired: primerModePopup.selectItem(at: 3)
        }
        primerForwardField.stringValue = configuration.forwardSequence ?? ""
        primerReverseField.stringValue = configuration.reverseSequence ?? ""
        primerReferenceField.stringValue = configuration.referenceFasta ?? ""
        primerOverlapField.stringValue = "\(configuration.minimumOverlap)"
        primerErrorField.stringValue = String(format: "%.2f", configuration.errorRate)
        primerAnchored5Checkbox.state = configuration.anchored5Prime ? .on : .off
        primerAnchored3Checkbox.state = configuration.anchored3Prime ? .on : .off
        primerAllowIndelsCheckbox.state = configuration.allowIndels ? .on : .off
        primerKeepUntrimmedCheckbox.state = configuration.keepUntrimmed ? .on : .off
        primerRevcompCheckbox.state = configuration.searchReverseComplement ? .on : .off
        switch configuration.pairFilter {
        case .any: primerPairFilterPopup.selectItem(at: 0)
        case .both: primerPairFilterPopup.selectItem(at: 1)
        case .first: primerPairFilterPopup.selectItem(at: 2)
        }

        // BBDuk-specific controls
        primerKtrimPopup.selectItem(at: configuration.ktrimDirection == .right ? 1 : 0)
        primerKmerField.stringValue = "\(configuration.kmerSize)"
        primerMinKmerField.stringValue = "\(configuration.minKmer)"
        primerHdistField.stringValue = "\(configuration.hammingDistance)"

        let isReference = configuration.source == .reference
        primerReferenceLabel.isHidden = !isReference
        primerReferenceField.isHidden = !isReference
        primerForwardLabel.isHidden = isReference
        primerForwardField.isHidden = isReference
        primerReverseLabel.isHidden = isReference
        primerReverseField.isHidden = isReference

        let isPaired = configuration.readMode == .paired
        primerPairFilterLabel.isHidden = !isPaired
        primerPairFilterPopup.isHidden = !isPaired
        primerRevcompCheckbox.isHidden = isPaired

        // Show/hide tool-specific controls
        // cutadapt-specific: mode, overlap, error, anchored, indels, read mode, pair filter, revcomp
        primerReadModeLabel.isHidden = isBBDuk
        primerReadModePopup.isHidden = isBBDuk
        primerModeLabel.isHidden = isBBDuk
        primerModePopup.isHidden = isBBDuk
        primerOverlapLabel.isHidden = isBBDuk
        primerOverlapField.isHidden = isBBDuk
        primerErrorLabel.isHidden = isBBDuk
        primerErrorField.isHidden = isBBDuk
        primerAnchored5Checkbox.isHidden = isBBDuk
        primerAnchored3Checkbox.isHidden = isBBDuk
        primerAllowIndelsCheckbox.isHidden = isBBDuk
        primerKeepUntrimmedCheckbox.isHidden = isBBDuk
        if isBBDuk { primerRevcompCheckbox.isHidden = true }
        if isBBDuk { primerPairFilterLabel.isHidden = true; primerPairFilterPopup.isHidden = true }

        // bbduk-specific: ktrim direction, kmer size, mink, hdist
        primerKtrimLabel.isHidden = !isBBDuk
        primerKtrimPopup.isHidden = !isBBDuk
        primerKmerLabel.isHidden = !isBBDuk
        primerKmerField.isHidden = !isBBDuk
        primerMinKmerLabel.isHidden = !isBBDuk
        primerMinKmerField.isHidden = !isBBDuk
        primerHdistLabel.isHidden = !isBBDuk
        primerHdistField.isHidden = !isBBDuk
    }

    @objc private func primerTrimControlChanged(_ sender: Any) {
        let tool: FASTQPrimerTool = primerToolPopup.indexOfSelectedItem == 1 ? .bbduk : .cutadapt
        let source: FASTQPrimerSource = primerSourcePopup.indexOfSelectedItem == 1 ? .reference : .literal
        let readMode: FASTQPrimerReadMode = primerReadModePopup.indexOfSelectedItem == 1 ? .paired : .single
        let mode: FASTQPrimerTrimMode
        switch primerModePopup.indexOfSelectedItem {
        case 1: mode = .threePrime
        case 2: mode = .linked
        case 3: mode = .paired
        default: mode = .fivePrime
        }
        let pairFilter: FASTQPrimerPairFilter
        switch primerPairFilterPopup.indexOfSelectedItem {
        case 1: pairFilter = .both
        case 2: pairFilter = .first
        default: pairFilter = .any
        }
        let ktrimDirection: FASTQKtrimDirection = primerKtrimPopup.indexOfSelectedItem == 1 ? .right : .left
        primerTrimConfiguration = FASTQPrimerTrimConfiguration(
            source: source,
            readMode: readMode,
            mode: mode,
            forwardSequence: primerForwardField.stringValue,
            reverseSequence: primerReverseField.stringValue,
            referenceFasta: primerReferenceField.stringValue,
            anchored5Prime: primerAnchored5Checkbox.state == .on,
            anchored3Prime: primerAnchored3Checkbox.state == .on,
            errorRate: Double(primerErrorField.stringValue) ?? 0.12,
            minimumOverlap: Int(primerOverlapField.stringValue) ?? 12,
            allowIndels: primerAllowIndelsCheckbox.state == .on,
            keepUntrimmed: primerKeepUntrimmedCheckbox.state == .on,
            searchReverseComplement: primerRevcompCheckbox.state == .on,
            pairFilter: pairFilter,
            tool: tool,
            ktrimDirection: ktrimDirection,
            kmerSize: Int(primerKmerField.stringValue) ?? 15,
            minKmer: Int(primerMinKmerField.stringValue) ?? 11,
            hammingDistance: Int(primerHdistField.stringValue) ?? 1
        )
        refreshPrimerTrimControls()
        statusLabel.stringValue = "Updated primer trimming configuration."
    }

    // MARK: - Dedup Panel

    private func setupDedupPanel() {
        let labels: [NSTextField] = [dedupPresetLabel, dedupSubsLabel, dedupDistLabel]
        for label in labels {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            dedupContainer.addSubview(label)
        }

        dedupPresetPopup.addItems(withTitles: [
            "Exact PCR Duplicates",
            "Near Duplicates (1 sub)",
            "Near Duplicates (2 subs)",
            "Optical (HiSeq 3000/4000/X)",
            "Optical (NextSeq/NovaSeq)",
            "Custom"
        ])
        dedupPresetPopup.font = .systemFont(ofSize: 12)
        dedupPresetPopup.translatesAutoresizingMaskIntoConstraints = false
        dedupPresetPopup.target = self
        dedupPresetPopup.action = #selector(dedupControlChanged(_:))
        dedupContainer.addSubview(dedupPresetPopup)

        for field in [dedupSubsField, dedupDistField] {
            field.font = .systemFont(ofSize: 12)
            field.translatesAutoresizingMaskIntoConstraints = false
            let formatter = NumberFormatter()
            formatter.numberStyle = .none
            formatter.minimum = 0
            formatter.maximum = field === dedupSubsField ? 5 : 100000
            field.formatter = formatter
            field.target = self
            field.action = #selector(dedupControlChanged(_:))
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true
            dedupContainer.addSubview(field)
        }

        dedupOpticalCheckbox.translatesAutoresizingMaskIntoConstraints = false
        dedupOpticalCheckbox.target = self
        dedupOpticalCheckbox.action = #selector(dedupControlChanged(_:))
        dedupContainer.addSubview(dedupOpticalCheckbox)

        dedupDescriptionLabel.font = .systemFont(ofSize: 11)
        dedupDescriptionLabel.textColor = .tertiaryLabelColor
        dedupDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        dedupDescriptionLabel.maximumNumberOfLines = 3
        dedupDescriptionLabel.preferredMaxLayoutWidth = 400
        dedupContainer.addSubview(dedupDescriptionLabel)

        NSLayoutConstraint.activate([
            dedupPresetLabel.topAnchor.constraint(equalTo: dedupContainer.topAnchor, constant: 8),
            dedupPresetLabel.leadingAnchor.constraint(equalTo: dedupContainer.leadingAnchor),
            dedupPresetPopup.centerYAnchor.constraint(equalTo: dedupPresetLabel.centerYAnchor),
            dedupPresetPopup.leadingAnchor.constraint(equalTo: dedupPresetLabel.trailingAnchor, constant: 6),
            dedupPresetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            dedupDescriptionLabel.topAnchor.constraint(equalTo: dedupPresetPopup.bottomAnchor, constant: 8),
            dedupDescriptionLabel.leadingAnchor.constraint(equalTo: dedupContainer.leadingAnchor),
            dedupDescriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: dedupContainer.trailingAnchor),

            dedupSubsLabel.topAnchor.constraint(equalTo: dedupDescriptionLabel.bottomAnchor, constant: 12),
            dedupSubsLabel.leadingAnchor.constraint(equalTo: dedupContainer.leadingAnchor),
            dedupSubsField.centerYAnchor.constraint(equalTo: dedupSubsLabel.centerYAnchor),
            dedupSubsField.leadingAnchor.constraint(equalTo: dedupSubsLabel.trailingAnchor, constant: 6),

            dedupOpticalCheckbox.topAnchor.constraint(equalTo: dedupSubsLabel.bottomAnchor, constant: 10),
            dedupOpticalCheckbox.leadingAnchor.constraint(equalTo: dedupContainer.leadingAnchor),

            dedupDistLabel.topAnchor.constraint(equalTo: dedupOpticalCheckbox.bottomAnchor, constant: 8),
            dedupDistLabel.leadingAnchor.constraint(equalTo: dedupContainer.leadingAnchor, constant: 20),
            dedupDistField.centerYAnchor.constraint(equalTo: dedupDistLabel.centerYAnchor),
            dedupDistField.leadingAnchor.constraint(equalTo: dedupDistLabel.trailingAnchor, constant: 6),
        ])
    }

    private func refreshDedupControls() {
        let preset = currentDedupPreset()
        let isCustom = preset == .custom
        dedupSubsField.isEnabled = isCustom
        dedupOpticalCheckbox.isEnabled = isCustom
        dedupDistField.isEnabled = isCustom && dedupOpticalCheckbox.state == .on
        dedupDistLabel.textColor = dedupDistField.isEnabled ? .secondaryLabelColor : .quaternaryLabelColor

        let descriptions: [FASTQDeduplicatePreset: String] = [
            .exactPCR: "Remove identical read pairs (subs=0). Best for amplicon/PCR duplicate removal.",
            .nearDuplicate1: "Allow 1 substitution between duplicates. Tolerates single sequencing errors.",
            .nearDuplicate2: "Allow 2 substitutions (BBTools default). Good general-purpose deduplication.",
            .opticalHiSeq: "Remove optical duplicates from patterned flowcells (HiSeq 3000/4000/X, dupedist=40).",
            .opticalNovaSeq: "Remove optical duplicates from NextSeq/NovaSeq (dupedist=12000, larger tile spacing).",
            .custom: "Manually configure substitution tolerance and optical duplicate settings."
        ]
        dedupDescriptionLabel.stringValue = descriptions[preset] ?? ""
    }

    private func currentDedupPreset() -> FASTQDeduplicatePreset {
        let index = dedupPresetPopup.indexOfSelectedItem
        let cases = FASTQDeduplicatePreset.allCases
        guard index >= 0, index < cases.count else { return .exactPCR }
        return cases[cases.index(cases.startIndex, offsetBy: index)]
    }

    @objc private func dedupControlChanged(_ sender: Any) {
        let preset = currentDedupPreset()

        // Apply preset values
        switch preset {
        case .exactPCR:
            dedupSubsField.stringValue = "0"
            dedupOpticalCheckbox.state = .off
            dedupDistField.stringValue = "40"
        case .nearDuplicate1:
            dedupSubsField.stringValue = "1"
            dedupOpticalCheckbox.state = .off
            dedupDistField.stringValue = "40"
        case .nearDuplicate2:
            dedupSubsField.stringValue = "2"
            dedupOpticalCheckbox.state = .off
            dedupDistField.stringValue = "40"
        case .opticalHiSeq:
            dedupSubsField.stringValue = "0"
            dedupOpticalCheckbox.state = .on
            dedupDistField.stringValue = "40"
        case .opticalNovaSeq:
            dedupSubsField.stringValue = "0"
            dedupOpticalCheckbox.state = .on
            dedupDistField.stringValue = "12000"
        case .custom:
            break // leave current values
        }

        refreshDedupControls()
        notifyDedupChanged()
        statusLabel.stringValue = "Updated deduplication configuration."
    }

    private func notifyDedupChanged() {
        let preset = currentDedupPreset()
        let subs = Int(dedupSubsField.stringValue) ?? 0
        let optical = dedupOpticalCheckbox.state == .on
        let dist = Int(dedupDistField.stringValue) ?? 40
        onDedupConfigChanged?(preset, subs, optical, dist)
    }

    private func ensureSingleDemuxStep() {
        if demuxSteps.isEmpty {
            let defaultKit = allKits.first?.id ?? BarcodeKitRegistry.builtinKits().first?.id ?? ""
            demuxSteps = [DemultiplexStep(label: "Demux", barcodeKitID: defaultKit, sampleAssignments: sampleAssignments, ordinal: 0)]
        } else {
            demuxSteps = Array(demuxSteps.sorted(by: { $0.ordinal < $1.ordinal }).prefix(1))
            demuxSteps[0].ordinal = 0
            if demuxSteps[0].sampleAssignments.isEmpty && !sampleAssignments.isEmpty {
                demuxSteps[0].sampleAssignments = sampleAssignments
            } else if sampleAssignments.isEmpty && !demuxSteps[0].sampleAssignments.isEmpty {
                sampleAssignments = demuxSteps[0].sampleAssignments
            }
        }
    }

    private func refreshSelectedKitReference() {
        ensureSingleDemuxStep()
        guard let kit = allKits.first(where: { $0.id == demuxSteps[0].barcodeKitID }) else {
            selectedKitBarcodes = []
            selectedKitName = ""
            kitDetailLabel.stringValue = "Kit Reference: no barcode kit selected."
            stepRemoveKitButton.isEnabled = false
            kitDetailTable.reloadData()
            return
        }
        selectedKitBarcodes = kit.barcodes
        selectedKitName = kit.displayName
        kitDetailLabel.stringValue = "Kit Reference: \(kit.displayName) — \(kit.barcodes.count) barcode(s)"
        stepRemoveKitButton.isEnabled = customBarcodeSets.contains(where: { $0.id == kit.id })
        kitDetailTable.reloadData()
    }

    @objc private func stepKitChanged(_ sender: NSPopUpButton) {
        ensureSingleDemuxStep()
        let kitIndex = sender.indexOfSelectedItem
        guard kitIndex >= 0, kitIndex < allKits.count else { return }
        let kit = allKits[kitIndex]
        demuxSteps[0].barcodeKitID = kit.id

        // Auto-set symmetry and location from kit's pairing mode
        let previousSymmetry = demuxSteps[0].symmetryMode
        let symmetry: BarcodeSymmetryMode
        switch kit.pairingMode {
        case .singleEnd: symmetry = .singleEnd
        case .symmetric: symmetry = .symmetric
        case .fixedDual, .combinatorialDual: symmetry = .asymmetric
        }
        demuxSteps[0].symmetryMode = symmetry

        // Rebuild columns when switching to/from asymmetric mode
        let symmetryClassChanged = (previousSymmetry == .asymmetric) != (symmetry == .asymmetric)
        if symmetryClassChanged {
            rebuildColumns()
        }

        // Symmetric and asymmetric always search both ends; single-end defaults to 5'
        switch symmetry {
        case .symmetric, .asymmetric:
            demuxSteps[0].barcodeLocation = .bothEnds
        case .singleEnd:
            break // keep current location
        }

        // Auto-set error rate, overlap, and revcomp from platform
        demuxSteps[0].errorRate = kit.platform.recommendedErrorRate
        demuxSteps[0].minimumOverlap = kit.platform.recommendedMinimumOverlap
        demuxSteps[0].searchReverseComplement = kit.platform.readsCanBeReverseComplemented

        refreshStepDetail()
        updateLocationControlState()
        statusLabel.stringValue = "Demux kit changed to '\(kit.displayName)'."
        notifyDemuxPlanChanged()
    }

    /// Enables/disables the location control based on symmetry mode.
    /// For symmetric/asymmetric, location is always "Both" and not user-editable.
    private func updateLocationControlState() {
        ensureSingleDemuxStep()
        let symmetry = demuxSteps[0].symmetryMode
        switch symmetry {
        case .symmetric, .asymmetric:
            stepLocationControl.isEnabled = false
            stepLocationControl.selectedSegment = 2 // Both
        case .singleEnd:
            stepLocationControl.isEnabled = true
        }
    }

    @objc private func stepDetailChanged(_ sender: Any) {
        ensureSingleDemuxStep()

        let previousSymmetry = demuxSteps[0].symmetryMode
        let symmetry: BarcodeSymmetryMode
        switch stepSymmetryPopup.indexOfSelectedItem {
        case 1: symmetry = .asymmetric
        case 2: symmetry = .singleEnd
        default: symmetry = .symmetric
        }
        demuxSteps[0].symmetryMode = symmetry

        // Rebuild columns when switching to/from asymmetric mode
        // (asymmetric shows simplified Barcode 1/2 columns instead of 5'/3' + sequence)
        let symmetryClassChanged = (previousSymmetry == .asymmetric) != (symmetry == .asymmetric)
        if symmetryClassChanged {
            rebuildColumns()
        }

        // Symmetry determines location: symmetric/asymmetric always use both ends
        switch symmetry {
        case .symmetric, .asymmetric:
            demuxSteps[0].barcodeLocation = .bothEnds
        case .singleEnd:
            let location: BarcodeLocation
            switch stepLocationControl.selectedSegment {
            case 0: location = .fivePrime
            case 1: location = .threePrime
            default: location = .bothEnds
            }
            demuxSteps[0].barcodeLocation = location
        }

        updateLocationControlState()

        if let rate = Double(stepErrorRateField.stringValue) {
            demuxSteps[0].errorRate = max(0.01, min(0.50, rate))
        }

        demuxSteps[0].trimBarcodes = stepTrimCheckbox.state == .on
        demuxSteps[0].allowIndels = stepIndelsCheckbox.state == .on

        if let overlap = Int(stepOverlapField.stringValue) {
            demuxSteps[0].minimumOverlap = max(1, min(30, overlap))
        }
        if let dist5 = Int(stepDistance5Field.stringValue) {
            demuxSteps[0].maxSearchDistance5Prime = max(0, dist5)
        }
        if let dist3 = Int(stepDistance3Field.stringValue) {
            demuxSteps[0].maxSearchDistance3Prime = max(0, dist3)
        }
        if let minInsert = Int(stepMinInsertField.stringValue) {
            demuxSteps[0].minimumInsert = max(0, minInsert)
        }

        refreshStepDetail()
        notifyDemuxPlanChanged()
    }

    @objc private func stepScoutClicked(_ sender: NSButton) {
        ensureSingleDemuxStep()
        delegate?.fastqMetadataDrawerViewDidRequestScout(self, step: demuxSteps[0])
    }

    @objc private func demuxAdvancedToggled(_ sender: NSButton) {
        isDemuxAdvancedEnabled = sender.state == .on
        refreshStepDetail()
        updateTabVisibility()
        statusLabel.stringValue = isDemuxAdvancedEnabled
            ? "Advanced demultiplexing options enabled."
            : "Advanced demultiplexing options hidden."
    }

    // MARK: - Button Actions

    @objc private func preferredSetChanged(_ sender: NSPopUpButton) {
        preferredBarcodeSetID = preferredSetIDByPopupIndex[sender.indexOfSelectedItem]
    }

    @objc private func addClicked(_ sender: NSButton) {
        guard activeTab == .samples || activeTab == .demux else { return }

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
        if activeTab == .demux {
            ensureSingleDemuxStep()
            demuxSteps[0].sampleAssignments = sampleAssignments
            notifyDemuxPlanChanged()
        }
    }

    @objc private func removeClicked(_ sender: NSButton) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }

        switch activeTab {
        case .samples, .demux:
            guard row < sampleAssignments.count else { return }
            let removed = sampleAssignments.remove(at: row)
            tableView.reloadData()
            statusLabel.stringValue = "Removed sample '\(removed.sampleID)'."
            if activeTab == .demux {
                ensureSingleDemuxStep()
                demuxSteps[0].sampleAssignments = sampleAssignments
                notifyDemuxPlanChanged()
            }
        case .primerTrim:
            primerTrimConfiguration = nil
            refreshPrimerTrimControls()
            statusLabel.stringValue = "Cleared primer trim configuration."
        case .dedup:
            dedupPresetPopup.selectItem(at: 0)
            dedupControlChanged(sender)
            statusLabel.stringValue = "Reset dedup configuration to defaults."
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
                case .samples, .demux:
                    do {
                        let content = try String(contentsOf: url, encoding: .utf8)
                        NSLog("[FASTQDrawer] Read \(content.count) chars from \(url.lastPathComponent), first 200: \(String(content.prefix(200)))")
                        let imported = try FASTQSampleBarcodeCSV.load(from: url)
                        NSLog("[FASTQDrawer] Imported \(imported.count) sample assignment(s) from \(url.lastPathComponent)")
                        self.sampleAssignments = imported
                        self.ensureSingleDemuxStep()
                        self.demuxSteps[0].sampleAssignments = self.sampleAssignments
                        self.tableView.reloadData()
                        self.statusLabel.stringValue = "Imported \(self.sampleAssignments.count) sample assignment(s)."
                        if self.activeTab == .demux {
                            self.notifyDemuxPlanChanged()
                        }
                    } catch {
                        NSLog("[FASTQDrawer] Import failed: \(error)")
                        self.statusLabel.stringValue = "Import failed: \(error.localizedDescription)"
                    }
                case .primerTrim, .dedup:
                    self.statusLabel.stringValue = "Import is not available for this tab."
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
        case .demux:
            panel.nameFieldStringValue = "demux-pattern.csv"
        case .primerTrim, .dedup:
            statusLabel.stringValue = "Export is not available for this tab."
            return
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let outputURL = panel.url else { return }
                do {
                    self.ensureSingleDemuxStep()
                    let isAsymmetric = self.demuxSteps[0].symmetryMode == .asymmetric
                    let content: String
                    if isAsymmetric && self.activeTab == .demux {
                        content = FASTQSampleBarcodeCSV.exportAsymmetricCSV(self.sampleAssignments)
                    } else {
                        content = FASTQSampleBarcodeCSV.exportCSV(self.sampleAssignments)
                    }
                    try content.write(to: outputURL, atomically: true, encoding: .utf8)
                    self.statusLabel.stringValue = "Exported \(outputURL.lastPathComponent)."
                } catch {
                    self.statusLabel.stringValue = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func importCustomKitClicked(_ sender: NSButton) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Kit"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    let name = url.deletingPathExtension().lastPathComponent
                    let set = try BarcodeKitRegistry.loadCustomKit(from: url, name: name)
                    if let existing = self.customBarcodeSets.firstIndex(where: { $0.id == set.id }) {
                        self.customBarcodeSets[existing] = set
                    } else {
                        self.customBarcodeSets.append(set)
                    }
                    self.allKits = BarcodeKitRegistry.builtinKits() + self.customBarcodeSets
                    self.rebuildPreferredSetPopup()
                    self.rebuildStepKitPopup()
                    self.ensureSingleDemuxStep()
                    self.demuxSteps[0].barcodeKitID = set.id
                    self.refreshStepDetail()
                    self.statusLabel.stringValue = "Imported custom barcode kit '\(set.displayName)'. Save to Project Dataset to persist it in this project."
                    self.notifyDemuxPlanChanged()
                } catch {
                    self.statusLabel.stringValue = "Custom kit import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func removeCurrentCustomKitClicked(_ sender: NSButton) {
        ensureSingleDemuxStep()
        let currentKitID = demuxSteps[0].barcodeKitID
        guard let customIndex = customBarcodeSets.firstIndex(where: { $0.id == currentKitID }) else {
            statusLabel.stringValue = "Selected kit is built in and cannot be removed."
            return
        }
        let removed = customBarcodeSets.remove(at: customIndex)
        if preferredBarcodeSetID == removed.id {
            preferredBarcodeSetID = nil
        }
        allKits = BarcodeKitRegistry.builtinKits() + customBarcodeSets
        rebuildPreferredSetPopup()
        rebuildStepKitPopup()
        demuxSteps[0].barcodeKitID = allKits.first?.id ?? ""
        refreshStepDetail()
        statusLabel.stringValue = "Removed custom barcode kit '\(removed.displayName)'. Save to Project Dataset to persist the removal in this project."
        notifyDemuxPlanChanged()
    }

    @objc private func saveClicked(_ sender: NSButton) {
        delegate?.fastqMetadataDrawerViewDidSave(self, fastqURL: fastqURL, metadata: currentMetadata())
        statusLabel.stringValue = "Saved project-local FASTQ metadata."
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

    private func encodePrimerTrimConfigurationToJSON(_ configuration: FASTQPrimerTrimConfiguration?) -> String? {
        guard let configuration else { return nil }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(configuration) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodePrimerTrimConfiguration(from json: String) -> FASTQPrimerTrimConfiguration? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(FASTQPrimerTrimConfiguration.self, from: data)
    }

    // Orient tab removed — orient is now dispatched from the FASTQ operations sidebar.

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
