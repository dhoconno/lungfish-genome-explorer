// FASTQDatasetViewController+ViewMemory.swift - The FASTQ dataset dashboard keeps its tab and its operations list width
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One struct holds the view fields, `FASTQDatasetSurface` adopts `ViewMemoryAdopting`, and the dashboard applies each
// field through the path a person's change takes. Nothing here writes into the bundle or the project, and nothing
// starts a tool or a write (VS S4).

import AppKit
import LungfishIO
import LungfishKit

/// The view the FASTQ dataset dashboard keeps for one dataset.
///
/// Each field and its class (VS B2 to B9):
/// - `middleTab`, Operations (0) or Reads (1), is presentation and comes back on any data key. The Reads tab reads the
///   first 1,000 records for its preview, as a click on the tab does.
/// - `operationsListWidth`, the width in points of the operations list beside the preview, is presentation and comes
///   back on any data key, within the list's own bounds. Nil while the list stands where the dashboard put it.
///
/// Never kept (VS B8, U1): the operation picked in the list, its typed values, the contaminant reference, the primer
/// trim and deduplicate settings and the metadata drawer, which are a run's inputs or a person's open pane. The top
/// split holds the summary at its fixed height, which no person can move, so it holds no view.
struct FASTQDatasetViewState: ViewMemoryState {
    static var kind: String { SurfaceKind.bundle(.fastq).description }
    static var schemaVersion: Int { 1 }

    var middleTab = 0
    var operationsListWidth: Double?
}

/// The size and modification time of a file, the stamp a data key holds (VS B1). Nil when the file does not read, so
/// the key never compares equal. It reads the disk, once a show.
enum ViewMemoryFileStamp {
    static func text(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size) \(modified.timeIntervalSince1970)"
    }
}

extension FASTQDatasetViewController {
    /// The kept width that the first layout gives the operations list in place of its default. The container holds it,
    /// since the surface restores before the dashboard has a size.
    var keptSidebarWidth: CGFloat? {
        (parent as? FASTQDatasetContainerController)?.keptOperationsListWidth
    }

    /// The operations list's width now, nil before the first layout placed it.
    var operationsListWidth: CGFloat? {
        guard didApplyInitialSplitPositions, let list = middleSplitView.subviews.first else { return nil }
        return list.frame.width
    }

    /// The width the first layout gives the list in a split of this width (`applyInitialSplitPositionsIfNeeded`).
    var defaultOperationsListWidth: CGFloat {
        max(
            LayoutDefaults.minSidebarWidth,
            min(middleSplitView.bounds.width * LayoutDefaults.preferredSidebarFraction, LayoutDefaults.maxSidebarWidth)
        )
    }

    /// Shows a tab as a click on it does, so the Reads tab starts its preview as the click does and nothing more.
    func showMiddleTab(_ tab: Int) {
        guard tab >= 0, tab < middleTabControl.segmentCount, tab != middleTabControl.selectedSegment else { return }
        middleTabControl.selectedSegment = tab
        middleTabChanged(middleTabControl)
    }
}

extension FASTQDatasetSurface: ViewMemoryAdopting {
    /// Reads where the dataset lives and its data key once, in `load`. The display has read the statistics before the
    /// show and this load cannot suspend, so the item's few file attributes are read on the main actor, once a show, as
    /// SWIFT ruling R2 allows for the 12S and Kraken2 surfaces. The item is the FASTQ bundle, or the reads file when no
    /// bundle holds it. The data key is the read count with the reads file's size and date, so an import or an edit of
    /// the reads changes it. Every kept field is presentation, so the key decides no field today.
    func readViewMemoryIdentity(of request: Input) {
        let itemURL = request.sourceURL ?? request.fastqURL
        viewMemoryItem = itemURL.map { ViewMemoryItem.read(at: $0) }
        let stamp = (request.fastqURL ?? itemURL).flatMap { ViewMemoryFileStamp.text(of: $0) }
        viewMemoryDataKey = stamp.map { ["FASTQ v1", "\(request.statistics.readCount)", $0].joined(separator: "\n") }
    }

    /// The view as the dashboard's controls hold it now. It reads no file and no store.
    func captureViewMemory() -> FASTQDatasetViewState {
        guard let container else { return FASTQDatasetViewState() }
        return FASTQDatasetViewState(
            middleTab: container.dashboard.middleTabControl.selectedSegment,
            operationsListWidth: widthToKeep(in: container)
        )
    }

    /// The kept width while the list stands there, nil while it stands at the dashboard's default, else the width the
    /// person left (VS S3: a width the app set is never kept as a choice).
    private func widthToKeep(in container: FASTQDatasetContainerController) -> Double? {
        let kept = container.keptOperationsListWidth
        guard let width = container.dashboard.operationsListWidth else { return kept.map { Double($0) } }
        if let kept, abs(width - kept) < 1 { return Double(kept) }
        if abs(width - container.dashboard.defaultOperationsListWidth) < 1 { return nil }
        return Double(width.rounded())
    }

    /// Applies a kept view. Both fields are presentation, so nothing is lost on a changed key and no line shows.
    func restoreViewMemory(_ state: FASTQDatasetViewState, dataChanged: Bool) -> ViewMemoryLoss {
        guard let container else { return [] }
        let dashboard = container.dashboard
        dashboard.showMiddleTab(state.middleTab)
        let width = state.operationsListWidth.map { CGFloat($0) }
        container.keptOperationsListWidth = width
        // Before the first layout the dashboard puts the list at the kept width in place of its default. After it, as
        // on Reset View, the list moves now.
        if dashboard.didApplyInitialSplitPositions {
            dashboard.middleSplitView.setPosition(width ?? dashboard.defaultOperationsListWidth, ofDividerAt: 0)
        }
        return []
    }
}
