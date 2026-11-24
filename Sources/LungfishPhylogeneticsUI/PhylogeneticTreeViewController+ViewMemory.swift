// PhylogeneticTreeViewController+ViewMemory.swift - The tree viewer keeps its view for each tree bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The tree adopts view memory as the 12S template does (`TwelveSSurface+ViewMemory.swift`). The surface's load reads
// the bundle and does not suspend, so the host restores the kept view before the install and no change of a person's
// can come first (VS A2). Nothing here reads or writes the bundle's own `.viewstate.json`, which its creation writes
// under the manifest checksums (VS A5), and `PhylogeneticTreeViewState` in LungfishIO stays private. Nothing here
// starts a tool, a write or a search (VS S4).

import AppKit
import LungfishIO
import LungfishKit

extension PhylogeneticTreeSurface {
    /// The view the tree viewer keeps for one tree bundle.
    ///
    /// Each field and its class (VS B2 to B9):
    /// - `cladogram`, `colorMode`, `zoomScale`, `tipLabelColumn`, `findText` and `columnWidths` are presentation and
    ///   come back on any key. A tip label column the bundle no longer has falls back to the original labels. The find
    ///   field moves the selection and hides no node, so it is no count filter of VS B6, and the restore runs no find.
    ///   `columnWidths` holds every node table column but the one the table fits to the drawer (see
    ///   `viewMemoryColumns`), so the window's layout alone changes no kept field (SWIFT SF-2).
    /// - `collapsedNodeIDs` are clades by node id, a stable identity made from the node's place and labels. Each one
    ///   the tree still has comes back on any key, before the selection, so a kept node under a collapsed clade is
    ///   found (lesson 11).
    /// - `scrollX` and `scrollY` are the pan, a place in the drawn tree. They come back only on an equal key and are
    ///   dropped otherwise, with the line.
    /// - `selection` is the selected node by node id with any other selected tips (VS B4). It comes back only on an
    ///   equal tree key and is dropped otherwise, with the line, so Extract Subtree acts only on a node the person
    ///   picked. It is nil while the selection is the one the open makes (VS S3).
    ///
    /// The type is public because `PhylogeneticTreeSurface` and `ViewMemoryAdopting` are. It is nested, so it is no
    /// top-level public type, and its fields stay internal.
    public struct TreeViewState: ViewMemoryState {
        public static var kind: String { SurfaceKind.bundle(.phylogeneticTree).description }
        public static var schemaVersion: Int { 1 }

        /// The selected node and every selected node, by node id.
        struct Selection: Codable, Sendable, Equatable {
            var nodeID: String
            var nodeIDs: [String]
        }

        var cladogram: Bool
        var zoomScale: Double
        var scrollX: Double
        var scrollY: Double
        var collapsedNodeIDs: [String]
        var colorMode: Int
        var columnWidths: [String: Double]
        var tipLabelColumn: String
        var findText: String
        var selection: Selection?

        public var selectionCount: Int { selection?.nodeIDs.count ?? 0 }

        public func withoutSelection() -> TreeViewState {
            var view = self
            view.selection = nil
            return view
        }
    }
}

extension PhylogeneticTreeSurface: ViewMemoryAdopting {
    /// Reads where the bundle lives and its data key once, in `load`, so a capture and a restore read only memory. The
    /// route needs the viewer installed when `show` returns (`ViewerViewController+AlignmentTreeBundles.swift`), so
    /// this load cannot suspend and reads the folder's few attributes on the main actor beside the bundle read the
    /// viewer already makes there, as 12S does under SWIFT ruling R2. The data key reads only the loaded manifest.
    func readViewMemoryIdentity(at url: URL) {
        viewMemoryItem = ViewMemoryItem.read(at: url)
        viewMemoryDataKey = Self.viewMemoryDataKey(of: controller?.bundle?.manifest)
    }

    /// The data key of VS B1: one digest of the manifest's identifier and the checksums it records for the Newick tree
    /// and the normalized tree the node ids come from. A new import, a reroot or a rebuild at the same path changes it.
    /// A manifest without either checksum gives no key, which never compares equal.
    nonisolated static func viewMemoryDataKey(of manifest: PhylogeneticTreeManifest?) -> String? {
        guard let manifest else { return nil }
        var checksums: [String: String] = [:]
        for path in ["tree/primary.nwk", "tree/primary.normalized.json"] {
            guard let checksum = manifest.checksums[path] else { return nil }
            checksums[path] = checksum
        }
        let key = ViewMemoryDataKey.payload(
            manifestIdentifier: manifest.identifier, recordID: nil, payloadChecksums: checksums)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(key)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The view as the viewer's controls hold it now. It reads no file and no store.
    public func captureViewMemory() -> TreeViewState {
        guard let controller else {
            return TreeViewState(
                cladogram: false, zoomScale: 1, scrollX: 0, scrollY: 0, collapsedNodeIDs: [], colorMode: 0,
                columnWidths: [:], tipLabelColumn: "Original", findText: "", selection: nil)
        }
        return controller.capturedViewMemory()
    }

    /// Applies a kept view, each field by its rule, and starts nothing.
    public func restoreViewMemory(_ state: TreeViewState, dataChanged: Bool) -> ViewMemoryLoss {
        controller?.restoreViewMemory(state, dataChanged: dataChanged) ?? []
    }

    /// Tells the Inspector the selected node through the viewer's own callback. At the install the route wires it
    /// after the show and tells the Inspector itself, so this reaches it after a reset.
    public func announceViewMemory() {
        controller?.notifySelectionStateIfAvailable()
    }
}

extension PhylogeneticTreeViewController {
    /// The node the open selects: the first tip, else the first node.
    var openingNodeID: String? {
        (nodes.first(where: \.isTip) ?? nodes.first)?.id
    }

    /// The node table's columns whose width only a person sets. The table keeps AppKit's default
    /// `lastColumnOnlyAutoresizingStyle`, so each change of the drawer's width, the install's first layout included,
    /// sizes its last column to fit (`superviewFrameChanged:` then `sizeLastColumnToFit`). That width is the layout's,
    /// so it is neither kept nor restored: the start taken before the install would otherwise differ from every later
    /// capture, and a visit with no change would keep an entry (SWIFT SF-2).
    var viewMemoryColumns: ArraySlice<NSTableColumn> {
        let columns = nodeTableView.tableColumns[...]
        return nodeTableView.columnAutoresizingStyle == .lastColumnOnlyAutoresizingStyle ? columns.dropLast() : columns
    }

    func capturedViewMemory() -> PhylogeneticTreeSurface.TreeViewState {
        let origin = treeScrollView.contentView.bounds.origin
        let opening = openingNodeID.map { selectedNodeID == $0 && selectedNodeIDs == [$0] } ?? (selectedNodeID == nil)
        let widths = viewMemoryColumns.map { ($0.identifier.rawValue, Double($0.width)) }
        return PhylogeneticTreeSurface.TreeViewState(
            cladogram: treeCanvasView.layoutMode == .cladogram,
            zoomScale: Double(treeCanvasView.zoomScale),
            scrollX: Double(origin.x),
            scrollY: Double(origin.y),
            collapsedNodeIDs: collapsedNodeIDs.sorted(),
            colorMode: colorModeControl.selectedSegment,
            columnWidths: Dictionary(widths) { first, _ in first },
            tipLabelColumn: tipLabelColumnPopup.titleOfSelectedItem ?? "Original",
            findText: searchField.stringValue,
            selection: opening ? nil : selectedNodeID.map {
                PhylogeneticTreeSurface.TreeViewState.Selection(nodeID: $0, nodeIDs: selectedNodeIDs.sorted())
            }
        )
    }

    /// Applies a kept view: the look first, then the clades, then the selection, then the zoom and the pan, so the pan
    /// lands on the tree as drawn. A loss is reported only when the data key changed (lesson 11).
    func restoreViewMemory(_ state: PhylogeneticTreeSurface.TreeViewState, dataChanged: Bool) -> ViewMemoryLoss {
        var lost: ViewMemoryLoss = []
        let layout: PhylogeneticTreeCanvasLayoutMode = state.cladogram ? .cladogram : .phylogram
        if treeCanvasView.layoutMode != layout {
            treeCanvasView.layoutMode = layout
            layoutModeControl.selectedSegment = state.cladogram ? 1 : 0
        }
        let colorModes: [PhylogeneticTreeCanvasColorMode] = [.none, .support, .branchLength]
        if colorModes.indices.contains(state.colorMode), colorModeControl.selectedSegment != state.colorMode {
            colorModeControl.selectedSegment = state.colorMode
            treeCanvasView.colorMode = colorModes[state.colorMode]
            refreshSupportLegend()
        }
        let tipLabel = tipLabelColumnPopup.titleOfSelectedItem ?? "Original"
        if state.tipLabelColumn != tipLabel, tipLabelColumnPopup.itemTitles.contains(state.tipLabelColumn) {
            tipLabelColumnPopup.selectItem(withTitle: state.tipLabelColumn)
            applyTipLabelColumn(state.tipLabelColumn)
        }
        let collapsed = Set(state.collapsedNodeIDs.filter { nodesByID[$0].map { !$0.isTip } ?? false })
        if collapsed != collapsedNodeIDs {
            collapsedNodeIDs = collapsed
            treeCanvasView.collapsedNodeIDs = collapsed
            nodeTableView.reloadData()
        }

        if let kept = state.selection {
            if dataChanged {
                lost.insert(.selection)
            } else if nodesByID[kept.nodeID] != nil {
                let others = ViewMemoryRules.keepIdentities(kept.nodeIDs, existing: Set(nodesByID.keys)).kept
                    .filter { $0 != kept.nodeID }
                if let first = others.first {
                    selectNode(id: first, center: false)
                    for id in others.dropFirst() { selectNode(id: id, center: false, extendingSelection: true) }
                    selectNode(id: kept.nodeID, center: false, extendingSelection: true)
                } else {
                    selectNode(id: kept.nodeID, center: false)
                }
            }
        } else if let opening = openingNodeID, selectedNodeID != opening || selectedNodeIDs != [opening] {
            selectInitialNode()
        }

        let zoom = CGFloat(state.zoomScale)
        if zoom > 0, abs(zoom - treeCanvasView.zoomScale) > 0.0001 {
            treeCanvasView.resetView()
            if abs(zoom - 1) > 0.0001 { treeCanvasView.zoom(by: zoom) }
        }
        for column in viewMemoryColumns {
            if let width = state.columnWidths[column.identifier.rawValue], abs(CGFloat(width) - column.width) > 0.5 {
                column.width = CGFloat(width)
            }
        }
        searchField.stringValue = state.findText

        let origin = NSPoint(x: state.scrollX, y: state.scrollY)
        if dataChanged {
            if origin != .zero { lost.insert(.place) }
        } else if treeScrollView.contentView.bounds.origin != origin {
            treeScrollView.contentView.scroll(to: origin)
            treeScrollView.reflectScrolledClipView(treeScrollView.contentView)
        }
        return lost
    }
}
