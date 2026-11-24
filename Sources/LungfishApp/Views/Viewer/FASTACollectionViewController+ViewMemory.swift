// FASTACollectionViewController+ViewMemory.swift - The FASTA collection keeps its filter, sort, selection and detail pane
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One struct holds the view fields, `FASTACollectionSurface` adopts `ViewMemoryAdopting`, and the list applies each
// field through the path a person's change takes. Nothing here writes into the file or the project, and nothing
// starts a tool, a search or a write (VS S4).

import AppKit
import LungfishCore
import LungfishKit

/// The view the FASTA collection keeps for one file.
///
/// Each field and its class (VS B2 to B9):
/// - `filterText`, the list's filter field, is a search text (VS B6). It comes back only on an equal data key, and the
///   field and the count label show it in the viewport.
/// - `sort`, the column and direction of the list's header, is presentation and comes back while its column exists.
/// - `selected`, the selected records by their row identity (VS B4): the record's name with its place among the
///   records of that name in the file, 0 for the first, and the source file's name when the list holds several files
///   (`FASTACollectionViewController.viewMemoryIdentities()`). Never an index. A record that is gone is dropped.
/// - `detailHeight`, the height of the pane that shows the selected records, is presentation. Nil while it is the
///   list's starting height.
struct FASTACollectionViewState: ViewMemoryState {
    struct Sort: Codable, Sendable, Equatable {
        var key: String
        var ascending: Bool
    }

    static var kind: String { SurfaceKind.view(.fastaCollection).description }
    static var schemaVersion: Int { 1 }

    var filterText = ""
    var sort: Sort?
    var selected: [String] = []
    var selectionTooLarge = false
    var detailHeight: Double?

    var selectionCount: Int { selectionTooLarge ? Int.max : selected.count }

    func withoutSelection() -> FASTACollectionViewState {
        var view = self
        view.selected = []
        view.selectionTooLarge = false
        return view
    }
}

extension FASTACollectionViewController {
    /// The detail pane's height before a person moves it, the list's own `lastExpandedDetailHeight` at its start.
    static let startingDetailHeight: CGFloat = 180

    /// Each record's identity by its sequence id, in the file's order: the source file's name when the list holds
    /// several files, the record's name, and its place among the records of that name. A file that names two records
    /// alike keeps them apart, and a record keeps its identity through a sort or a filter.
    func viewMemoryIdentities() -> [UUID: String] {
        var seen: [String: Int] = [:]
        var identities: [UUID: String] = [:]
        for sequence in sequences {
            let name = (sourceNames[sequence.id] ?? "") + "\t" + sequence.name
            let place = seen[name, default: 0]
            seen[name] = place + 1
            identities[sequence.id] = "\(name)\t\(place)"
        }
        return identities
    }

    /// The view as the list's controls hold it now. It reads no file and no store.
    func captureFASTACollectionViewMemory() -> FASTACollectionViewState {
        var state = FASTACollectionViewState()
        state.filterText = filterText
        if !sortKey.isEmpty { state.sort = .init(key: sortKey, ascending: sortAscending) }
        let selected = selectedSequences()
        if !selected.isEmpty {
            let identities = viewMemoryIdentities()
            switch ViewMemoryRules.capSelection(selected.compactMap { identities[$0.id] }) {
            case .kept(let kept): state.selected = kept
            case .tooLarge: state.selectionTooLarge = true
            case .empty: break
            }
        }
        if abs(lastExpandedDetailHeight - Self.startingDetailHeight) >= 1 {
            state.detailHeight = Double(lastExpandedDetailHeight.rounded())
        }
        return state
    }

    /// Applies a kept view, each field by its rule, through the header, the filter field and the selection a person
    /// uses, and returns what it could not bring back. The detail pane takes its height once the list has a size.
    func applyFASTACollectionViewMemory(_ state: FASTACollectionViewState, dataChanged: Bool) -> ViewMemoryLoss {
        var lost: ViewMemoryLoss = []
        lastExpandedDetailHeight = state.detailHeight.map { CGFloat($0) } ?? Self.startingDetailHeight
        if let sort = state.sort, tableView.tableColumns.contains(where: { $0.sortDescriptorPrototype?.key == sort.key }) {
            tableView.sortDescriptors = [NSSortDescriptor(key: sort.key, ascending: sort.ascending)]
        } else if state.sort == nil, !sortKey.isEmpty {
            // Reset View: the file's own order, which the filter pass below rebuilds.
            sortKey = ""
            tableView.sortDescriptors = []
        }
        let text = dataChanged ? "" : state.filterText
        if dataChanged, !state.filterText.isEmpty { lost.insert(.filters) }
        searchField.stringValue = text
        filterText = text
        applyFilter()

        let identities = viewMemoryIdentities()
        let restore = ViewMemoryRules.keepIdentities(state.selected, existing: Set(identities.values))
        // A record that is gone is dropped, and only a changed key says so (adopters' lesson 11).
        if dataChanged, restore.lostAny { lost.insert(.selection) }
        let wanted = Set(restore.kept)
        restoreSelection(for: Set(identities.compactMap { wanted.contains($0.value) ? $0.key : nil }))
        updateSelectionDetail()
        refreshContextMenu()
        return lost
    }

    /// Gives the detail pane its kept height once the list has its size. It starts nothing.
    func placeDetailPane(height: CGFloat) {
        view.window?.layoutIfNeeded()
        lastExpandedDetailHeight = height
        guard !selectionDetailView.isHidden else { return }
        setDetailHeight(height)
    }
}

/// The item and data key a list read at its first show, kept for the way back from one record, which shows the same
/// list with no contents to read them from. The list holds it weakly, so it goes with the list.
@MainActor
final class FASTACollectionViewMemoryIdentity: NSObject {
    let item: ViewMemoryItem
    let dataKey: String?

    private init(item: ViewMemoryItem, dataKey: String?) {
        self.item = item
        self.dataKey = dataKey
    }

    private static let byList = NSMapTable<FASTACollectionViewController, FASTACollectionViewMemoryIdentity>
        .weakToStrongObjects()

    /// The identity of a list read from one file: the file's own identity and path (VS A3), and the data key of the
    /// record count with the file's size and date (VS B1), so an edit of the file changes it. It reads the disk.
    static func read(file: URL, recordCount: Int) -> FASTACollectionViewMemoryIdentity {
        let stamp = ViewMemoryFileStamp.text(of: file)
        return FASTACollectionViewMemoryIdentity(
            item: ViewMemoryItem.read(at: file),
            dataKey: stamp.map { ["FASTA collection v1", "\(recordCount)", $0].joined(separator: "\n") }
        )
    }

    static func remember(_ identity: FASTACollectionViewMemoryIdentity?, for list: FASTACollectionViewController) {
        if let identity { byList.setObject(identity, forKey: list) } else { byList.removeObject(forKey: list) }
    }

    static func remembered(for list: FASTACollectionViewController) -> FASTACollectionViewMemoryIdentity? {
        byList.object(forKey: list)
    }
}

extension FASTACollectionSurface: ViewMemoryAdopting {
    /// Reads where the list's file lives and its data key once, in `load`. The display has read the records before
    /// the show and this load cannot suspend, so the file's few attributes are read on the main actor, once a show, as
    /// SWIFT ruling R2 allows. A list of several files or of a project's sequences has no one file and keeps no view.
    /// The way back from one record shows the same list, which already holds its view, so it reads the identity its
    /// first show kept and starts from the list's starting view, through a handle applied on the next turn (VS S3).
    func readViewMemoryIdentity(of request: Input) {
        let identity: FASTACollectionViewMemoryIdentity?
        if let contents = request.contents {
            identity = contents.sourceFiles.count == 1
                ? FASTACollectionViewMemoryIdentity.read(file: contents.sourceFiles[0], recordCount: contents.sequences.count)
                : nil
            FASTACollectionViewMemoryIdentity.remember(identity, for: request.controller)
        } else {
            identity = FASTACollectionViewMemoryIdentity.remembered(for: request.controller)
            isWayBack = identity != nil
        }
        viewMemoryItem = identity?.item
        viewMemoryDataKey = identity?.dataKey
        guard isWayBack else { return }
        // The host sets the handle after this load returns, and the list as left differs from the starting view, so
        // the kept view does not apply over it and a later change is kept from the starting view.
        Task { @MainActor [weak self] in
            self?.viewMemoryHandle?.applyPending(startingView: FASTACollectionViewState())
        }
    }

    var viewMemoryLoadIsPending: Bool { isWayBack }

    func captureViewMemory() -> FASTACollectionViewState {
        controller?.captureFASTACollectionViewMemory() ?? FASTACollectionViewState()
    }

    func restoreViewMemory(_ state: FASTACollectionViewState, dataChanged: Bool) -> ViewMemoryLoss {
        guard let controller else { return [] }
        let lost = controller.applyFASTACollectionViewMemory(state, dataChanged: dataChanged)
        pendingDetailHeight = controller.lastExpandedDetailHeight
        if controller.view.window != nil { announceViewMemory() }
        return lost
    }

    /// The host calls this on the turn after the install, once the list sits in the window, so the detail pane can
    /// take its kept height. It starts nothing.
    func announceViewMemory() {
        guard let height = pendingDetailHeight, let controller else { return }
        pendingDetailHeight = nil
        controller.placeDetailPane(height: height)
    }
}
