// ViewerViewController+Genotype.swift - Native genotype result bundle display
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishGenotypeUI
import os.log

private let genotypeDisplayLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerGenotype")

extension ViewerViewController {
    @discardableResult
    func displayGenotypeResult(_ result: ONTGenotypeResultBundleData) -> GenotypeResultViewController {
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
        hideMHCReferenceBundleView()
        hideGenotypeResultView()
        hideAlignmentTreeBundleViews()
        hideTwelveSAmpliconResultView()
        clearBundleDisplay()
        hideCollectionBackButton()
        hideBundleBackNavigationButton()
        hideProgress()
        contentMode = .genotype

        let controller = GenotypeResultViewController()
        controller.annotationAuthorProvider = { AppSettings.shared.resolvedAnalystIdentity() }
        controller.windowStateScope = windowStateScope
        controller.manualHaplotypeBandDisclosureStore =
            genotypeManualHaplotypeBandDisclosureStore
        addChild(controller)

        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let genotypeView = controller.view
        genotypeView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(genotypeView)

        NSLayoutConstraint.activate([
            genotypeView.topAnchor.constraint(equalTo: view.topAnchor),
            genotypeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            genotypeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            genotypeView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        controller.configure(result: result)
        genotypeResultViewController = controller

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        genotypeDisplayLogger.info(
            "displayGenotypeResult: Showing \(result.manifest.outputName, privacy: .public)"
        )

        return controller
    }

    func hideGenotypeResultView() {
        guard let controller = genotypeResultViewController else { return }
        onGenotypeResultViewWillHide?(controller)
        controller.detachHostPresentationCallbacks()
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        genotypeResultViewController = nil

        enhancedRulerView?.isHidden = false
        viewerView?.isHidden = false
        headerView?.isHidden = false
        statusBar?.isHidden = false
        geneTabBarView?.isHidden = (geneTabBarView?.selectedGeneRegion == nil)
        annotationDrawerView?.isHidden = false
        fastqMetadataDrawerView?.isHidden = false
    }
}
