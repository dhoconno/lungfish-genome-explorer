// ViewerViewController+AlignmentTreeBundles.swift - Native MSA/tree bundle routing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishPhylogeneticsUI
import os.log

private let alignmentTreeViewerLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerAlignmentTreeBundles")

extension ViewerViewController {
    /// The defaults a newly built alignment viewer keeps its bottom pane state
    /// and name gutter width in. The app never changes it. The view-switch
    /// tests give each test a suite of its own, so the open flag that an
    /// earlier run saved on the machine cannot decide whether the pane opens.
    static var multipleSequenceAlignmentDefaults: UserDefaults = .standard

    /// Shows a multiple-sequence-alignment bundle through the surface host and returns its viewer for the route to wire.
    /// Returns nil when something newer took over during the load, and throws the reason when a load that is still
    /// current fails.
    ///
    /// The primary alignment read is a suspension point, so a newer sidebar selection can supersede this request while
    /// the read is in flight. The caller passes `canCommit` (the display generation guard), and it and the host's token
    /// dominate the install and the chrome, because the newer selection now owns those views. The callbacks are wired
    /// only after the viewer is installed, so a superseded viewer never has one to fire. Removing the viewer cuts them
    /// in `MultipleSequenceAlignmentSurface.willDeactivate` on every removal, and `onWillDeactivate` runs there too, so
    /// the route can take the alignment's blocks out of the Inspector.
    @discardableResult
    func displayMultipleSequenceAlignmentBundle(
        at url: URL,
        canCommit: @escaping @MainActor () -> Bool = { true },
        onWillDeactivate: (@MainActor () -> Void)? = nil
    ) async throws -> MultipleSequenceAlignmentViewController? {
        hideForNativeAlignmentTreeBundle()
        let controller = MultipleSequenceAlignmentViewController()
        controller.gutterWidthDefaults = Self.multipleSequenceAlignmentDefaults
        let input = MultipleSequenceAlignmentSurface.Input(controller: controller, url: url, canCommit: canCommit)
        guard let surface = try await showSurfaceAfterLoad(
            .bundle(.multipleSequenceAlignment), input: input, as: MultipleSequenceAlignmentSurface.self, canCommit: canCommit
        ) else {
            alignmentTreeViewerLogger.info(
                "displayMultipleSequenceAlignmentBundle: Superseded before install for \(url.lastPathComponent, privacy: .public)"
            )
            return nil
        }
        surface.onWillDeactivate = onWillDeactivate

        controller.onExtractSequenceRequested = { [weak self] fastaRecords, suggestedName in
            self?.presentFASTASequenceExtractionDialog(records: fastaRecords, suggestedName: suggestedName)
        }
        controller.onExtractAnnotatedSequenceRequested = { [weak self, weak controller] fastaRecords, suggestedName, annotationsByRecord in
            self?.presentFASTASequenceExtractionDialog(
                records: fastaRecords,
                suggestedName: suggestedName,
                annotationsByRecord: annotationsByRecord,
                sourceAlignmentBundleURL: controller?.bundleURL
            )
        }
        controller.onExportFASTARequested = { [weak self] fastaRecords, suggestedName in
            self?.exportFASTARecords(fastaRecords, suggestedName: suggestedName)
        }
        controller.onExportMSASelectionRequested = { [weak self] request in
            self?.exportMSASelectionViaCLI(request)
        }
        controller.onCopyMSASelectionRequested = { [weak self] request in
            self?.copyMSASubalignment(request)
        }
        controller.onCreateBundleRequested = { [weak self] fastaRecords, suggestedName in
            self?.createReferenceBundle(from: fastaRecords, suggestedName: suggestedName)
        }
        controller.onCreateAnnotatedBundleRequested = { [weak self, weak controller] fastaRecords, suggestedName, annotationsByRecord in
            self?.createReferenceBundle(
                from: fastaRecords,
                suggestedName: suggestedName,
                annotationsByRecord: annotationsByRecord,
                sourceAlignmentBundleURL: controller?.bundleURL
            )
        }
        controller.onRunOperationRequested = { [weak self] fastaRecords, suggestedName in
            self?.presentFASTAOperationDialog(records: fastaRecords, suggestedName: suggestedName)
        }
        controller.onExportAlignmentRequested = { [weak self] request in
            self?.presentMSAAlignmentExportSheet(
                bundleURL: request.bundleURL,
                rows: request.rows,
                columns: request.columns,
                selectedRowCount: request.selectedRowCount,
                totalRowCount: request.totalRowCount
            )
        }
        controller.onInferTreeRequested = { [weak self] request in
            self?.inferTreeFromMSAViaCLI(request)
        }
        controller.onAddAnnotationRequested = { [weak self, weak controller] request in
            self?.addMSAAnnotationViaCLI(request, refreshing: controller)
        }
        controller.onProjectAnnotationRequested = { [weak self, weak controller] request in
            self?.projectMSAAnnotationViaCLI(request, refreshing: controller)
        }
        controller.onExportDistanceMatrixRequested = { [weak self] bundleURL, options in
            self?.exportMSADistanceMatrixViaCLI(bundleURL: bundleURL, options: options)
        }
        controller.onBottomPaneStateChanged = { [weak self] in self?.syncWindowDrawerToolbarButton() }
        // The host installed the viewer a hop before this line, when this callback was not yet set.
        syncWindowDrawerToolbarButton()

        contentMode = .genomics
        alignmentTreeViewerLogger.info("displayMultipleSequenceAlignmentBundle: Showing \(url.lastPathComponent, privacy: .public)")
        return controller
    }

    /// What the route passes as `onWillDeactivate`. It takes the alignment's own document and selection out of the
    /// Inspector and leaves every other kind's blocks where they are, since the route gives the next alignment's blocks
    /// only after that show. It leaves the discriminating sites and pairwise distance models in place, which
    /// `updateMultipleSequenceAlignmentDocument(nil)` would drop: they hold the roles a person marked, saved nowhere, and
    /// the Inspector reuses them when the same alignment opens again.
    static func multipleSequenceAlignmentBlockReset(_ inspector: InspectorViewController?) -> @MainActor () -> Void {
        { [weak inspector] in
            guard let inspector else { return }
            let document = inspector.viewModel.documentSectionViewModel
            document.multipleSequenceAlignmentDocument = nil
            document.msaPairwiseDistance?.onShowDistanceMatrix = nil
            if inspector.viewModel.selectionSectionViewModel.multipleSequenceAlignmentSelection != nil {
                inspector.updateMultipleSequenceAlignmentSelection(nil)
            }
        }
    }

    /// Hides the alignment viewer, a shim that other display routes call until the hide list goes in Phase 3.2.
    func hideMultipleSequenceAlignmentBundleView() {
        clearSurface(ifShowing: .bundle(.multipleSequenceAlignment))
    }

    /// Shows the tree bundle at `url` through the surface host and returns its viewer for the route to wire, or throws
    /// the reason it is not installed. The surface's load reads the bundle, so a file that does not read reaches the
    /// route as that file's own error. Removing the viewer cuts its callbacks in `PhylogeneticTreeSurface.willDeactivate`
    /// on every removal, and `onWillDeactivate` runs there too, so the route can take the tree's blocks out of the
    /// Inspector.
    @discardableResult
    public func displayPhylogeneticTreeBundle(
        at url: URL,
        onWillDeactivate: (@MainActor () -> Void)? = nil
    ) throws -> PhylogeneticTreeViewController {
        hideForNativeAlignmentTreeBundle()
        let surface = try showSurface(.bundle(.phylogeneticTree), input: url, as: PhylogeneticTreeSurface.self)
        guard let controller = surface.controller else { throw SurfaceError.notInstalled(.bundle(.phylogeneticTree)) }
        surface.onWillDeactivate = onWillDeactivate
        controller.onTreeBundleOperationRequested = { [weak self] request in
            self?.performTreeBundleOperationViaCLI(request)
        }

        contentMode = .genomics
        alignmentTreeViewerLogger.info("displayPhylogeneticTreeBundle: Showing \(url.lastPathComponent, privacy: .public)")
        return controller
    }

    /// What the route passes as `onWillDeactivate`. It takes the tree's own document and selection out of the
    /// Inspector and leaves every other kind's blocks where they are, since the route gives the next tree's blocks only
    /// after that tree's show.
    static func phylogeneticTreeBlockReset(_ inspector: InspectorViewController?) -> @MainActor () -> Void {
        { [weak inspector] in
            guard let inspector else { return }
            inspector.viewModel.documentSectionViewModel.updatePhylogeneticTreeDocument(nil)
            if inspector.viewModel.selectionSectionViewModel.phylogeneticTreeSelection != nil {
                inspector.updatePhylogeneticTreeSelection(nil)
            }
        }
    }

    /// Hides the tree viewer, a shim that other display routes call until the hide list goes in Phase 3.2.
    func hidePhylogeneticTreeBundleView() {
        clearSurface(ifShowing: .bundle(.phylogeneticTree))
    }

    func hideAlignmentTreeBundleViews() {
        hideMultipleSequenceAlignmentBundleView()
        hidePhylogeneticTreeBundleView()
        hideGenotypeResultView()
        hideTwelveSAmpliconResultView()
        hideMHCReferenceBundleView()
        showGenomicsStackAfterNativeBundle()
    }

    private func hideForNativeAlignmentTreeBundle() {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideCzIdView()
        hideAssemblyView()
        hideMappingView()
        hideAlignmentTreeBundleViews()
        clearBundleDisplay()
        hideCollectionBackButton()
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true
    }

    private func installNativeBundleSubview(_ nativeView: NSView) {
        nativeView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nativeView)
        NSLayoutConstraint.activate([
            nativeView.topAnchor.constraint(equalTo: view.topAnchor),
            nativeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nativeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nativeView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true
    }

    private func showGenomicsStackAfterNativeBundle() {
        enhancedRulerView?.isHidden = false
        viewerView?.isHidden = false
        headerView?.isHidden = false
        statusBar?.isHidden = false
        geneTabBarView?.isHidden = true
    }

    private func hideGenomicsStackForNativeBundle() {
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true
    }
}
