// RNASeqEmbeddingSelection.swift - Selecting cells in the embedding view (Phase 5.5 lane CM-SELECT-APP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A person selects cells with a lasso, a legend row or the keyboard (5.5 S1 to S3, UX U-A2). Selecting writes nothing.
// The highlight and the count on screen come from LungfishIO's one membership function, `RNASeqCellMapSelection`, run off
// the main actor on the Float32 points of `coordinates(embedding:)`, and the newest request wins. A lasso is simplified
// by one fixed rule to at most `RNASeqCellMapSelection.maximumVertices` vertices before the highlight is drawn and before
// the polygon is handed on, so the view's cells and the cells `lungfish-cli rnaseq cell-map select` writes are the same.
// Saving and pseudobulking go to the App through `RNASeqResultSurface.onSelectionAction`, which launches that leaf.

import AppKit
import LungfishIO
import LungfishWorkflow

/// The words of selecting. UX reads them at the notes step.
public enum RNASeqEmbeddingSelectionWords {
    public static let saveTitle = "Save Selection as Labels Table…"
    public static let pseudobulkTitle = "Pseudobulk Selected Cells…"
    public static let selectAllTitle = "Select All Cells"
    public static let clearTitle = "Clear Selection"
    /// The VoiceOver action on each legend child of the plot group (5.5 V2).
    public static let selectAction = "Select these cells"
    public static let none = "No cells selected. Drag around cells, or click a legend row."
    public static let noOneCommand = "One lungfish-cli command cannot name this selection, since it joins lassos or picks samples. "
        + "Draw one lasso, or pick labels of one label set, to save it or pseudobulk it."

    public static func count(_ cells: Int) -> String {
        cells == 1 ? "1 cell selected" : "\(RNASeqCellMapImportRefusal.number(cells)) cells selected"
    }

    /// What the pseudobulk dialog shows in place of a file path (UX OBJECT U8).
    public static func fromCellMap(_ cells: Int, cellMap: String) -> String {
        "\(RNASeqCellMapImportRefusal.number(cells)) selected \(cells == 1 ? "cell" : "cells") from \(cellMap)"
    }

    /// The line beside the count for a sample whose selection is under 10 cells (CM-SELECT-CLI-BIO backlog 10).
    public static func underTen(sample: String, cells: Int) -> String {
        "\(sample) holds \(cells) selected \(cells == 1 ? "cell" : "cells"), under 10, so the pseudobulk leaves out its selected column "
            + "and counts those cells with the cells that have no label."
    }
}

/// The selected cells of one sample.
public struct RNASeqEmbeddingSelectionSample: Equatable, Sendable {
    public var sample: String
    public var selected: Int
}

/// What is selected in the embedding on show. The mask is in cell order over every cell of the map.
public struct RNASeqEmbeddingSelection: Sendable {
    public enum Mode: Equatable, Sendable {
        case replace
        case add
        case subtract
    }

    public var embedding: Int
    public var mask: [Bool]
    public var count: Int
    public var samples: [RNASeqEmbeddingSelectionSample]
    /// The one `cell-map select` form that names these cells, or nil when no single command names them.
    public var form: RNASeqCellMapSelect.Form?
    /// The legend rows the cells were picked by, in the colouring `rowsColouring`, and empty for a lasso.
    public var rows: Set<Int>
    public var rowsColouring: RNASeqCellMapColouring?
    /// The lasso's polygon in the plane, for the outline, and nil for a selection by rows.
    public var polygon: [RNASeqCellMapSelection.Vertex]?

    /// Combines a new membership with what was selected. A mask of another length starts again.
    public static func combine(_ base: [Bool]?, _ new: [Bool], mode: Mode) -> [Bool] {
        guard let base, base.count == new.count, mode != .replace else { return mode == .subtract ? [Bool](repeating: false, count: new.count) : new }
        var out = base
        for cell in out.indices where new[cell] { out[cell] = mode == .add }
        return out
    }

    /// The selected cells of each sample. Cells are numbered over all samples in sample order, so a sample's cells follow
    /// those of the samples before it (`docs/formats/rnaseq-cell-map.md`, cellmap.sqlite).
    public static func sampleCounts(_ mask: [Bool], samples: [RNASeqCellMapDatabase.Sample]) -> [RNASeqEmbeddingSelectionSample] {
        var start = 0
        return samples.map { sample in
            let end = min(start + sample.cells, mask.count)
            let selected = start < end ? mask[start..<end].reduce(0) { $0 + ($1 ? 1 : 0) } : 0
            start += sample.cells
            return RNASeqEmbeddingSelectionSample(sample: sample.name, selected: selected)
        }
    }

    /// The membership of a rule through the one function, combined with `base`, and its counts. It reads no file, so a
    /// detached task runs it.
    public static func make(points: RNASeqCellMapPoints, rule: RNASeqCellMapSelection.Rule, base: [Bool]?, mode: Mode,
                            samples: [RNASeqCellMapDatabase.Sample]) -> (mask: [Bool], count: Int, samples: [RNASeqEmbeddingSelectionSample]) {
        let inside = RNASeqCellMapSelection.mask(x: points.x, y: points.y, rule: rule)
        let mask = combine(base, inside, mode: mode)
        return (mask, mask.reduce(0) { $0 + ($1 ? 1 : 0) }, sampleCounts(mask, samples: samples))
    }

    /// A box around every drawn point, so the plain rule holds each of them, for Command-A. Nil when no point is drawn.
    public static func box(around points: RNASeqCellMapPoints) -> [RNASeqCellMapSelection.Vertex]? {
        var lowX = Float32.infinity, highX = -Float32.infinity, lowY = Float32.infinity, highY = -Float32.infinity
        for cell in points.x.indices where points.isDrawn(cell) {
            lowX = min(lowX, points.x[cell])
            highX = max(highX, points.x[cell])
            lowY = min(lowY, points.y[cell])
            highY = max(highY, points.y[cell])
        }
        guard lowX <= highX, lowY <= highY else { return nil }
        let margin = max(1, (highX - lowX) / 100, (highY - lowY) / 100)
        let left = lowX - margin, right = highX + margin, bottom = lowY - margin, top = highY + margin
        return [.init(x: left, y: bottom), .init(x: right, y: bottom), .init(x: right, y: top), .init(x: left, y: top)]
    }

    /// The lines under the count, one for each sample whose selection is 1 to 9 cells.
    public var underTenWords: [String] {
        samples.filter { $0.selected > 0 && $0.selected < 10 }.map { RNASeqEmbeddingSelectionWords.underTen(sample: $0.sample, cells: $0.selected) }
    }
}

/// The lasso's one fixed rule. A point closer than `minimumStep` view points to the last one kept is dropped, then, while
/// more than `limit` remain, every k-th point is kept from the first, with k the smallest whole number that leaves at most
/// `limit`. The rule is the same for every lasso, so the same drag gives the same polygon.
public enum RNASeqEmbeddingLasso {
    public static let minimumStep: CGFloat = 2

    public static func simplify(_ points: [CGPoint], limit: Int = RNASeqCellMapSelection.maximumVertices) -> [CGPoint] {
        var kept: [CGPoint] = []
        kept.reserveCapacity(points.count)
        for point in points {
            if let last = kept.last, hypot(point.x - last.x, point.y - last.y) < minimumStep { continue }
            kept.append(point)
        }
        guard limit > 0, kept.count > limit else { return kept }
        let step = (kept.count + limit - 1) / limit
        return stride(from: 0, to: kept.count, by: step).map { kept[$0] }
    }

    /// The plane's Float32 vertices under view points of a plot that shows `raster` at `scale` pixels a point.
    public static func vertices(_ points: [CGPoint], raster: RNASeqEmbeddingRaster, viewHeight: CGFloat, scale: CGFloat) -> [RNASeqCellMapSelection.Vertex] {
        points.map { point in
            let plane = raster.mapping.point(column: Float32(point.x * scale), row: Float32((viewHeight - point.y) * scale))
            return RNASeqCellMapSelection.Vertex(x: plane.x, y: plane.y)
        }
    }
}

/// What the App is asked to do with a selection. The App launches `lungfish-cli rnaseq cell-map select`, so the module
/// writes nothing.
public struct RNASeqEmbeddingSelectionRequest: Equatable, Sendable {
    public var cellMapURL: URL
    /// The cell map's name as its manifest gives it.
    public var cellMapName: String
    /// The parent single-cell result, resolved from the folder that holds the cell map, or nil when the manifest names none.
    public var parentURL: URL?
    public var embedding: String
    public var form: RNASeqCellMapSelect.Form
    public var count: Int
    public var underTenWords: [String]

    public init(cellMapURL: URL, cellMapName: String, parentURL: URL?, embedding: String, form: RNASeqCellMapSelect.Form, count: Int,
                underTenWords: [String]) {
        self.cellMapURL = cellMapURL
        self.cellMapName = cellMapName
        self.parentURL = parentURL
        self.embedding = embedding
        self.form = form
        self.count = count
        self.underTenWords = underTenWords
    }
}

public enum RNASeqEmbeddingSelectionAction: Equatable, Sendable {
    case saveLabelsTable(RNASeqEmbeddingSelectionRequest)
    case pseudobulk(RNASeqEmbeddingSelectionRequest)
}

extension RNASeqEmbeddingSelection {
    /// The palette at 30% in premultiplied form, which the cells outside a selection are drawn in, so the selected cells
    /// on top stand out.
    public static func faded(_ palette: [UInt32]) -> [UInt32] {
        palette.map { word in
            var out: UInt32 = 0
            for shift in stride(from: 0, through: 24, by: 8) {
                out |= UInt32((Double(word >> UInt32(shift) & 0xFF) * 0.3).rounded()) << UInt32(shift)
            }
            return out
        }
    }
}

// MARK: - The view's selection

extension RNASeqCellMapViewController {
    /// Selects the cells inside a polygon of the plane. Shift adds and Option takes away. A polygon of more than
    /// `RNASeqCellMapSelection.maximumVertices` keeps every k-th vertex by the lasso's rule.
    public func selectPolygon(_ given: [RNASeqCellMapSelection.Vertex], mode: RNASeqEmbeddingSelection.Mode = .replace) {
        guard let shown = snapshot, given.count >= RNASeqCellMapSelection.minimumVertices else { return }
        let limit = RNASeqCellMapSelection.maximumVertices
        let vertices = given.count <= limit ? given : stride(from: 0, to: given.count, by: (given.count + limit - 1) / limit).map { given[$0] }
        let hasBase = selection?.embedding == shown.points.embedding
        if mode == .subtract && !hasBase { return }
        let single = mode == .replace || !hasBase
        runSelection(rule: { .polygon(vertices) }, mode: single ? .replace : mode, form: single ? .polygon(vertices) : nil,
                     rows: [], rowsColouring: nil, polygon: single ? vertices : nil)
    }

    /// A click on a legend row selects its cells, and Command-click adds them.
    public func selectLegendRow(_ row: Int, adding: Bool) {
        guard let shown = snapshot else { return }
        let current = selection.flatMap { $0.embedding == shown.points.embedding && $0.rowsColouring == shown.colouring && !$0.rows.isEmpty ? $0 : nil }
        if adding, current == nil, selection?.embedding == shown.points.embedding {
            selectRows([row], mode: .add)
        } else {
            selectRows(adding ? (current?.rows ?? []).union([row]) : [row], mode: .replace)
        }
    }

    /// Space on the focused legend row adds its cells, or takes them away when the row is selected.
    public func toggleLegendRow(_ row: Int) {
        guard let shown = snapshot else { return }
        guard let current = selection, current.embedding == shown.points.embedding, current.rowsColouring == shown.colouring, !current.rows.isEmpty else {
            return selectLegendRow(row, adding: true)
        }
        let rows = current.rows.symmetricDifference([row])
        if rows.isEmpty { clearSelection() } else { selectRows(rows, mode: .replace) }
    }

    /// Command-A selects every drawn cell, as a box around them, which `cell-map select` takes as a polygon.
    public func selectAllCells() {
        guard let shown = snapshot, let box = RNASeqEmbeddingSelection.box(around: shown.points) else { return }
        runSelection(rule: { .polygon(box) }, mode: .replace, form: .polygon(box), rows: [], rowsColouring: nil, polygon: box)
    }

    /// Escape empties the selection.
    public func clearSelection() {
        selectionGeneration += 1
        selectionWork?.cancel()
        selection = nil
        showSelection()
        requestRaster()
    }

    /// The legend rows as the one function's label form. A label set's rows give its label numbers, each kept inside
    /// `1...labels.count` as `cell-map select` keeps them, and the sample's rows give each cell's sample place plus 1.
    private func selectRows(_ rows: Set<Int>, mode: RNASeqEmbeddingSelection.Mode) {
        guard let shown = snapshot, !rows.isEmpty else { return }
        let facts = shown.facts
        switch (shown.colouring, shown.values) {
        case (.labelSet(let id), .labels(let labels)):
            guard let set = facts.labelSets.first(where: { $0.labelSet == id }),
                  rows.allSatisfy({ set.labels.indices.contains($0) && (1...set.labels.count).contains(set.labels[$0].label) }) else { return }
            let chosen = Set(rows.map { UInt32(set.labels[$0].label) })
            let form: RNASeqCellMapSelect.Form? = mode == .replace ? .labels(set: set.name, labels: rows.sorted().map { set.labels[$0].name }) : nil
            runSelection(rule: { .labels(labels, chosen: chosen) }, mode: mode, form: form, rows: mode == .replace ? rows : [],
                         rowsColouring: mode == .replace ? shown.colouring : nil, polygon: nil)
        case (.sample, _):
            guard rows.allSatisfy({ facts.samples.indices.contains($0) }) else { return }
            let chosen = Set(rows.map { UInt32($0 + 1) })
            let count = shown.points.x.count
            let samples = facts.samples
            runSelection(rule: {
                var places = ContiguousArray<UInt32>(repeating: 0, count: count)
                var start = 0
                for (place, sample) in samples.enumerated() {
                    for cell in start..<max(start, min(start + sample.cells, count)) { places[cell] = UInt32(place + 1) }
                    start += sample.cells
                }
                return .labels(places, chosen: chosen)
            }, mode: mode, form: nil, rows: mode == .replace ? rows : [], rowsColouring: mode == .replace ? shown.colouring : nil, polygon: nil)
        default:
            return
        }
    }

    /// Runs the membership off the main actor. A newer request cancels this one, and only the newest is shown.
    private func runSelection(rule: @escaping @Sendable () -> RNASeqCellMapSelection.Rule, mode: RNASeqEmbeddingSelection.Mode,
                              form: RNASeqCellMapSelect.Form?, rows: Set<Int>, rowsColouring: RNASeqCellMapColouring?,
                              polygon: [RNASeqCellMapSelection.Vertex]?) {
        guard let shown = snapshot else { return }
        let points = shown.points
        let samples = shown.facts.samples
        let base = selection?.embedding == points.embedding ? selection?.mask : nil
        selectionWork?.cancel()
        selectionGeneration += 1
        let mine = selectionGeneration
        selectionWork = Task { [weak self] in
            guard let made = try? await offMain({ RNASeqEmbeddingSelection.make(points: points, rule: rule(), base: base, mode: mode, samples: samples) }),
                  let self, mine == self.selectionGeneration, !Task.isCancelled, self.snapshot?.points.embedding == points.embedding else { return }
            self.selection = made.count == 0 ? nil : RNASeqEmbeddingSelection(
                embedding: points.embedding, mask: made.mask, count: made.count, samples: made.samples, form: form, rows: rows,
                rowsColouring: rowsColouring, polygon: polygon)
            self.showSelection()
            self.requestRaster()
        }
    }

    /// The lasso a drag drew, in view points, simplified by the fixed rule before it becomes the plane's vertices.
    func lasso(_ viewPoints: [CGPoint], modifiers: NSEvent.ModifierFlags) {
        guard let raster = plot.raster else { return }
        let simplified = RNASeqEmbeddingLasso.simplify(viewPoints)
        guard simplified.count >= RNASeqCellMapSelection.minimumVertices else { return }
        let vertices = RNASeqEmbeddingLasso.vertices(simplified, raster: raster, viewHeight: plot.bounds.height, scale: plot.rasterScale)
        selectPolygon(vertices, mode: modifiers.contains(.shift) ? .add : modifiers.contains(.option) ? .subtract : .replace)
    }

    /// The count, the lines of samples under 10 cells, the note of a selection no command names, the actions, the legend's
    /// marks, and VoiceOver's announcement of the count.
    func showSelection() {
        let words = selection.map { RNASeqEmbeddingSelectionWords.count($0.count) } ?? RNASeqEmbeddingSelectionWords.none
        selectionField.stringValue = words
        let notes = selection.map { $0.form == nil ? [RNASeqEmbeddingSelectionWords.noOneCommand] : $0.underTenWords } ?? []
        selectionNote.stringValue = notes.joined(separator: "\n")
        selectionNote.isHidden = notes.isEmpty
        let named = selectionRequest() != nil
        saveSelectionButton.isEnabled = named
        pseudobulkSelectionButton.isEnabled = named && result?.manifest.parent != nil
        legendView.mark(selection.flatMap { $0.rowsColouring == snapshot?.colouring ? $0.rows : nil } ?? [])
        guard words != selectionAnnouncement else { return }
        selectionAnnouncement = words
        NSAccessibility.post(element: plot, notification: .announcementRequested, userInfo: [
            .announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// What the App needs to save or pseudobulk the selection, or nil when nothing is selected or no single command names it.
    public func selectionRequest() -> RNASeqEmbeddingSelectionRequest? {
        guard let shown = snapshot, let selection, selection.embedding == shown.points.embedding, let form = selection.form,
              let bundleURL, let result else { return nil }
        let name = shown.facts.embeddings.first { $0.embedding == selection.embedding }?.name ?? ""
        let parent = result.manifest.parent.map { bundleURL.deletingLastPathComponent().appendingPathComponent($0.path).standardizedFileURL }
        return RNASeqEmbeddingSelectionRequest(cellMapURL: bundleURL, cellMapName: result.manifest.name, parentURL: parent, embedding: name,
                                               form: form, count: selection.count, underTenWords: selection.underTenWords)
    }

    @objc public func saveSelectionAsLabelsTable(_ sender: Any?) {
        if let request = selectionRequest() { onSelectionAction?(.saveLabelsTable(request)) }
    }

    @objc public func pseudobulkSelectedCells(_ sender: Any?) {
        if let request = selectionRequest(), request.parentURL != nil { onSelectionAction?(.pseudobulk(request)) }
    }

    @objc func selectAllCellsAction(_ sender: Any?) { selectAllCells() }
    @objc func clearSelectionAction(_ sender: Any?) { clearSelection() }

    /// The plot's context menu.
    func selectionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let named = selectionRequest() != nil
        let items: [(String, Selector, Bool)] = [
            (RNASeqEmbeddingSelectionWords.saveTitle, #selector(saveSelectionAsLabelsTable(_:)), named),
            (RNASeqEmbeddingSelectionWords.pseudobulkTitle, #selector(pseudobulkSelectedCells(_:)), named && result?.manifest.parent != nil),
            (RNASeqEmbeddingSelectionWords.selectAllTitle, #selector(selectAllCellsAction(_:)), snapshot != nil),
            (RNASeqEmbeddingSelectionWords.clearTitle, #selector(clearSelectionAction(_:)), selection != nil),
        ]
        for (index, entry) in items.enumerated() {
            if index == 2 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.0, action: entry.1, keyEquivalent: "")
            item.target = self
            item.isEnabled = entry.2
            menu.addItem(item)
        }
        return menu
    }
}
