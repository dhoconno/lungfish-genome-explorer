// InspectorViewController+ViewMemory.swift - The Inspector keeps its tab and disclosures per item and serves Reset View
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishGenotypeUI
import LungfishKit

/// The Inspector's view of one item (plan row I, VS U7): the tab a person picked, the "Samples & Metadata" disclosure
/// and the View tab's read style subsection. None acts on data, so each restores on any data key. The item keeps it in
/// a record of its own, beside the viewer's, and never in the bundle.
struct InspectorViewMemory: ViewMemoryState {
    static let kind = "inspector"
    static let schemaVersion = 1

    /// The tab a person picked, nil while the content's own tab shows.
    var tab: String?
    var samplesExpanded = true
    var readStyleSubsection = ReadStyleViewSubsection.alignment.rawValue

    /// The view the Inspector opens on for an item with no entry, which the store never keeps (VS S3).
    static let start = InspectorViewMemory()
}

/// The visit to the item on show: its URL, and the item and key read off the main actor.
@MainActor
final class InspectorViewMemoryVisit {
    let url: URL
    let store: ViewMemoryStore
    var item: ViewMemoryItem?
    var key: ViewMemoryKey?
    /// Whether the store's entry is read, for a test to wait on.
    var read = false
    /// A person's pick made before the read landed, kept as soon as it lands (LESSONS 1).
    var changedBeforeRead = false

    init(url: URL, store: ViewMemoryStore) {
        self.url = url
        self.store = store
    }

    /// The Inspector's own item, beside the viewer's: the same place, a path no file can have.
    static func inspectorItem(of item: ViewMemoryItem) -> ViewMemoryItem {
        ViewMemoryItem(url: item.url, projectRoot: item.projectRoot, path: item.path + "\u{1F}inspector", folder: item.folder)
    }
}

/// The words of Reset View (VS-WORDS rows 1 and 6, `SCR/codex/VS-WORDS-decisions.md` section 1).
enum ResetViewWords {
    /// Row 1, the View menu item.
    static let menuTitle = "Reset View"
    /// Row 6, the help tag of the Appearance section's Reset button, which names what that button resets.
    static let appearanceResetHelp = "Restores default nucleotide colors, track height and quality overlay in every bundle."
}

extension InspectorViewModel {
    /// The Inspector's view as it stands.
    var currentViewMemory: InspectorViewMemory {
        InspectorViewMemory(
            tab: personTab?.rawValue, samplesExpanded: shownSamplesExpanded,
            readStyleSubsection: shownReadStyleSubsection.rawValue)
    }

    /// Whether the Selected Item tab shows a selection, so a kept Selected Item tab has something to show.
    var selectedItemShowsASelection: Bool {
        selectedAnnotation != nil || variantSectionViewModel.hasVariantSelection
            || readStyleSectionViewModel.selectedRead != nil
    }

    /// Shows the tab the person picked or kept for the item once the content offers it. A kept Selected Item tab whose
    /// selection was not kept leaves the content's tab, with no line (VS U7).
    func applyPersonTab() {
        guard let tab = personTab, tab != shownTab, availableTabs.contains(tab) else { return }
        if tab == .selectedItem, !selectedItemShowsASelection { return }
        setAppTab(tab)
    }

    /// Keeps the Inspector's view for the item on show, in the store and never in the bundle. A view equal to the
    /// start is a retire mark or nothing (VS S3). A pick made before the read lands is kept when it lands.
    func keepViewMemory() {
        guard !applyingViewMemory, let visit = viewMemoryVisit else { return }
        guard visit.read else {
            visit.changedBeforeRead = true
            return
        }
        guard let key = visit.key else { return }
        visit.store.keep(
            currentViewMemory, startingView: .start, for: key, dataKey: nil, folder: visit.item?.folder)
    }

    /// Starts the visit to the item at `url`. The same item shown again keeps its visit. Another item opens on its
    /// content's tab, or on the window's tab at a relaunch, with the disclosure and the subsection at their defaults,
    /// and its kept view applies once its item and key are read off the main actor (SWIFT 2).
    func beginViewMemoryVisit(for url: URL?, store: ViewMemoryStore) {
        let url = url?.standardizedFileURL
        if let visit = viewMemoryVisit, visit.url == url { return }
        viewMemoryVisit = nil
        guard let url else { return }
        applyingViewMemory = true
        personTab = nil
        shownSamplesExpanded = true
        shownReadStyleSubsection = .alignment
        setAppTab(windowStateTab ?? .bundle)
        windowStateTab = nil
        reconcileSelectedTab()
        applyingViewMemory = false
        let visit = InspectorViewMemoryVisit(url: url, store: store)
        viewMemoryVisit = visit
        Task.detached(priority: .userInitiated) { [weak self] in
            let item = ViewMemoryItem.read(at: url)
            await self?.viewMemoryDidRead(item, for: visit)
        }
    }

    private func viewMemoryDidRead(_ item: ViewMemoryItem, for visit: InspectorViewMemoryVisit) {
        guard viewMemoryVisit === visit else { return }
        visit.item = item
        visit.key = visit.store.key(for: InspectorViewMemoryVisit.inspectorItem(of: item))
        visit.read = true
        // A pick made first stays, and is kept now (LESSONS 1).
        guard !visit.changedBeforeRead else { return keepViewMemory() }
        guard let key = visit.key,
              case .view(let kept, _, _) = visit.store.restorable(InspectorViewMemory.self, for: key, folder: item.folder)
        else { return }
        applyingViewMemory = true
        shownSamplesExpanded = kept.samplesExpanded
        shownReadStyleSubsection = ReadStyleViewSubsection(rawValue: kept.readStyleSubsection) ?? .alignment
        personTab = kept.tab.flatMap(InspectorTab.init(rawValue:))
        applyPersonTab()
        applyingViewMemory = false
    }
}

extension InspectorViewController {
    /// Starts the Inspector's visit to the item the window shows next (VS U7). The content display and the relaunch's
    /// restore call it before the content's own notifications.
    func beginViewMemoryVisit(for url: URL?) {
        viewModel.beginViewMemoryVisit(for: url, store: viewMemoryStore)
    }

    /// Whether the Inspector's read of the item on show has landed, for a test to wait on.
    var viewMemoryIsSettled: Bool { viewModel.viewMemoryVisit?.read ?? true }

    /// The store of the window's viewer, so the Inspector keeps its view where the window keeps every other one.
    var viewMemoryStore: ViewMemoryStore {
        enclosingSplit?.viewerController?.surfaceHost.viewMemoryStore ?? .shared
    }

    private var enclosingSplit: MainSplitViewController? {
        var next = parent
        while let controller = next, !(controller is MainSplitViewController) { next = controller.parent }
        return next as? MainSplitViewController
    }

    /// The reference viewer on show, the one a reference or mapping route opened with view memory.
    private var referenceViewerOnShow: ViewerViewController? {
        guard let viewer = enclosingSplit?.viewerController else { return nil }
        if viewer.viewMemory != nil { return viewer }
        return (viewer.installedSurface as? ReferenceBundleSurface)?.controller?.embeddedViewerController
    }

    /// View > Reset View (VS U3, word 1). It resets the view on show only: the surface host's reset and the genotype
    /// viewer's each remove the item's kept view and leave its retire mark, the reference viewer returns its colours,
    /// visibility, list and read filters to the open's, and the annotation block's count filters return to their
    /// defaults. Nothing in a bundle is written or deleted, and the app-wide look stays (the Appearance Reset).
    func resetOpenView() {
        guard let viewer = enclosingSplit?.viewerController else { return }
        if viewModel.contentMode == .genomics || viewModel.contentMode == .mapping {
            viewModel.annotationSectionViewModel.resetToDefaults()
            postAnnotationSettings()
        }
        NotificationCenter.default.post(
            name: .bundleViewStateResetRequested, object: self, userInfo: windowScopedUserInfo())
        viewer.surfaceHost.resetViewMemory()
        if let genotype = viewer.genotypeResultViewController {
            genotype.resetViewMemory()
            // The minimums the viewer does not keep return to their defaults too (VS-GENO BIO ruling 6).
            viewModel.genotypeResultDisplaySectionViewModel.resetCountFilters()
        }
    }

    /// Whether View > Reset View has a view to reset: the open view's live capture differs from its starting view.
    /// It compares on the main actor and reads no store. Its cost is one capture of the view on show and one compare,
    /// at each validation of the menu.
    var openViewDiffersFromItsStart: Bool {
        guard let viewer = enclosingSplit?.viewerController else { return false }
        if viewer.surfaceHost.viewMemoryDiffersFromStart { return true }
        if viewer.genotypeResultViewController?.viewMemoryDiffersFromStart == true { return true }
        return referenceViewerOnShow?.viewMemoryDiffersFromStart ?? false
    }

    /// Sends the annotation block's settings and filters to the viewer, as the block's own controls do.
    func postAnnotationSettings() {
        let annotations = viewModel.annotationSectionViewModel
        NotificationCenter.default.post(
            name: .annotationSettingsChanged, object: self,
            userInfo: windowScopedUserInfo([
                "showAnnotations": annotations.showAnnotations, "annotationHeight": annotations.annotationHeight,
                "annotationSpacing": annotations.annotationSpacing,
            ]))
        NotificationCenter.default.post(
            name: .annotationFilterChanged, object: self,
            userInfo: windowScopedUserInfo([
                "visibleTypes": annotations.visibleTypes, "filterText": annotations.filterText,
            ]))
    }
}
