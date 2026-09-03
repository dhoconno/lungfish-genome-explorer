// ViewerViewController+AlignmentTreeBundles.swift - Native MSA/tree bundle routing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishPhylogeneticsUI
import os.log

private let alignmentTreeViewerLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerAlignmentTreeBundles")

extension ViewerViewController {
    /// Displays a multiple-sequence-alignment bundle, reading the primary
    /// alignment FASTA off the main actor.
    ///
    /// The primary alignment read is a suspension point, so a newer sidebar
    /// selection can supersede this request while the read is in flight. The
    /// caller passes `canCommit` (the display generation guard); it is
    /// re-checked on the main actor AFTER the awaited read but BEFORE the
    /// viewport is installed. If the request has been superseded the freshly
    /// built controller is torn down and NOTHING is committed to the viewport,
    /// so a stale read cannot clobber a newer selection.
    public func displayMultipleSequenceAlignmentBundle(
        at url: URL,
        canCommit: @MainActor () -> Bool = { true }
    ) async throws {
        hideForNativeAlignmentTreeBundle()
        hideGenomicsStackForNativeBundle()
        let controller = MultipleSequenceAlignmentViewController()

        func tearDownFailedController() {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            showGenomicsStackAfterNativeBundle()
        }

        do {
            guard try await controller.displayBundle(at: url, canCommit: canCommit) else {
                alignmentTreeViewerLogger.info(
                    "displayMultipleSequenceAlignmentBundle: Superseded before install for \(url.lastPathComponent, privacy: .public)"
                )
                return
            }
        } catch {
            tearDownFailedController()
            throw error
        }

        // The awaited FASTA read above is a suspension point. If a newer
        // selection superseded this request while the read was in flight, tear
        // down only this offscreen controller and commit nothing: the generation
        // guard must dominate viewport installation and global viewer-chrome
        // restoration, because the newer selection now owns those views.
        guard canCommit() else {
            alignmentTreeViewerLogger.info(
                "displayMultipleSequenceAlignmentBundle: Superseded before install for \(url.lastPathComponent, privacy: .public)"
            )
            return
        }

        addChild(controller)
        installNativeBundleSubview(controller.view)

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

        multipleSequenceAlignmentViewController = controller
        contentMode = .genomics
        alignmentTreeViewerLogger.info("displayMultipleSequenceAlignmentBundle: Showing \(url.lastPathComponent, privacy: .public)")
    }

    public func displayPhylogeneticTreeBundle(at url: URL) throws {
        hideForNativeAlignmentTreeBundle()
        let controller = PhylogeneticTreeViewController()
        addChild(controller)
        installNativeBundleSubview(controller.view)

        do {
            try controller.displayBundle(at: url)
        } catch {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            showGenomicsStackAfterNativeBundle()
            throw error
        }

        controller.onTreeBundleOperationRequested = { [weak self] request in
            self?.performTreeBundleOperationViaCLI(request)
        }

        phylogeneticTreeViewController = controller
        contentMode = .genomics
        alignmentTreeViewerLogger.info("displayPhylogeneticTreeBundle: Showing \(url.lastPathComponent, privacy: .public)")
    }

    func hideAlignmentTreeBundleViews() {
        if let controller = multipleSequenceAlignmentViewController {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            multipleSequenceAlignmentViewController = nil
        }
        if let controller = phylogeneticTreeViewController {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            phylogeneticTreeViewController = nil
        }
        hideGenotypeResultView()
        hideTwelveSAmpliconResultView()
        showGenomicsStackAfterNativeBundle()
    }

    private func hideForNativeAlignmentTreeBundle() {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
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
