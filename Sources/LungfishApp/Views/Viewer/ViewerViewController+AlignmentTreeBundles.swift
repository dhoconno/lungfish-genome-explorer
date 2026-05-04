// ViewerViewController+AlignmentTreeBundles.swift - Native MSA/tree bundle routing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

private let alignmentTreeViewerLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerAlignmentTreeBundles")

extension ViewerViewController {
    public func displayMultipleSequenceAlignmentBundle(at url: URL) throws {
        hideForNativeAlignmentTreeBundle()
        let controller = MultipleSequenceAlignmentViewController()
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
}
