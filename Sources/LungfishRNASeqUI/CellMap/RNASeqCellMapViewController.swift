// RNASeqCellMapViewController.swift - The embedding view of a cell map, the third child of the surface (Phase 5.5 lane CM-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view draws the cells of a cell map on its embedding (5.5 O1 (a)). The surface's load reads what the view opens
// with, so the memory guard's cancel of the surface's `loadTask` reaches it. A later read, of another embedding or
// another colouring, and every raster run off the main actor, and the newest request wins. The controls are an
// Embedding pop-up, a Colour by pop-up and a point size that nothing records, which is LungfishKit's shared slider in
// a hosting view (RNASeqCellMapPointSize.swift). The view opens on the first embedding in file order (5.5 V6). The
// right column is one fixed width that sets every wrap width in it (5.6 L1). A general caveat sits in an info button
// beside the control it explains, and a fact true of this result sits under that control (5.6 U2).

import AppKit
import LungfishIO
import LungfishKit
import SwiftUI

@MainActor
public final class RNASeqCellMapViewController: NSViewController {
    public static let accessibilityID = "rnaseq-cell-map-view"
    public static let pointSizes = 1.0...8.0
    public static let defaultPointSize = 2.0
    /// The control column's width, which sets every wrap width in it (5.6 L1).
    public static let columnWidth: CGFloat = 240
    static let columnInsets = NSEdgeInsets(top: 4, left: 12, bottom: 12, right: 16)
    /// The width the column's content fits in, 212 pt.
    public static var contentWidth: CGFloat { columnWidth - columnInsets.left - columnInsets.right }

    public private(set) var result: RNASeqResult?
    public private(set) var bundleURL: URL?
    /// What is shown: the facts, the embedding's points, the colouring and its colours. Nil until the read ends.
    public private(set) var snapshot: RNASeqCellMapSnapshot?
    public private(set) var failureWords: String?
    /// The point size in points, a display setting that nothing records (5.5 V6). The model holds it, so the shared
    /// slider and the raster read one value.
    public var pointSize: Double { pointSizeModel.value }
    /// The part of the plane shown, nil for every drawn cell.
    public private(set) var plotWindow: RNASeqEmbeddingWindow?
    /// The hover line on show, nil when the pointer is over no cell.
    public private(set) var hoverWords: String?
    /// The latest read or raster, which a test can wait on.
    public private(set) var work: Task<Void, Never>?
    public private(set) var hoverWork: Task<Void, Never>?

    public let plot = RNASeqEmbeddingPlotView()
    public let legendView = RNASeqEmbeddingLegendView()
    public let embeddingPopUp = NSPopUpButton()
    public let colourPopUp = NSPopUpButton()
    /// The size on show in the shared slider. A size that the slider or its number field writes runs `choosePointSize(_:)`.
    private(set) lazy var pointSizeModel = RNASeqCellMapPointSizeModel { [weak self] size in self?.choosePointSize(size) }
    /// The shared slider and number field of the point size, which sit in the control row.
    private(set) lazy var pointSizeHost = NSHostingView(rootView: RNASeqCellMapPointSizeControl(model: pointSizeModel))
    private let column = NSStackView()
    /// The facts of the embedding on show, under the Embedding row, and of the label set, under the Colour by row.
    private let embeddingLines = NSStackView()
    private let labelLines = NSStackView()
    /// "About <method>" beside Embedding and "About clusters" beside Colour by, each with a caveat that left the view.
    public let embeddingInfo = LungfishInfoButton(item: RNASeqEmbeddingWords.embeddingHelp(method: nil, embedding: ""), about: "")
    public let clustersInfo = LungfishInfoButton(item: RNASeqEmbeddingWords.clustersHelp(computed: false, numbers: true)
        ?? RNASeqEmbeddingWords.embeddingHelp(method: nil, embedding: ""), about: RNASeqEmbeddingWords.clustersSubject)
    /// "About selecting" beside the selection line (S1b).
    public let selectingInfo = LungfishInfoButton(item: RNASeqEmbeddingSelectionWords.selectingHelp, about: RNASeqEmbeddingSelectionWords.selectingSubject)
    var infoButtons: [LungfishInfoButton] { [embeddingInfo, clustersInfo, legendView.scaleInfo, selectingInfo] }
    private let xAxis = NSTextField(labelWithString: "")
    private let yAxis = NSTextField(labelWithString: "")
    private let hoverField = NSTextField(wrappingLabelWithString: "")
    private var readWork: Task<Void, Never>?
    private var rasterWork: Task<Void, Never>?
    private var generation = 0
    /// The cell whose hover read is on show or in flight, so a pointer moving inside one disc starts no new read.
    private var hoveredCell: Int?
    /// The embedding and colouring the newest choices want, kept until a read shows them, so a later choice keeps an
    /// earlier one still being read (5.5 V1, newest wins).
    private var wantedEmbedding: Int?
    private var wantedColouring: RNASeqCellMapColouring?
    /// The unit a gene is coloured in, the normalised value until a person asks for raw UMIs (5.5 G1).
    public private(set) var geneUnit: RNASeqCellMapDatabase.GeneUnit = .normalised
    /// The picker that the Gene… item opened, and the read of the cell map's features that fills it.
    public private(set) var genePicker: RNASeqEmbeddingGenePickerViewController?
    public private(set) var geneIndexWork: Task<Void, Never>?
    private var geneIndex: RNASeqGeneIndex?
    private var genePopover: NSPopover?
    /// Normalised UMIs or raw UMIs, in a row under the Colour by list that shows while a gene is on show.
    public let geneUnitControl = NSSegmentedControl(labels: RNASeqEmbeddingWords.geneUnitSegments, trackingMode: .selectOne, target: nil, action: nil)
    /// What is selected, nil when nothing is. Selecting writes nothing (5.5 S1, RNASeqEmbeddingSelection.swift).
    public internal(set) var selection: RNASeqEmbeddingSelection?
    /// The latest membership run, which a test can wait on.
    public internal(set) var selectionWork: Task<Void, Never>?
    /// The count VoiceOver was last told.
    public internal(set) var selectionAnnouncement: String?
    var selectionGeneration = 0
    /// Called with Save Selection as Labels Table… or Pseudobulk Selected Cells…, which the App runs through lungfish-cli.
    public var onSelectionAction: (@MainActor (RNASeqEmbeddingSelectionAction) -> Void)?
    /// Gets the fact lines on each refresh, and none on close or a failed reread (the Inspector's cell map part).
    var onFacts: (@MainActor ([(label: String, value: String)]) -> Void)?
    public let selectionField = NSTextField(wrappingLabelWithString: RNASeqEmbeddingSelectionWords.none)
    public let selectionNote = NSTextField(wrappingLabelWithString: "")
    public let saveSelectionButton = NSButton(title: RNASeqEmbeddingSelectionWords.saveTitle, target: nil, action: nil)
    public let pseudobulkSelectionButton = NSButton(title: RNASeqEmbeddingSelectionWords.pseudobulkTitle, target: nil, action: nil)

    public override func loadView() {
        let root = NSView()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityIdentifier(Self.accessibilityID)
        for field in [xAxis, yAxis] {
            field.textColor = .secondaryLabelColor
            field.alignment = .center
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        xAxis.setAccessibilityIdentifier("rnaseq-cell-map-axis-x")
        yAxis.setAccessibilityIdentifier("rnaseq-cell-map-axis-y")
        yAxis.frameCenterRotation = 90
        plot.translatesAutoresizingMaskIntoConstraints = false
        plot.onNeedsRaster = { [weak self] in self?.requestRaster() }
        plot.onWindowChange = { [weak self] window in
            self?.plotWindow = window
            self?.requestRaster()
        }
        plot.onHover = { [weak self] cell in self?.hover(cell) }
        plot.onLasso = { [weak self] points, modifiers in self?.lasso(points, modifiers: modifiers) }
        plot.contextMenu = { [weak self] in self?.selectionMenu() }
        legendView.onRowClick = { [weak self] row, adding in self?.selectLegendRow(row, adding: adding) }
        legendView.onRowToggle = { [weak self] row in self?.toggleLegendRow(row) }
        plot.onEscape = { [weak self] in self?.escape() }
        legendView.onEscape = { [weak self] in self?.escape() }
        legendView.wrapWidth = Self.contentWidth
        // How to select is the plot's VoiceOver help and the popover of "About selecting", never a help tag on the plot (S1b).
        plot.setAccessibilityHelp(RNASeqEmbeddingSelectionWords.howToSelect)
        selectionField.isSelectable = true
        selectionField.preferredMaxLayoutWidth = Self.contentWidth - ceil(selectingInfo.intrinsicContentSize.width) - 8
        selectionField.setAccessibilityIdentifier("rnaseq-cell-map-selection-count")
        selectionNote.isSelectable = true
        selectionNote.preferredMaxLayoutWidth = Self.contentWidth
        selectionNote.isHidden = true
        selectionNote.setAccessibilityIdentifier("rnaseq-cell-map-selection-note")
        for (button, action, id) in [(saveSelectionButton, #selector(saveSelectionAsLabelsTable(_:)), "rnaseq-cell-map-save-selection"),
                                     (pseudobulkSelectionButton, #selector(pseudobulkSelectedCells(_:)), "rnaseq-cell-map-pseudobulk-selection")] {
            button.target = self
            button.action = action
            button.isEnabled = false
            button.setAccessibilityIdentifier(id)
            // The regular size is 220 pt wide for Save Selection as Labels Table…, past the column's 212 (5.6 L1).
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }

        embeddingPopUp.setAccessibilityIdentifier("rnaseq-cell-map-embedding")
        embeddingPopUp.target = self
        embeddingPopUp.action = #selector(embeddingChosen(_:))
        colourPopUp.setAccessibilityIdentifier("rnaseq-cell-map-colour")
        colourPopUp.target = self
        colourPopUp.action = #selector(colouringChosen(_:))
        geneUnitControl.target = self
        geneUnitControl.action = #selector(geneUnitChosen(_:))
        geneUnitControl.setAccessibilityIdentifier("rnaseq-cell-map-gene-unit")
        geneUnitControl.setAccessibilityLabel(RNASeqEmbeddingWords.geneUnitTitle)
        hoverField.isSelectable = true
        hoverField.preferredMaxLayoutWidth = Self.contentWidth
        hoverField.setAccessibilityIdentifier("rnaseq-cell-map-hover")

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = Self.columnInsets
        column.translatesAutoresizingMaskIntoConstraints = false
        for lines in [embeddingLines, labelLines] {
            lines.orientation = .vertical
            lines.alignment = .leading
            lines.spacing = 6
        }
        clustersInfo.isHidden = true
        embeddingInfo.isHidden = true
        for (label, control, info, lines) in [("Embedding", embeddingPopUp, embeddingInfo, embeddingLines), ("Colour by", colourPopUp, clustersInfo, labelLines),
                                              (RNASeqEmbeddingWords.geneUnitTitle, geneUnitControl, nil, nil),
                                              (RNASeqCellMapPointSizeControl.title, pointSizeHost, nil, nil)] as [(String, NSView, NSView?, NSView?)] {
            let row = Self.control(label, control, info: info)
            row.isHidden = control === geneUnitControl
            column.addArrangedSubview(row)
            if let lines { column.addArrangedSubview(lines) }
        }
        column.addArrangedSubview(legendView)
        let selectionRow = NSStackView(views: [selectionField, selectingInfo])
        selectionRow.orientation = .horizontal
        selectionRow.alignment = .centerY
        selectionRow.spacing = 8
        column.addArrangedSubview(selectionRow)
        column.addArrangedSubview(selectionNote)
        let actions = NSStackView(views: [saveSelectionButton, pseudobulkSelectionButton])
        actions.orientation = .vertical
        actions.alignment = .leading
        column.addArrangedSubview(actions)
        column.addArrangedSubview(hoverField)
        let document = RNASeqCellMapFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        let side = RNASeqCellMapSideView()
        side.hasVerticalScroller = true
        side.drawsBackground = false
        side.documentView = document
        side.translatesAutoresizingMaskIntoConstraints = false
        let sideWidth = side.widthAnchor.constraint(equalToConstant: RNASeqCellMapSideView.width(for: side.scrollerStyle))
        side.widthConstraint = sideWidth

        for view in [plot, xAxis, yAxis, side] as [NSView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: side.contentView.widthAnchor),
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sideWidth,
            yAxis.centerXAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            yAxis.centerYAnchor.constraint(equalTo: plot.centerYAnchor),
            plot.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            plot.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            plot.trailingAnchor.constraint(equalTo: side.leadingAnchor, constant: -8),
            plot.bottomAnchor.constraint(equalTo: xAxis.topAnchor, constant: -4),
            xAxis.centerXAnchor.constraint(equalTo: plot.centerXAnchor),
            xAxis.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            plot.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            plot.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        view = root
    }

    /// Keeps the result and shows what the surface's load read, or reads it here when the surface read none.
    public func configure(result: RNASeqResult, bundleURL: URL, outcome: RNASeqCellMapLoadOutcome? = nil) {
        _ = view
        self.result = result
        self.bundleURL = bundleURL
        close()
        if let outcome {
            apply(outcome)
            return
        }
        let task = Task { [weak self] in
            let outcome = await RNASeqCellMapLoader.load(result: result, bundleURL: bundleURL)
            guard !Task.isCancelled, let self, self.bundleURL == bundleURL else { return }
            self.apply(outcome)
        }
        readWork = task
        work = task
    }

    /// Stops every read and raster in flight, as when the surface shows another result.
    public func close() {
        generation += 1
        readWork?.cancel()
        rasterWork?.cancel()
        hoverWork?.cancel()
        geneIndexWork?.cancel()
        genePopover?.close()
        genePopover = nil
        genePicker = nil
        geneIndex = nil
        geneUnit = .normalised
        wantedEmbedding = nil
        wantedColouring = nil
        selectionGeneration += 1
        selectionWork?.cancel()
        selection = nil
        clearHover()
        onFacts?([])
    }

    /// Escape closes an open info popover and keeps the selection, or else empties the selection.
    public override func cancelOperation(_ sender: Any?) { escape() }

    /// Each Escape path calls this: the plot's and the legend's key handlers and `cancelOperation` (5.6 A1).
    func escape() {
        if closeInfoPopover() { return }
        clearSelection()
    }

    /// Closes the info popover on show, if one is, and says whether one was.
    @discardableResult public func closeInfoPopover() -> Bool {
        infoButtons.reduce(false) { closed, button in button.closePopover() || closed }
    }

    /// Command-A selects every drawn cell.
    public override func selectAll(_ sender: Any?) { selectAllCells() }

    func apply(_ outcome: RNASeqCellMapLoadOutcome) {
        wantedEmbedding = nil
        wantedColouring = nil
        switch outcome {
        case .failed(let words):
            snapshot = nil
            failureWords = words
            Self.replace(embeddingLines, with: [Self.text(words, id: "rnaseq-cell-map-failure", wraps: true)])
            Self.replace(labelLines, with: [])
            // No map was read, so no button explains one (UX SF-2, BIO SF-1).
            closeInfoPopover()
            embeddingInfo.isHidden = true
            clustersInfo.isHidden = true
            onFacts?([])
        case .loaded(let shown):
            snapshot = shown
            failureWords = nil
            plotWindow = nil
            embeddingPopUp.removeAllItems()
            for embedding in shown.facts.embeddings { Self.addItem(embedding.name, to: embeddingPopUp) }
            colourPopUp.removeAllItems()
            for colouring in shown.facts.colourings { Self.addItem(shown.facts.title(of: colouring), to: colourPopUp) }
            Self.addItem(RNASeqEmbeddingWords.genePopUpItem, to: colourPopUp)
            refresh()
        }
    }

    /// Adds an item to the menu itself. `addItem(withTitle:)` removes an earlier item of the same title, and a label set may be
    /// named Sample as the sample colouring is, so the items would fall out of step with the colourings and embeddings they
    /// stand for.
    private static func addItem(_ title: String, to popUp: NSPopUpButton) {
        popUp.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
    }

    // MARK: - Controls

    @objc private func embeddingChosen(_ sender: NSPopUpButton) {
        guard let facts = snapshot?.facts, facts.embeddings.indices.contains(sender.indexOfSelectedItem) else { return }
        chooseEmbedding(facts.embeddings[sender.indexOfSelectedItem].embedding)
    }

    @objc private func colouringChosen(_ sender: NSPopUpButton) {
        guard let shown = snapshot else { return }
        let facts = shown.facts
        if sender.indexOfSelectedItem == facts.colourings.count {
            // The Gene… item colours nothing itself. The pop-up keeps naming what is shown until a gene is picked.
            refreshColourPopUp(shown)
            showGenePicker()
            return
        }
        guard facts.colourings.indices.contains(sender.indexOfSelectedItem) else { return }
        chooseColouring(facts.colourings[sender.indexOfSelectedItem])
    }

    @objc private func geneUnitChosen(_ sender: NSSegmentedControl) {
        geneUnit = sender.selectedSegment == 1 ? .umis : .normalised
        if case .gene(let choice)? = wantedColouring ?? snapshot?.colouring { chooseColouring(.gene(choice.with(unit: geneUnit))) }
    }

    /// Opens the gene picker under the Colour by list. The features are read once, off the main actor, and a pick is one more
    /// colouring choice, so the newest pick wins and a pick keeps an embedding still being read (5.5 V1).
    public func showGenePicker() {
        guard let database = snapshot?.database else { return }
        genePopover?.close()
        let picker = RNASeqEmbeddingGenePickerViewController()
        picker.onPick = { [weak self] entry in self?.pickGene(entry) }
        genePicker = picker
        if let geneIndex {
            picker.show(index: geneIndex)
        } else {
            geneIndexWork?.cancel()
            geneIndexWork = Task { [weak self, weak picker] in
                do {
                    let index = try await offMain { RNASeqGeneIndex(features: try database.features()) }
                    guard let self, !Task.isCancelled else { return }
                    self.geneIndex = index
                    picker?.show(index: index)
                } catch is CancellationError {
                } catch {
                    picker?.showFailure(RNASeqSingleCellSummary.failureWords(error))
                }
            }
        }
        guard colourPopUp.window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        genePopover = popover
        popover.show(relativeTo: colourPopUp.bounds, of: colourPopUp, preferredEdge: .maxY)
    }

    private func pickGene(_ entry: RNASeqGeneIndex.Entry) {
        genePopover?.close()
        genePopover = nil
        if let choice = RNASeqGeneChoice(entry: entry, unit: geneUnit) { chooseColouring(.gene(choice)) }
    }

    /// Names what is shown in the Colour by list, and shows the unit control only beside a gene. The last item reads Gene…, or
    /// Gene and the name while a gene is shown, so choosing it again changes the gene.
    private func refreshColourPopUp(_ shown: RNASeqCellMapSnapshot) {
        let facts = shown.facts
        let geneItem = colourPopUp.item(at: facts.colourings.count)
        if case .gene(let choice) = shown.colouring {
            geneItem?.title = RNASeqEmbeddingWords.genePopUpTitle(choice.label)
            colourPopUp.selectItem(at: facts.colourings.count)
            geneUnitControl.selectedSegment = choice.unit == .umis ? 1 : 0
            geneUnitControl.superview?.isHidden = false
        } else {
            // Raw UMIs asked for one gene do not carry on: the unit control is hidden now, so the next gene starts normalised.
            geneUnit = .normalised
            geneItem?.title = RNASeqEmbeddingWords.genePopUpItem
            if let index = facts.colourings.firstIndex(of: shown.colouring) { colourPopUp.selectItem(at: index) }
            geneUnitControl.superview?.isHidden = true
        }
    }

    /// Reads and shows another embedding with the colouring wanted. A newer choice cancels this read and keeps this
    /// embedding.
    public func chooseEmbedding(_ embedding: Int) {
        guard snapshot != nil else { return }
        wantedEmbedding = embedding
        rereadWanted()
    }

    /// Reads and shows another colouring on the embedding wanted. A newer choice cancels this read and keeps this
    /// colouring.
    public func chooseColouring(_ colouring: RNASeqCellMapColouring) {
        guard snapshot != nil else { return }
        wantedColouring = colouring
        rereadWanted()
    }

    /// Reads what the newest choices want, the points only when the embedding wanted is not the one on show and the
    /// values only when the colouring wanted is not, then colours the one by the other.
    private func rereadWanted() {
        guard let shown = snapshot else { return }
        let embedding = wantedEmbedding ?? shown.points.embedding
        let colouring = wantedColouring ?? shown.colouring
        reread { database in
            let points = try embedding == shown.points.embedding ? shown.points : RNASeqCellMapLoader.points(database, embedding: embedding)
            try Task.checkCancellation()
            let values = try colouring == shown.colouring ? shown.values : RNASeqCellMapLoader.values(database, colouring: colouring)
            let colours = try RNASeqCellMapColours.make(facts: shown.facts, colouring: colouring, values: values, points: points)
            return (points, colouring, values, colours)
        }
    }

    /// Shows a point size from 1 to 8 pt, clamping what it is given, and draws the cells again at that size.
    public func choosePointSize(_ size: Double) {
        pointSizeModel.show(min(max(size, Self.pointSizes.lowerBound), Self.pointSizes.upperBound))
        requestRaster()
    }

    private typealias Reread = (RNASeqCellMapPoints, RNASeqCellMapColouring, RNASeqCellMapValues, RNASeqCellMapColours)

    private func reread(_ read: @escaping @Sendable (RNASeqCellMapDatabase) throws -> Reread) {
        guard let database = snapshot?.database else { return }
        readWork?.cancel()
        generation += 1
        let mine = generation
        let task = Task { [weak self] in
            do {
                let (points, colouring, values, colours) = try await offMain { try read(database) }
                guard let self, mine == self.generation, var shown = self.snapshot else { return }
                self.wantedEmbedding = nil
                self.wantedColouring = nil
                if points.embedding != shown.points.embedding {
                    // A selection belongs to the embedding it was drawn in.
                    self.plotWindow = nil
                    self.selectionWork?.cancel()
                    self.selection = nil
                }
                shown.points = points
                shown.colouring = colouring
                shown.values = values
                shown.colours = colours
                self.snapshot = shown
                self.refresh()
            } catch is CancellationError {
            } catch {
                guard let self, mine == self.generation else { return }
                self.apply(.failed(RNASeqSingleCellSummary.failureWords(error)))
            }
        }
        readWork = task
        work = task
    }

    // MARK: - Showing

    private func refresh() {
        // A new embedding or colouring makes the value on the hover line stale.
        clearHover()
        guard let shown = snapshot else { return }
        let facts = shown.facts
        if let index = facts.embeddings.firstIndex(where: { $0.embedding == shown.points.embedding }) { embeddingPopUp.selectItem(at: index) }
        refreshColourPopUp(shown)
        let embedding = facts.embeddings.first { $0.embedding == shown.points.embedding }
        let name = embedding?.name ?? ""
        let axes = RNASeqEmbeddingWords.axes(method: embedding?.method, embedding: name)
        xAxis.stringValue = axes.x
        yAxis.stringValue = axes.y
        legendView.show(shown.colours.legend, palette: RNASeqEmbeddingPalette.words(dark: plot.isDark))
        place(shown)
        plot.setAccessibilityLabel(RNASeqEmbeddingWords.plotLabel(method: embedding?.method, embedding: name,
                                                                  colouring: facts.title(of: shown.colouring)))
        let legend = shown.colours.legend
        plot.setAccessibilityValue(RNASeqEmbeddingWords.plotValue(cells: embedding?.cells ?? 0, values: max(legend.rows.count, legend.scale == nil ? 0 : 1)))
        view.layoutSubtreeIfNeeded()
        var labels = legend.rows.map { RNASeqEmbeddingWords.legendChild(name: $0.name, count: $0.count) }
        if let scale = legend.scale { labels.append("\(legend.title), 0 to \(RNASeqEmbeddingWords.number(scale.top))") }
        plot.setLegendChildren(labels, frames: legendView.rowViews.map { plot.convert($0.bounds, from: $0) },
                               select: legend.rows.isEmpty ? nil : { [weak self] row in self?.selectLegendRow(row, adding: false) })
        showSelection()
        requestRaster()
        onFacts?(factLines(shown))
    }

    /// The lines that moved to an info button: the caption beside Embedding, W2 and W3 beside Colour by (5.6 U2).
    static let movedLineIDs: Set<String> = ["rnaseq-cell-map-caption", "rnaseq-cell-map-computed-labels", "rnaseq-cell-map-cluster-numbers"]
    /// The lines about the label set, which sit under Colour by. The rest sit under Embedding.
    static let labelLineIDs: Set<String> = ["rnaseq-cell-map-imported-labels", "rnaseq-cell-map-labels-computed-by"]

    /// Lays each line of what is shown under the control it belongs to and points the info buttons at their caveats.
    /// "About clusters" hides when no caveat of it holds.
    private func place(_ shown: RNASeqCellMapSnapshot) {
        let words = wordLines(shown)
        let lines = words.filter { !Self.movedLineIDs.contains($0.id) }.map { Self.text($0.text, id: $0.id, wraps: true) as NSView }
            + viewFacts(shown).map { Self.fact($0.label, $0.value) }
        let underColour = { (view: NSView) in Self.labelLineIDs.contains(Self.lineID(view)) }
        Self.replace(embeddingLines, with: lines.filter { !underColour($0) })
        Self.replace(labelLines, with: lines.filter(underColour))
        let embedding = shown.facts.embeddings.first { $0.embedding == shown.points.embedding }
        let name = embedding?.name ?? ""
        let ids = Set(words.map(\.id))
        embeddingInfo.configure(item: RNASeqEmbeddingWords.embeddingHelp(method: embedding?.method, embedding: name,
                                                                         otherCounts: ids.contains("rnaseq-cell-map-other-counts")),
                                about: RNASeqEmbeddingWords.methodSubject(method: embedding?.method, embedding: name))
        embeddingInfo.isHidden = false
        var gene = false
        var unlabelled = false
        if case .gene = shown.colouring { gene = true }
        if case .labelSet(let id) = shown.colouring {
            unlabelled = shown.facts.labelSets.first { $0.labelSet == id }?.samples.contains { $0.unlabelled > 0 } ?? false
        }
        legendView.scaleInfo.configure(item: RNASeqEmbeddingWords.scaleHelp(cells: shown.facts.cellCount, gene: gene),
                                       about: RNASeqEmbeddingWords.scaleSubject)
        if let item = RNASeqEmbeddingWords.clustersHelp(computed: ids.contains("rnaseq-cell-map-computed-labels"),
                                                         numbers: ids.contains("rnaseq-cell-map-cluster-numbers"), unlabelled: unlabelled) {
            clustersInfo.configure(item: item, about: RNASeqEmbeddingWords.clustersSubject)
            clustersInfo.isHidden = false
        } else {
            clustersInfo.closePopover()
            clustersInfo.isHidden = true
        }
        // A title cut short keeps its whole name in the help tag, and the pop-up's AX value is the whole name.
        embeddingPopUp.toolTip = embeddingPopUp.titleOfSelectedItem
        colourPopUp.toolTip = colourPopUp.titleOfSelectedItem
    }

    /// The id of a line: a text's own, or its value's in a fact row.
    private static func lineID(_ view: NSView) -> String {
        if let field = view as? NSTextField { return field.accessibilityIdentifier() }
        return (view as? NSStackView)?.arrangedSubviews.last?.accessibilityIdentifier() ?? ""
    }

    /// The words of 5.5 W1 and I3 for what is shown, each with its accessibility id.
    func wordLines(_ shown: RNASeqCellMapSnapshot) -> [(id: String, text: String)] {
        let facts = shown.facts
        guard let embedding = facts.embeddings.first(where: { $0.embedding == shown.points.embedding }) else { return [] }
        var lines = [(id: "rnaseq-cell-map-caption", text: RNASeqEmbeddingWords.caption(method: embedding.method, embedding: embedding.name))]
        // One line says who made the coordinates, "not computed by LGE" or "Computed by <tool> <version>" whole (C4).
        lines.append(embedding.source == "imported"
                     ? ("rnaseq-cell-map-imported", RNASeqEmbeddingWords.imported(file: Self.fileName(embedding.sourceFile)))
                     : ("rnaseq-cell-map-computed-by", source(kind: embedding.source, file: embedding.sourceFile)))
        if embedding.otherCounts {
            lines.append(("rnaseq-cell-map-other-counts", RNASeqEmbeddingWords.otherCounts(embedding: embedding.name, parent: parentName)))
        }
        // A map of one sample says its left-out cells in its Cells drawn row (C6a, `viewFacts`).
        for row in facts.embeddingCells where facts.samples.count > 1 && row.embedding == embedding.embedding && row.leftOut > 0 {
            // The sample's own count as the CLI wrote it, never drawn plus left out (5.6 B5).
            guard let total = facts.samples.first(where: { $0.sample == row.sample })?.cells else { continue }
            lines.append(("rnaseq-cell-map-left-out-\(row.sample)",
                          RNASeqEmbeddingWords.leftOut(row.leftOut, of: total, sample: facts.sampleName(row.sample), embedding: embedding.name)))
        }
        if case .labelSet(let id) = shown.colouring, let set = facts.labelSets.first(where: { $0.labelSet == id }) {
            if set.source == "computed" { lines.append(("rnaseq-cell-map-computed-labels", RNASeqEmbeddingWords.computedLabels)) }
            if !set.labels.isEmpty, set.labels.allSatisfy({ !$0.name.isEmpty && $0.name.allSatisfy(\.isNumber) }) {
                lines.append(("rnaseq-cell-map-cluster-numbers", RNASeqEmbeddingWords.clusterNumbers))
            }
            lines.append(set.source == "imported"
                         ? ("rnaseq-cell-map-imported-labels", RNASeqEmbeddingWords.imported(file: Self.fileName(set.sourceFile)))
                         : ("rnaseq-cell-map-labels-computed-by", source(kind: set.source, file: set.sourceFile)))
        }
        return lines
    }

    /// The fact rows laid in view: Embedding only while its method is not recorded (C3c), and Cells drawn, which on a map
    /// of one sample also says its left-out cells (C6a, C6c). The parent, the source and the labels' facts are the
    /// Inspector's (C17), and `factLines` keeps every row for it.
    func viewFacts(_ shown: RNASeqCellMapSnapshot) -> [(label: String, value: String)] {
        let facts = shown.facts
        guard let embedding = facts.embeddings.first(where: { $0.embedding == shown.points.embedding }) else { return [] }
        let all = factLines(shown)
        var rows = (embedding.method ?? "").isEmpty ? all.filter { $0.label == "Embedding" } : []
        let single = facts.samples.count == 1 ? facts.embeddingCells.first { $0.embedding == embedding.embedding && $0.leftOut > 0 } : nil
        if let single {
            rows.append(("Cells drawn", RNASeqEmbeddingWords.cellsDrawn(embedding.cells, of: facts.cellCount, sample: facts.sampleName(single.sample),
                                                                         leftOut: single.leftOut, embedding: embedding.name)))
        } else {
            rows += all.filter { $0.label == "Cells drawn" }
        }
        return rows
    }

    /// The fact lines of 5.5 V5, values as the manifest and the file hold them.
    func factLines(_ shown: RNASeqCellMapSnapshot) -> [(label: String, value: String)] {
        let facts = shown.facts
        let notRecorded = RNASeqResultBundle.notRecordedText
        var rows: [(label: String, value: String)] = [("Parent result", "\(parentName) (\(result?.manifest.parent?.path ?? notRecorded))")]
        guard let embedding = facts.embeddings.first(where: { $0.embedding == shown.points.embedding }) else { return rows }
        rows.append(("Embedding", "\(embedding.name), method \(embedding.method ?? notRecorded)"))
        rows.append(("Source", source(kind: embedding.source, file: embedding.sourceFile)))
        if case .labelSet(let id) = shown.colouring, let set = facts.labelSets.first(where: { $0.labelSet == id }) {
            rows.append(("Labels", "\(set.name), \(source(kind: set.source, file: set.sourceFile).prefix(1).lowercased())\(source(kind: set.source, file: set.sourceFile).dropFirst())"))
        }
        rows.append(("Cells drawn", "\(embedding.cells) of \(facts.cellCount)"))
        return rows
    }

    private func source(kind: String, file: String) -> String {
        let manifest = result?.manifest
        if kind == "imported" {
            let sha = manifest?.sourceFiles.first { $0.path == file }.map { String($0.sha256.prefix(12)) } ?? RNASeqResultBundle.notRecordedText
            return "Imported from \(Self.fileName(file)) (sha256 \(sha)), not computed by LGE"
        }
        let made = [manifest?.origin.tool, manifest?.origin.toolVersion].compactMap { $0 }.joined(separator: " ")
        return "Computed by \(made.isEmpty ? RNASeqResultBundle.notRecordedText : made)"
    }

    /// The parent's folder name, from the manifest's pointer. The view never opens the parent.
    private var parentName: String {
        guard let path = result?.manifest.parent?.path else { return RNASeqResultBundle.notRecordedText }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private static func fileName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    // MARK: - Raster and hover

    /// Draws the shown cells off the main actor at the plot's size. A newer request cancels this one.
    public func requestRaster() {
        guard let shown = snapshot, isViewLoaded else { return }
        let size = plot.pixelSize
        guard size.width > 0, size.height > 0 else { return }
        let colours = shown.colours
        let window = plotWindow ?? RNASeqEmbeddingWindow.fit(x: shown.points.x, y: shown.points.y, order: colours.order)
        let palette = RNASeqEmbeddingPalette.words(dark: plot.isDark)
        // With a selection the other cells draw faded, and the selected cells draw on top in a second raster.
        let chosen = selection?.embedding == shown.points.embedding ? selection?.mask : nil
        let input = RNASeqEmbeddingRasterInput(
            x: shown.points.x, y: shown.points.y, order: colours.order, colour: colours.index,
            palette: chosen == nil ? palette : RNASeqEmbeddingSelection.faded(palette), width: size.width, height: size.height,
            radius: max(Int((pointSize * size.scale / 2).rounded()), 0), window: window)
        rasterWork?.cancel()
        let mine = generation
        let task = Task { [weak self] in
            // The pixels' one copy into `Data` runs off the main actor with the raster, and the main actor only wraps it.
            guard let drawn = try? await offMain({ () throws -> (RNASeqEmbeddingRaster, Data, Data?, RNASeqEmbeddingRaster?) in
                let raster = try RNASeqEmbeddingRaster.draw(input)
                var top: RNASeqEmbeddingRaster?
                if let chosen {
                    var over = input
                    over.palette = palette
                    over.order = input.order.filter { Int($0) < chosen.count && chosen[Int($0)] }
                    top = try RNASeqEmbeddingRaster.draw(over)
                }
                return (raster, RNASeqEmbeddingPlotView.pixelData(of: raster), top.map(RNASeqEmbeddingPlotView.pixelData(of:)), top)
            }), let self, mine == self.generation, !Task.isCancelled else { return }
            self.plot.show(drawn.0, image: RNASeqEmbeddingPlotView.image(of: drawn.0, data: drawn.1), scale: size.scale)
            self.plot.showSelection(drawn.3.flatMap { top in drawn.2.flatMap { RNASeqEmbeddingPlotView.image(of: top, data: $0) } })
        }
        rasterWork = task
        work = task
    }

    /// Reads the barcode of the cell under the pointer by its id, off the main actor, one read in flight (5.5 V4). A
    /// pointer that moves inside the disc of the cell already read starts no new read.
    public func hover(_ cell: Int?) {
        guard cell != hoveredCell else { return }
        hoveredCell = cell
        hoverWork?.cancel()
        guard let cell, let shown = snapshot else {
            hoverWords = nil
            hoverField.stringValue = ""
            return
        }
        let database = shown.database
        hoverWork = Task { [weak self] in
            guard let found = try? await offMain({ try database.cell(id: cell + 1) }), let self, !Task.isCancelled,
                  let current = self.snapshot else { return }
            let words = RNASeqEmbeddingWords.hover(barcode: found.barcode, sample: current.facts.sampleName(found.sample),
                                                  value: self.valueWords(of: cell, in: current))
            self.hoverWords = words
            self.hoverField.stringValue = words
        }
    }

    /// Empties the hover line, drops a hover read in flight and forgets its cell, so the next hover reads again and no
    /// late read fills the line after it was emptied.
    private func clearHover() {
        hoverWork?.cancel()
        hoveredCell = nil
        hoverWords = nil
        hoverField.stringValue = ""
    }

    /// The value the colouring shows for a cell, as the file writes it.
    private func valueWords(of cell: Int, in shown: RNASeqCellMapSnapshot) -> String? {
        let title = shown.facts.title(of: shown.colouring)
        switch (shown.colouring, shown.values) {
        case (.labelSet(let id), .labels(let labels)):
            let label = cell < labels.count ? Int(labels[cell]) : 0
            let name = shown.facts.labelSets.first { $0.labelSet == id }?.labels.first { $0.label == label }?.name
            return "\(title) \(name ?? "no label")"
        case (.cellUMIs, .totals(let totals)), (.cellGenes, .totals(let totals)):
            return "\(title) \(cell < totals.count ? String(totals[cell]) : "0")"
        case (.gene, .gene(let read)):
            return "\(title) \(read.values.value(ofCell: cell + 1).map(RNASeqEmbeddingWords.number) ?? "0")"
        case (_, .counts(let cells, let values)):
            return "\(title) \(cells.firstIndex(of: cell + 1).map { RNASeqEmbeddingWords.number(values[$0]) } ?? "0")"
        case (_, .flags(let cells, let words)):
            return "\(title) \(cells.firstIndex(of: cell + 1).map { words[$0] } ?? RNASeqEmbeddingWords.notFlagged)"
        default:
            return nil
        }
    }

    // MARK: - Text

    /// Puts `views` in `stack` in place of what it held, and hides the stack when they are none.
    private static func replace(_ stack: NSStackView, with views: [NSView]) {
        for line in stack.arrangedSubviews {
            stack.removeArrangedSubview(line)
            line.removeFromSuperview()
        }
        for view in views { stack.addArrangedSubview(view) }
        stack.isHidden = views.isEmpty
    }

    static func text(_ string: String, id: String, wraps: Bool = false, width: CGFloat = contentWidth) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: string) : NSTextField(labelWithString: string)
        field.isEditable = false
        field.isSelectable = true
        field.setAccessibilityIdentifier(id)
        if wraps { field.preferredMaxLayoutWidth = width }
        return field
    }

    /// A fact row, its value wrapping in what the column leaves beside the name.
    private static func fact(_ label: String, _ value: String) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.textColor = .secondaryLabelColor
        name.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        let id = "rnaseq-cell-map-fact-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))"
        let spacing: CGFloat = 8
        let row = NSStackView(views: [name, text(value, id: id, wraps: true, width: contentWidth - ceil(name.intrinsicContentSize.width) - spacing)])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = spacing
        return row
    }

    /// A control row: the name, the control and its info button. A pop-up cut short truncates its title at the tail, and
    /// the name and the button keep their size.
    private static func control(_ label: String, _ control: NSView, info: NSView? = nil) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.textColor = .secondaryLabelColor
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        (control as? NSPopUpButton)?.cell.flatMap { $0 as? NSPopUpButtonCell }?.lineBreakMode = .byTruncatingTail
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [name, control] + (info.map { [$0] } ?? []))
        info?.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(lessThanOrEqualToConstant: contentWidth).isActive = true
        return row
    }
}

/// A document view whose rows run down from the top, so the column starts at the top of its scroll view.
private final class RNASeqCellMapFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The column's scroll view: the column's width plus the room a scroller takes when scroll bars always show, so the
/// column keeps its width and its content its 212 pt in either scroller style (5.6 L1).
final class RNASeqCellMapSideView: NSScrollView {
    var widthConstraint: NSLayoutConstraint?

    override var scrollerStyle: NSScroller.Style {
        didSet { widthConstraint?.constant = Self.width(for: scrollerStyle) }
    }

    static func width(for style: NSScroller.Style) -> CGFloat {
        RNASeqCellMapViewController.columnWidth + (style == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0)
    }
}
